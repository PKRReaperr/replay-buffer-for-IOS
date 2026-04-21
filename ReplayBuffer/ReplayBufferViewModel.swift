import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class ReplayBufferViewModel: ObservableObject {
    @Published var replayDurationSeconds: Double = 30
    @Published private(set) var statusText = "Preparing camera..."
    @Published private(set) var isRecording = false
    @Published private(set) var isSaving = false
    @Published private(set) var bufferedDurationSeconds: Double = 0
    @Published private(set) var zoomFactor: Double = 1
    @Published private(set) var minimumZoomFactor: Double = 1
    @Published private(set) var maximumZoomFactor: Double = 1
    @Published private(set) var availableStabilizationModes: [CameraStabilizationMode] = [.off]
    @Published private(set) var selectedStabilizationMode: CameraStabilizationMode = .off
    @Published var showingAlert = false
    @Published var alertMessage = ""

    let minimumReplayDuration: Double = 10
    let maximumReplayDuration: Double = 300

    let captureSession = AVCaptureSession()

    private let recorder: ReplayBufferRecorder
    private var hasStarted = false

    init() {
        recorder = ReplayBufferRecorder(session: captureSession)

        recorder.onStatusChange = { [weak self] message in
            Task { @MainActor in
                self?.statusText = message
            }
        }

        recorder.onRecordingStateChange = { [weak self] isRecording in
            Task { @MainActor in
                self?.isRecording = isRecording
            }
        }

        recorder.onSaveStateChange = { [weak self] isSaving in
            Task { @MainActor in
                self?.isSaving = isSaving
            }
        }

        recorder.onBufferedDurationChange = { [weak self] duration in
            Task { @MainActor in
                self?.bufferedDurationSeconds = duration
            }
        }

        recorder.onZoomConfigurationChange = { [weak self] minimum, maximum, current in
            Task { @MainActor in
                self?.minimumZoomFactor = Double(minimum)
                self?.maximumZoomFactor = Double(maximum)
                self?.zoomFactor = Double(current)
            }
        }

        recorder.onAvailableStabilizationModesChange = { [weak self] modes in
            Task { @MainActor in
                self?.availableStabilizationModes = modes
            }
        }

        recorder.onSelectedStabilizationModeChange = { [weak self] mode in
            Task { @MainActor in
                self?.selectedStabilizationMode = mode
            }
        }

        recorder.onAlert = { [weak self] message in
            Task { @MainActor in
                self?.alertMessage = message
                self?.showingAlert = true
            }
        }
    }

    var formattedReplayDuration: String {
        label(for: replayDurationSeconds)
    }

    var formattedBufferedDuration: String {
        label(for: min(bufferedDurationSeconds, replayDurationSeconds))
    }

    var bufferProgress: Double {
        guard replayDurationSeconds > 0 else { return 0 }
        return min(bufferedDurationSeconds / replayDurationSeconds, 1)
    }

    var canSaveReplay: Bool {
        bufferedDurationSeconds > 0 && !isSaving
    }

    var formattedZoomFactor: String {
        if abs(zoomFactor.rounded() - zoomFactor) < 0.05 {
            return "\(Int(zoomFactor.rounded()))x"
        }

        return String(format: "%.1fx", zoomFactor)
    }

    var zoomPresets: [Double] {
        [1, 2, 5, 10]
            .filter { $0 >= minimumZoomFactor - 0.01 && $0 <= maximumZoomFactor + 0.01 }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        statusText = "Requesting camera permission..."

        let granted = await recorder.requestPermissions()
        guard granted else {
            statusText = "Camera, microphone, or photo library access is required."
            alertMessage = "Enable camera, microphone, and photo library access in Settings to use the replay buffer."
            showingAlert = true
            return
        }

        do {
            try await recorder.configureSession()
            statusText = "Camera ready. Tap record to start buffering."
        } catch {
            statusText = "Unable to start capture."
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    func toggleRecording() {
        if isRecording {
            recorder.stop()
        } else {
            recorder.start()
        }
    }

    func saveReplay() {
        recorder.exportRecentReplay(duration: replayDurationSeconds)
    }

    func setZoomFactor(_ zoomFactor: Double) {
        recorder.setZoomFactor(CGFloat(zoomFactor))
    }

    func setStabilizationMode(_ mode: CameraStabilizationMode) {
        recorder.setStabilizationMode(mode)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase != .active, isRecording else { return }
        recorder.stop()
    }

    deinit {
        recorder.release()
    }

    func label(for duration: Double) -> String {
        let totalSeconds = Int(duration.rounded())
        if totalSeconds >= 60 {
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return seconds == 0 ? "\(minutes) min" : "\(minutes)m \(seconds)s"
        }

        return "\(totalSeconds)s"
    }
}
