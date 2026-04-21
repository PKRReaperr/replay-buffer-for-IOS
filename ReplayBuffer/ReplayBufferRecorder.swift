@preconcurrency import AVFoundation
import Foundation
import Photos

enum CameraStabilizationMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case standard
    case cinematic
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .standard:
            return "Standard"
        case .cinematic:
            return "Cinematic"
        case .auto:
            return "Auto"
        }
    }

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off:
            return .off
        case .standard:
            return .standard
        case .cinematic:
            return .cinematic
        case .auto:
            return .auto
        }
    }
}

enum CameraPosition: String, Identifiable, Sendable {
    case back
    case front

    var id: String { rawValue }

    var label: String {
        switch self {
        case .back:
            return "Rear"
        case .front:
            return "Front"
        }
    }
}

final class ReplayBufferRecorder: NSObject, @unchecked Sendable {
    struct RecordedSegment {
        let url: URL
        let duration: TimeInterval
    }

    var onStatusChange: ((String) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?
    var onSaveStateChange: ((Bool) -> Void)?
    var onBufferedDurationChange: ((TimeInterval) -> Void)?
    var onZoomConfigurationChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onAvailableStabilizationModesChange: (([CameraStabilizationMode]) -> Void)?
    var onSelectedStabilizationModeChange: ((CameraStabilizationMode) -> Void)?
    var onCameraPositionChange: ((CameraPosition) -> Void)?
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
    private var videoInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    private var supportedStabilizationModes: [CameraStabilizationMode] = [.off]
    private var selectedStabilizationMode: CameraStabilizationMode = .off
    private var cameraPosition: CameraPosition = .back

    init(session: AVCaptureSession) {
        self.session = session
        super.init()
    }

    func requestPermissions() async -> Bool {
        async let video = requestMediaAccess(for: .video)
        async let audio = requestMediaAccess(for: .audio)
        async let photos = requestPhotoLibraryAccess()

        let videoGranted = await video
        let audioGranted = await audio
        let photosGranted = await photos

        return videoGranted && audioGranted && photosGranted
    }

    func configureSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if self.isConfigured {
                        continuation.resume()
                        return
                    }

                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high

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

                    try self.configureVideoInput(position: .back)
                    self.applyVideoConnectionConfiguration()

                    self.session.commitConfiguration()
                    self.isConfigured = true
                    self.publishCameraConfiguration()
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
            let hasBufferedFootage = !self.segments.isEmpty
            guard self.shouldContinueRecording || self.movieOutput.isRecording || hasBufferedFootage else {
                self.alert("No buffered footage is available yet.")
                return
            }
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

    func setZoomFactor(_ zoomFactor: CGFloat) {
        sessionQueue.async {
            guard let videoDevice = self.videoDevice else { return }

            let maximumZoomFactor = self.maximumZoomFactor(for: videoDevice)
            let clampedZoomFactor = min(max(zoomFactor, 1), maximumZoomFactor)

            do {
                try videoDevice.lockForConfiguration()
                videoDevice.videoZoomFactor = clampedZoomFactor
                videoDevice.unlockForConfiguration()
                self.updateZoomConfiguration(minimum: 1, maximum: maximumZoomFactor, current: clampedZoomFactor)
            } catch {
                self.alert("The camera could not change zoom.")
            }
        }
    }

    func setStabilizationMode(_ mode: CameraStabilizationMode) {
        sessionQueue.async {
            let resolvedMode = self.supportedStabilizationModes.contains(mode) ? mode : .off
            self.selectedStabilizationMode = resolvedMode
            self.applyVideoConnectionConfiguration()
            self.updateSelectedStabilizationMode(resolvedMode)
        }
    }

    func switchCamera() {
        sessionQueue.async {
            guard self.isConfigured else { return }
            guard !self.movieOutput.isRecording else {
                self.alert("Stop buffering before switching cameras.")
                return
            }

            let targetPosition: CameraPosition = self.cameraPosition == .back ? .front : .back

            do {
                self.session.beginConfiguration()
                try self.configureVideoInput(position: targetPosition)
                self.applyVideoConnectionConfiguration()
                self.session.commitConfiguration()
                self.publishCameraConfiguration()
                self.updateStatus("\(targetPosition.label) camera ready. Tap record to start buffering.")
            } catch {
                self.session.commitConfiguration()
                self.alert(error.localizedDescription)
            }
        }
    }

    private func startNewSegment() {
        guard shouldContinueRecording, !movieOutput.isRecording else { return }

        let url = makeSegmentURL()
        currentSegmentStart = Date()
        movieOutput.maxRecordedDuration = CMTime(seconds: segmentDuration, preferredTimescale: 600)
        applyVideoConnectionConfiguration()
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

    private func maximumZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        max(1, min(device.activeFormat.videoMaxZoomFactor, 10))
    }

    private func cameraDevice(for position: CameraPosition) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType]

        switch position {
        case .back:
            deviceTypes = [.builtInWideAngleCamera]
        case .front:
            deviceTypes = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position == .back ? .back : .front
        ).devices.first
    }

    private func configureVideoInput(position: CameraPosition) throws {
        guard let device = cameraDevice(for: position) else {
            throw RecorderError.cameraUnavailable
        }

        let newInput = try AVCaptureDeviceInput(device: device)
        let previousInput = videoInput

        if let previousInput {
            session.removeInput(previousInput)
        }

        guard session.canAddInput(newInput) else {
            if let previousInput {
                session.addInput(previousInput)
            }
            throw RecorderError.cannotAddVideoInput
        }

        session.addInput(newInput)
        videoInput = newInput
        videoDevice = device
        cameraPosition = position
        supportedStabilizationModes = availableStabilizationModes(for: device)
        selectedStabilizationMode = supportedStabilizationModes.contains(selectedStabilizationMode)
            ? selectedStabilizationMode
            : defaultStabilizationMode(from: supportedStabilizationModes)

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = 1
            device.unlockForConfiguration()
        } catch {
            throw RecorderError.cannotConfigureCamera
        }
    }

    private func availableStabilizationModes(for device: AVCaptureDevice) -> [CameraStabilizationMode] {
        var modes: [CameraStabilizationMode] = [.off]

        for mode in [CameraStabilizationMode.standard, .cinematic, .auto] {
            if device.activeFormat.isVideoStabilizationModeSupported(mode.avMode) {
                modes.append(mode)
            }
        }

        return modes
    }

    private func defaultStabilizationMode(from modes: [CameraStabilizationMode]) -> CameraStabilizationMode {
        if modes.contains(.cinematic) {
            return .cinematic
        }

        if modes.contains(.standard) {
            return .standard
        }

        if modes.contains(.auto) {
            return .auto
        }

        return .off
    }

    private func applyVideoConnectionConfiguration() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        let resolvedMode = supportedStabilizationModes.contains(selectedStabilizationMode) ? selectedStabilizationMode : .off
        selectedStabilizationMode = resolvedMode
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = resolvedMode.avMode
        }
    }

    private func publishCameraConfiguration() {
        guard let videoDevice else { return }

        updateZoomConfiguration(
            minimum: 1,
            maximum: maximumZoomFactor(for: videoDevice),
            current: min(max(videoDevice.videoZoomFactor, 1), maximumZoomFactor(for: videoDevice))
        )
        updateAvailableStabilizationModes(supportedStabilizationModes)
        updateSelectedStabilizationMode(selectedStabilizationMode)
        updateCameraPosition(cameraPosition)
    }

    private func handleCompletedSegment(at outputURL: URL) {
        let duration = max(Date().timeIntervalSince(currentSegmentStart), 0)

        segments.append(RecordedSegment(url: outputURL, duration: duration))
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
            let semaphore = DispatchSemaphore(value: 0)

            Task {
                defer { semaphore.signal() }

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

            semaphore.wait()
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
            let newStatus = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
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

    private func updateZoomConfiguration(minimum: CGFloat, maximum: CGFloat, current: CGFloat) {
        DispatchQueue.main.async {
            self.onZoomConfigurationChange?(minimum, maximum, current)
        }
    }

    private func updateAvailableStabilizationModes(_ modes: [CameraStabilizationMode]) {
        DispatchQueue.main.async {
            self.onAvailableStabilizationModesChange?(modes)
        }
    }

    private func updateSelectedStabilizationMode(_ mode: CameraStabilizationMode) {
        DispatchQueue.main.async {
            self.onSelectedStabilizationModeChange?(mode)
        }
    }

    private func updateCameraPosition(_ position: CameraPosition) {
        DispatchQueue.main.async {
            self.onCameraPositionChange?(position)
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
    case cannotConfigureCamera
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
        case .cannotConfigureCamera:
            return "The selected camera could not be configured."
        case .noSegmentsToExport:
            return "There is not enough buffered footage to export yet."
        case .cannotCreateExportSession:
            return "The replay export session could not be created."
        case .photoLibrarySaveFailed:
            return "The replay clip could not be saved to the Photos library."
        }
    }
}

extension AVAssetExportSession: @unchecked Sendable {}

private extension AVAssetExportSession {
    func exportAsync() async throws {
        let session = self

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: session.error ?? RecorderError.cannotCreateExportSession)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: RecorderError.cannotCreateExportSession)
                }
            }
        }
    }
}
