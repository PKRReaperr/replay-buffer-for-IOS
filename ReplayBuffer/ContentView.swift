import Foundation
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ReplayBufferViewModel()

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                header
                Spacer()
                controls
            }
            .padding(20)
        }
        .task {
            await viewModel.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhase(newPhase)
        }
        .alert("Replay Buffer", isPresented: $viewModel.showingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.alertMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Replay Buffer")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(viewModel.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Buffered")
                    Spacer()
                    Text("\(viewModel.formattedBufferedDuration) / \(viewModel.formattedReplayDuration)")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

                ProgressView(value: viewModel.bufferProgress)
                    .tint(.red)
            }

            HStack(spacing: 10) {
                Label(viewModel.isRecording ? "Recording" : "Stopped", systemImage: viewModel.isRecording ? "record.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(viewModel.isRecording ? .red : .white.opacity(0.75))

                if viewModel.isSaving {
                    Label("Saving clip", systemImage: "square.and.arrow.down.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Replay Length")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(viewModel.formattedReplayDuration)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Slider(
                    value: $viewModel.replayDurationSeconds,
                    in: viewModel.minimumReplayDuration...viewModel.maximumReplayDuration,
                    step: 5
                )
                .tint(.red)

                HStack {
                    ForEach([30.0, 60.0, 120.0, 180.0], id: \.self) { preset in
                        Button(viewModel.label(for: preset)) {
                            viewModel.replayDurationSeconds = preset
                        }
                        .buttonStyle(PresetButtonStyle(isSelected: abs(viewModel.replayDurationSeconds - preset) < 0.5))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Zoom")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Spacer()

                    Text(viewModel.formattedZoomFactor)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }

                Slider(
                    value: Binding(
                        get: { viewModel.zoomFactor },
                        set: { viewModel.setZoomFactor($0) }
                    ),
                    in: viewModel.minimumZoomFactor...viewModel.maximumZoomFactor
                )
                .tint(.yellow)
                .disabled(viewModel.maximumZoomFactor <= viewModel.minimumZoomFactor)

                if !viewModel.zoomPresets.isEmpty {
                    HStack {
                        ForEach(viewModel.zoomPresets, id: \.self) { preset in
                            Button {
                                viewModel.setZoomFactor(preset)
                            } label: {
                                Text(zoomPresetLabel(for: preset))
                            }
                            .buttonStyle(PresetButtonStyle(isSelected: abs(viewModel.zoomFactor - preset) < 0.1))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Stabilization")
                    .font(.headline)
                    .foregroundStyle(.white)

                if viewModel.availableStabilizationModes == [.off] {
                    Text("This lens does not expose adjustable stabilization on the current device.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    let columns = [
                        GridItem(.flexible(minimum: 80), spacing: 8),
                        GridItem(.flexible(minimum: 80), spacing: 8)
                    ]

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.availableStabilizationModes) { mode in
                            Button(mode.label) {
                                viewModel.setStabilizationMode(mode)
                            }
                            .buttonStyle(PresetButtonStyle(isSelected: viewModel.selectedStabilizationMode == mode))
                        }
                    }
                }
            }

            Button {
                viewModel.toggleRecording()
            } label: {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "record.circle.fill")
                    Text(viewModel.isRecording ? "Stop Buffering" : "Start Buffering")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button {
                viewModel.saveReplay()
            } label: {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("Save Last \(viewModel.formattedReplayDuration)")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .disabled(!viewModel.canSaveReplay)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private func zoomPresetLabel(for preset: Double) -> String {
    if abs(preset.rounded() - preset) < 0.05 {
        return "\(Int(preset.rounded()))x"
    }

    return String(format: "%.1fx", preset)
}

private struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.white : Color.white.opacity(configuration.isPressed ? 0.28 : 0.15))
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .clipShape(Capsule())
    }
}

#Preview {
    ContentView()
}
