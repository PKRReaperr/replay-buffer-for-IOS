@preconcurrency import AVFoundation
import CoreMedia
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
        let duration: CMTime

        var durationSeconds: TimeInterval {
            max(CMTimeGetSeconds(duration), 0)
        }
    }

    private final class ActiveSegment {
        let url: URL
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput
        let startedAt: CMTime
        var lastVideoEndTime: CMTime

        init(
            url: URL,
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            audioInput: AVAssetWriterInput,
            startedAt: CMTime
        ) {
            self.url = url
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.startedAt = startedAt
            self.lastVideoEndTime = startedAt
        }
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
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "ReplayBufferRecorder.SessionQueue")
    private let exportQueue = DispatchQueue(label: "ReplayBufferRecorder.ExportQueue", qos: .userInitiated)

    private let segmentDuration: TimeInterval = 5
    private let maximumBufferDuration: TimeInterval = 300

    private var isConfigured = false
    private var shouldContinueRecording = false
    private var segments: [RecordedSegment] = []
    private var currentSegment: ActiveSegment?
    private var pendingExportDuration: TimeInterval?
    private var pendingCameraPosition: CameraPosition?
    private var forceSegmentRollover = false
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
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

                    try self.configureAudioInput()
                    try self.configureVideoInput(position: .back)
                    try self.configureDataOutputs()
                    self.applyVideoConnectionConfiguration()

                    self.session.commitConfiguration()

                    if !self.session.isRunning {
                        self.session.startRunning()
                    }

                    self.isConfigured = true
                    self.publishCameraConfiguration()
                    self.updateStatus("Camera ready. Tap record to start buffering.")
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
            self.forceSegmentRollover = false

            if !self.session.isRunning {
                self.session.startRunning()
            }

            self.updateStatus("Recording into replay buffer...")
            self.updateRecordingState(true)
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.isConfigured else { return }
            guard self.shouldContinueRecording || self.currentSegment != nil else { return }

            self.shouldContinueRecording = false
            self.pendingCameraPosition = nil
            self.forceSegmentRollover = false
            self.updateStatus("Stopping recording...")

            if self.currentSegment != nil {
                self.finishCurrentSegment(exportDuration: nil)
            } else {
                self.updateStatus("Camera ready. Tap record to start buffering.")
                self.updateRecordingState(false)
            }
        }
    }

    func release() {
        sessionQueue.async {
            self.shouldContinueRecording = false
            self.pendingExportDuration = nil
            self.pendingCameraPosition = nil
            self.forceSegmentRollover = false

            if let currentSegment = self.currentSegment {
                currentSegment.writer.cancelWriting()
                self.currentSegment = nil
            }

            self.segments.removeAll()
            self.updateBufferedDuration(0)

            if self.session.isRunning {
                self.session.stopRunning()
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReplayBufferSegments", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func exportRecentReplay(duration: TimeInterval) {
        sessionQueue.async {
            let hasBufferedFootage = !self.segments.isEmpty || self.currentSegment != nil
            guard hasBufferedFootage else {
                self.alert("No buffered footage is available yet.")
                return
            }

            if self.currentSegment != nil {
                self.pendingExportDuration = duration
                self.forceSegmentRollover = true
                self.updateSaveState(true)
                self.updateStatus("Preparing replay...")
            } else {
                self.exportCompletedSegments(duration: duration)
            }
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
                self.publishCameraConfiguration()
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

            let targetPosition: CameraPosition = self.cameraPosition == .back ? .front : .back

            if self.currentSegment != nil {
                self.pendingCameraPosition = targetPosition
                self.forceSegmentRollover = true
                self.updateStatus("Switching to \(targetPosition.label.lowercased()) camera...")
                return
            }

            do {
                try self.performCameraSwitch(to: targetPosition)
                self.updateStatus("\(targetPosition.label) camera ready. Tap record to start buffering.")
            } catch {
                self.alert(error.localizedDescription)
            }
        }
    }

    private func configureAudioInput() throws {
        guard audioInput == nil else { return }

        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.microphoneUnavailable
        }

        let input = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(input) else {
            throw RecorderError.cannotAddAudioInput
        }

        session.addInput(input)
        audioInput = input
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

    private func configureDataOutputs() throws {
        if !session.outputs.contains(videoDataOutput) {
            videoDataOutput.alwaysDiscardsLateVideoFrames = false
            videoDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(videoDataOutput) else {
                throw RecorderError.cannotAddVideoOutput
            }
            session.addOutput(videoDataOutput)
        }

        if !session.outputs.contains(audioDataOutput) {
            audioDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(audioDataOutput) else {
                throw RecorderError.cannotAddAudioOutput
            }
            session.addOutput(audioDataOutput)
        }
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

    private func maximumZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        max(1, min(device.activeFormat.videoMaxZoomFactor, 10))
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
        guard let connection = videoDataOutput.connection(with: .video) else { return }

        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = cameraPosition == .front
        }

        let resolvedMode = supportedStabilizationModes.contains(selectedStabilizationMode) ? selectedStabilizationMode : .off
        selectedStabilizationMode = resolvedMode

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = resolvedMode.avMode
        }
    }

    private func performCameraSwitch(to position: CameraPosition) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        try configureVideoInput(position: position)
        applyVideoConnectionConfiguration()
        publishCameraConfiguration()
    }

    private func startSegment(with sampleBuffer: CMSampleBuffer) throws {
        let url = makeSegmentURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings = videoWriterSettings()
        let audioSettings = audioWriterSettings()

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.cannotCreateSegmentWriter
        }

        writer.add(videoInput)
        writer.add(audioInput)
        writer.startWriting()

        let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: startTime)
        currentSegment = ActiveSegment(
            url: url,
            writer: writer,
            videoInput: videoInput,
            audioInput: audioInput,
            startedAt: startTime
        )
    }

    private func videoWriterSettings() -> [String: Any] {
        if let settings = videoDataOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            return settings
        }

        let dimensions: CMVideoDimensions
        if let videoDevice {
            dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        } else {
            dimensions = CMVideoDimensions(width: 1080, height: 1920)
        }

        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height)
        ]
    }

    private func audioWriterSettings() -> [String: Any] {
        if let settings = audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            return settings
        }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
    }

    private func append(sampleBuffer: CMSampleBuffer, to segment: ActiveSegment, mediaType: AVMediaType) {
        let writerInput = mediaType == .video ? segment.videoInput : segment.audioInput
        guard writerInput.isReadyForMoreMediaData else { return }

        if writerInput.append(sampleBuffer) {
            if mediaType == .video {
                let endTime = sampleEndTime(for: sampleBuffer)
                if endTime.isValid, CMTimeCompare(endTime, segment.lastVideoEndTime) > 0 {
                    segment.lastVideoEndTime = endTime
                }

                updateBufferedDuration(totalBufferedDurationIncludingCurrentSegment())
            }
        } else if let error = segment.writer.error {
            alert(error.localizedDescription)
        }
    }

    private func sampleEndTime(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard startTime.isValid else { return .invalid }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, !duration.isIndefinite, CMTimeCompare(duration, .zero) > 0 {
            return CMTimeAdd(startTime, duration)
        }

        if let fallbackDuration = fallbackVideoFrameDuration() {
            return CMTimeAdd(startTime, fallbackDuration)
        }

        return startTime
    }

    private func fallbackVideoFrameDuration() -> CMTime? {
        guard let videoDevice else { return nil }

        for candidate in [videoDevice.activeVideoMinFrameDuration, videoDevice.activeVideoMaxFrameDuration] {
            if candidate.isValid, !candidate.isIndefinite, CMTimeCompare(candidate, .zero) > 0 {
                return candidate
            }
        }

        return nil
    }

    private func segmentDuration(for segment: ActiveSegment) -> CMTime {
        guard segment.lastVideoEndTime.isValid else { return .zero }

        let duration = CMTimeSubtract(segment.lastVideoEndTime, segment.startedAt)
        guard duration.isValid, !duration.isIndefinite, CMTimeCompare(duration, .zero) > 0 else {
            return .zero
        }

        return duration
    }

    private func clampedDuration(_ duration: CMTime, to upperBound: CMTime) -> CMTime {
        guard duration.isValid, !duration.isIndefinite, CMTimeCompare(duration, .zero) > 0 else {
            return .zero
        }

        guard upperBound.isValid, !upperBound.isIndefinite, CMTimeCompare(upperBound, .zero) > 0 else {
            return duration
        }

        return CMTimeCompare(duration, upperBound) <= 0 ? duration : upperBound
    }

    private func finishCurrentSegment(exportDuration: TimeInterval?) {
        guard let segment = currentSegment else {
            if let pendingCameraPosition {
                self.pendingCameraPosition = nil
                do {
                    try performCameraSwitch(to: pendingCameraPosition)
                } catch {
                    alert(error.localizedDescription)
                }
            }

            if let exportDuration {
                exportCompletedSegments(duration: exportDuration)
            }

            if !shouldContinueRecording {
                updateStatus("Camera ready. Tap record to start buffering.")
                updateRecordingState(false)
            }
            return
        }

        currentSegment = nil
        forceSegmentRollover = false

        let duration = segmentDuration(for: segment)
        let pendingCameraPosition = self.pendingCameraPosition
        self.pendingCameraPosition = nil

        segment.videoInput.markAsFinished()
        segment.audioInput.markAsFinished()

        if let pendingCameraPosition {
            do {
                try performCameraSwitch(to: pendingCameraPosition)
            } catch {
                alert(error.localizedDescription)
            }
        }

        segment.writer.finishWriting { [weak self] in
            guard let self else { return }

            let recordedSegment = RecordedSegment(url: segment.url, duration: duration)

            self.sessionQueue.async {
                self.handleFinishedSegment(recordedSegment)

                if let exportDuration {
                    self.exportCompletedSegments(duration: exportDuration)
                }

                if !self.shouldContinueRecording {
                    self.updateStatus("Camera ready. Tap record to start buffering.")
                    self.updateRecordingState(false)
                }
            }
        }
    }

    private func handleFinishedSegment(_ segment: RecordedSegment) {
        guard segment.durationSeconds > 0 else {
            try? FileManager.default.removeItem(at: segment.url)
            updateBufferedDuration(totalBufferedDurationIncludingCurrentSegment())
            return
        }

        segments.append(segment)
        pruneSegmentsIfNeeded()
    }

    private func pruneSegmentsIfNeeded() {
        var retained: [RecordedSegment] = []
        var totalDuration: TimeInterval = 0

        for segment in segments.reversed() {
            retained.append(segment)
            totalDuration += segment.durationSeconds

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

        updateBufferedDuration(totalBufferedDurationIncludingCurrentSegment())
    }

    private func totalBufferedDurationIncludingCurrentSegment() -> TimeInterval {
        let completedDuration = segments.reduce(0) { $0 + $1.durationSeconds }

        guard let currentSegment else {
            return completedDuration
        }

        let activeDuration = max(CMTimeGetSeconds(segmentDuration(for: currentSegment)), 0)
        return completedDuration + activeDuration
    }

    private func makeSegmentURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferSegments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
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
            let segmentDuration = clampedDuration(segment.duration, to: assetDuration)
            guard CMTimeCompare(segmentDuration, .zero) > 0 else { continue }

            let timeRange = CMTimeRange(start: .zero, duration: segmentDuration)

            if let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack?.insertTimeRange(timeRange, of: sourceVideoTrack, at: cursor)
                let transform = try await sourceVideoTrack.load(.preferredTransform)
                videoTrack?.preferredTransform = transform
            }

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(timeRange, of: sourceAudioTrack, at: cursor)
            }

            cursor = cursor + segmentDuration
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
            accumulated += segment.durationSeconds

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
        updateBufferedDuration(totalBufferedDurationIncludingCurrentSegment())
    }

    private func alert(_ message: String) {
        DispatchQueue.main.async {
            self.onAlert?(message)
        }
    }
}

extension ReplayBufferRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if output === videoDataOutput {
            handleVideoSampleBuffer(sampleBuffer)
        } else if output === audioDataOutput {
            handleAudioSampleBuffer(sampleBuffer)
        }
    }

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid else { return }

        if let currentSegment, pendingCameraPosition != nil {
            append(sampleBuffer: sampleBuffer, to: currentSegment, mediaType: .video)
            let exportDuration = pendingExportDuration
            pendingExportDuration = nil
            finishCurrentSegment(exportDuration: exportDuration)
            return
        }

        if let currentSegment {
            let projectedEndTime = sampleEndTime(for: sampleBuffer)
            let effectiveEndTime = projectedEndTime.isValid ? projectedEndTime : timestamp
            let projectedDuration = max(
                CMTimeGetSeconds(CMTimeSubtract(effectiveEndTime, currentSegment.startedAt)),
                0
            )

            if forceSegmentRollover || projectedDuration >= segmentDuration {
                let exportDuration = pendingExportDuration
                pendingExportDuration = nil
                finishCurrentSegment(exportDuration: exportDuration)
            }
        }

        guard shouldContinueRecording else { return }

        if currentSegment == nil {
            do {
                try startSegment(with: sampleBuffer)
            } catch {
                shouldContinueRecording = false
                updateRecordingState(false)
                alert(error.localizedDescription)
                return
            }
        }

        if let currentSegment {
            append(sampleBuffer: sampleBuffer, to: currentSegment, mediaType: .video)
        }
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard shouldContinueRecording, let currentSegment else { return }
        append(sampleBuffer: sampleBuffer, to: currentSegment, mediaType: .audio)
    }
}

private enum RecorderError: LocalizedError {
    case cameraUnavailable
    case microphoneUnavailable
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotAddVideoOutput
    case cannotAddAudioOutput
    case cannotConfigureCamera
    case cannotCreateSegmentWriter
    case noSegmentsToExport
    case cannotCreateExportSession
    case photoLibrarySaveFailed

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "The requested camera is not available on this device."
        case .microphoneUnavailable:
            return "The microphone is not available on this device."
        case .cannotAddVideoInput:
            return "The app could not attach the video input."
        case .cannotAddAudioInput:
            return "The app could not attach the audio input."
        case .cannotAddVideoOutput:
            return "The app could not create the video capture output."
        case .cannotAddAudioOutput:
            return "The app could not create the audio capture output."
        case .cannotConfigureCamera:
            return "The selected camera could not be configured."
        case .cannotCreateSegmentWriter:
            return "The app could not create the rolling segment writer."
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
