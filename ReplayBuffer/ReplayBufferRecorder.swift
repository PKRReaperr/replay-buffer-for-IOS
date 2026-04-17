import AVFoundation
import Foundation
import Photos

final class ReplayBufferRecorder: NSObject {
    struct RecordedSegment {
        let url: URL
        let startedAt: Date
        let duration: TimeInterval
    }

    var onStatusChange: ((String) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?
    var onSaveStateChange: ((Bool) -> Void)?
    var onBufferedDurationChange: ((TimeInterval) -> Void)?
    var onAlert: ((String) -> Void)?

    private let session: AVCaptureSession
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "ReplayBufferRecorder.SessionQueue")
    private let exportQueue = DispatchQueue(label: "ReplayBufferRecorder.ExportQueue", qos: .userInitiated)

    private let segmentDuration: TimeInterval = 5
    private let maximumBufferDuration: TimeInterval = 300

    private var isConfigured = false
    private var shouldContinueRecording = false
    private var currentSegmentStart = Date()
    private var segments: [RecordedSegment] = []
    private var pendingExportDuration: TimeInterval?

    init(session: AVCaptureSession) {
        self.session = session
        super.init()
    }

    func requestPermissions() async -> Bool {
        async let video = requestMediaAccess(for: .video)
        async let audio = requestMediaAccess(for: .audio)
        async let photos = requestPhotoLibraryAccess()

        return await video && audio && photos
    }

    func configureSession() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    if self.isConfigured {
                        continuation.resume()
                        return
                    }

                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high

                    guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw RecorderError.cameraUnavailable
                    }

                    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                    guard self.session.canAddInput(videoInput) else {
                        throw RecorderError.cannotAddVideoInput
                    }
                    self.session.addInput(videoInput)

                    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                        throw RecorderError.microphoneUnavailable
                    }

                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    guard self.session.canAddInput(audioInput) else {
                        throw RecorderError.cannotAddAudioInput
                    }
                    self.session.addInput(audioInput)

                    guard self.session.canAddOutput(self.movieOutput) else {
                        throw RecorderError.cannotAddMovieOutput
                    }

                    self.movieOutput.movieFragmentInterval = .invalid
                    self.movieOutput.maxRecordedFileSize = 0
                    self.session.addOutput(self.movieOutput)

                    if let connection = self.movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }

                    self.session.commitConfiguration()
                    self.isConfigured = true
                    continuation.resume()
                } catch {
                    self.session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() {
        sessionQueue.async {
            guard self.isConfigured else { return }
            guard !self.shouldContinueRecording else { return }

            self.shouldContinueRecording = true

            if !self.session.isRunning {
                self.session.startRunning()
            }

            self.updateStatus("Recording into replay buffer...")
            self.updateRecordingState(true)
            self.startNewSegment()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.isConfigured else { return }
            guard self.shouldContinueRecording || self.movieOutput.isRecording else { return }

            self.shouldContinueRecording = false
            self.updateStatus("Stopping recording...")

            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.updateStatus("Camera ready. Tap record to start buffering.")
                self.updateRecordingState(false)
            }
        }
    }

    func release() {
        stop()
        sessionQueue.async {
            self.pendingExportDuration = nil
            self.segments.removeAll()
            self.updateBufferedDuration(0)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReplayBufferSegments", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func exportRecentReplay(duration: TimeInterval) {
        sessionQueue.async {
            guard self.shouldContinueRecording else { return }
            guard self.movieOutput.isRecording else {
                self.exportCompletedSegments(duration: duration)
                return
            }

            self.pendingExportDuration = duration
            self.updateSaveState(true)
            self.updateStatus("Closing current segment...")
            self.movieOutput.stopRecording()
        }
    }

    private func startNewSegment() {
        guard shouldContinueRecording, !movieOutput.isRecording else { return }

        let url = makeSegmentURL()
        currentSegmentStart = Date()
        movieOutput.maxRecordedDuration = CMTime(seconds: segmentDuration, preferredTimescale: 600)
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func makeSegmentURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayBufferSegments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    private func pruneSegmentsIfNeeded() {
        var retained: [RecordedSegment] = []
        var totalDuration: TimeInterval = 0

        for segment in segments.reversed() {
            retained.append(segment)
            totalDuration += segment.duration

            if totalDuration >= maximumBufferDuration {
                break
            }
        }

        let keep = Array(retained.reversed())
        let removedURLs = Set(segments.map(\.url)).subtracting(keep.map(\.url))
        segments = keep

        for url in removedURLs {
            try? FileManager.default.removeItem(at: url)
        }

        updateBufferedDuration(segments.reduce(0) { $0 + $1.duration })
    }

    private func handleCompletedSegment(at outputURL: URL) {
        let measuredDuration = max(CMTimeGetSeconds(AVURLAsset(url: outputURL).duration), 0)
        let duration = measuredDuration > 0 ? measuredDuration : Date().timeIntervalSince(currentSegmentStart)

        segments.append(RecordedSegment(url: outputURL, startedAt: currentSegmentStart, duration: duration))
        pruneSegmentsIfNeeded()
    }

    private func exportCompletedSegments(duration: TimeInterval) {
        let snapshot = segments
        guard !snapshot.isEmpty else {
            updateSaveState(false)
            updateStatus("The replay buffer has not captured enough footage yet.")
            alert("No buffered footage is available yet.")
            return
        }

        updateSaveState(true)
        updateStatus("Saving replay to Photos...")

        exportQueue.async {
            Task {
                do {
                    let exportURL = try await self.buildReplayClip(from: snapshot, requestedDuration: duration)
                    try await self.saveExportToPhotoLibrary(exportURL: exportURL)
                    try? FileManager.default.removeItem(at: exportURL)
                    self.updateStatus("Replay saved to Photos.")
                    self.updateSaveState(false)
                } catch {
                    self.updateStatus("Replay save failed.")
                    self.updateSaveState(false)
                    self.alert(error.localizedDescription)
                }
            }
        }
    }

    private func buildReplayClip(from segments: [RecordedSegment], requestedDuration: TimeInterval) async throws -> URL {
        let selectedSegments = selectSegments(for: requestedDuration, from: segments)
        guard !selectedSegments.isEmpty else {
            throw RecorderError.noSegmentsToExport
        }

        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero

        for segment in selectedSegments {
            let asset = AVURLAsset(url: segment.url)
            let assetDuration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: assetDuration)

            if let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack?.insertTimeRange(timeRange, of: sourceVideoTrack, at: cursor)
                let transform = try await sourceVideoTrack.load(.preferredTransform)
                videoTrack?.preferredTransform = transform
            }

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(timeRange, of: sourceAudioTrack, at: cursor)
            }

            cursor = cursor + assetDuration
        }

        let exportDuration = min(requestedDuration, CMTimeGetSeconds(cursor))
        guard exportDuration > 0 else {
            throw RecorderError.noSegmentsToExport
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Replay-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.cannotCreateExportSession
        }

        let trimStart = max(0, CMTimeGetSeconds(cursor) - exportDuration)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: exportDuration, preferredTimescale: 600)
        )

        try await exportSession.exportAsync()
        return outputURL
    }

    private func selectSegments(for requestedDuration: TimeInterval, from segments: [RecordedSegment]) -> [RecordedSegment] {
        var selection: [RecordedSegment] = []
        var accumulated: TimeInterval = 0

        for segment in segments.reversed() {
            selection.append(segment)
            accumulated += segment.duration

            if accumulated >= requestedDuration {
                break
            }
        }

        return selection.reversed()
    }

    private func saveExportToPhotoLibrary(exportURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportURL)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RecorderError.photoLibrarySaveFailed)
                }
            }
        }
    }

    private func requestMediaAccess(for mediaType: AVMediaType) async -> Bool {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: mediaType)

        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func requestPhotoLibraryAccess() async -> Bool {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch currentStatus {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
            return newStatus == .authorized || newStatus == .limited
        default:
            return false
        }
    }

    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.onStatusChange?(message)
        }
    }

    private func updateRecordingState(_ isRecording: Bool) {
        DispatchQueue.main.async {
            self.onRecordingStateChange?(isRecording)
        }
    }

    private func updateSaveState(_ isSaving: Bool) {
        DispatchQueue.main.async {
            self.onSaveStateChange?(isSaving)
        }
    }

    private func updateBufferedDuration(_ duration: TimeInterval) {
        DispatchQueue.main.async {
            self.onBufferedDurationChange?(duration)
        }
    }

    private func alert(_ message: String) {
        DispatchQueue.main.async {
            self.onAlert?(message)
        }
    }
}

extension ReplayBufferRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        updateStatus("Buffering the latest five minutes.")
        updateRecordingState(true)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async {
            if let nsError = error as NSError?, nsError.code != AVError.maximumDurationReached.rawValue {
                self.shouldContinueRecording = false
                self.pendingExportDuration = nil
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.updateStatus("Capture interrupted.")
                self.updateRecordingState(false)
                self.updateSaveState(false)
                self.alert(nsError.localizedDescription)
                return
            }

            self.handleCompletedSegment(at: outputFileURL)

            if let exportDuration = self.pendingExportDuration {
                self.pendingExportDuration = nil
                self.exportCompletedSegments(duration: exportDuration)
            }

            if self.shouldContinueRecording {
                self.startNewSegment()
            } else {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.updateStatus("Camera ready. Tap record to start buffering.")
                self.updateRecordingState(false)
            }
        }
    }
}

private enum RecorderError: LocalizedError {
    case cameraUnavailable
    case microphoneUnavailable
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotAddMovieOutput
    case noSegmentsToExport
    case cannotCreateExportSession
    case photoLibrarySaveFailed

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "The back camera is not available on this device."
        case .microphoneUnavailable:
            return "The microphone is not available on this device."
        case .cannotAddVideoInput:
            return "The app could not attach the video input."
        case .cannotAddAudioInput:
            return "The app could not attach the audio input."
        case .cannotAddMovieOutput:
            return "The app could not create the movie output."
        case .noSegmentsToExport:
            return "There is not enough buffered footage to export yet."
        case .cannotCreateExportSession:
            return "The replay export session could not be created."
        case .photoLibrarySaveFailed:
            return "The replay clip could not be saved to the Photos library."
        }
    }
}

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: self.error ?? RecorderError.cannotCreateExportSession)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: RecorderError.cannotCreateExportSession)
                }
            }
        }
    }
}
