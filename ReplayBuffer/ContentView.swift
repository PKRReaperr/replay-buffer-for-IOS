import Foundation
import SwiftUI

private enum ActiveCameraMenu {
    case replay
    case controls
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ReplayBufferViewModel()
    @State private var activeMenu: ActiveCameraMenu?
    @State private var pinchStartZoomFactor: Double?

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(pinchGesture)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeMenu = nil
                    }
                }

            previewGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                menuLayer
                Spacer()
                statusPill
                zoomStrip
                bottomControls
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 14)
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

    private var previewGradient: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.34),
                Color.clear,
                Color.black.opacity(0.14),
                Color.black.opacity(0.58)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var topBar: some View {
        HStack {
            CameraChromeButton(
                systemName: "gobackward",
                isSelected: activeMenu == .replay,
                action: { toggleMenu(.replay) }
            )

            Spacer()

            CameraChromeButton(
                systemName: "slider.horizontal.3",
                isSelected: activeMenu == .controls,
                action: { toggleMenu(.controls) }
            )
        }
    }

    @ViewBuilder
    private var menuLayer: some View {
        HStack(alignment: .top) {
            if activeMenu == .replay {
                replayMenu
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Spacer()
                    .frame(width: 0, height: 0)
            }

            Spacer()

            if activeMenu == .controls {
                controlsMenu
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: activeMenu)
        .padding(.top, 12)
    }

    private var replayMenu: some View {
        CameraMenuCard(title: "Replay", accessory: viewModel.formattedReplayDuration, width: 244) {
            VStack(alignment: .leading, spacing: 12) {
                Slider(
                    value: $viewModel.replayDurationSeconds,
                    in: viewModel.minimumReplayDuration...viewModel.maximumReplayDuration,
                    step: 5
                )
                .tint(.yellow)

                HStack(spacing: 8) {
                    ForEach([30.0, 60.0, 120.0, 180.0], id: \.self) { preset in
                        Button(viewModel.label(for: preset)) {
                            viewModel.replayDurationSeconds = preset
                        }
                        .buttonStyle(CameraChipStyle(isSelected: abs(viewModel.replayDurationSeconds - preset) < 0.5))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.targetBufferedLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))

                    ProgressView(value: viewModel.bufferProgress)
                        .tint(.red)
                }
            }
        }
    }

    private var controlsMenu: some View {
        CameraMenuCard(title: "Controls", accessory: viewModel.cameraPosition.label, width: 268) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Zoom")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(viewModel.formattedZoomFactor)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.84))
                    }

                    Slider(
                        value: Binding(
                            get: { viewModel.normalizedZoomValue },
                            set: { viewModel.setNormalizedZoomValue($0) }
                        ),
                        in: 0...1
                    )
                    .tint(.yellow)
                    .disabled(viewModel.maximumZoomFactor <= viewModel.minimumZoomFactor)

                    Text("Pinch anywhere on the preview for smooth zoom.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                }

                Divider()
                    .overlay(Color.white.opacity(0.14))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Stabilization")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    if viewModel.availableStabilizationModes == [.off] {
                        Text("Adjustable stabilization is unavailable on this camera.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                    } else {
                        let columns = [
                            GridItem(.flexible(minimum: 76), spacing: 8),
                            GridItem(.flexible(minimum: 76), spacing: 8)
                        ]

                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(viewModel.availableStabilizationModes) { mode in
                                Button(mode.label) {
                                    viewModel.setStabilizationMode(mode)
                                }
                                .buttonStyle(CameraChipStyle(isSelected: viewModel.selectedStabilizationMode == mode))
                            }
                        }
                    }
                }
            }
        }
    }

    private var statusPill: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isSaving ? Color.yellow : (viewModel.isRecording ? Color.red : Color.white.opacity(0.84)))
                    .frame(width: 8, height: 8)

                Text(viewModel.statusBadgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)

                Text("|")
                    .foregroundStyle(.white.opacity(0.5))

                Text(viewModel.targetBufferedLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())

            Text(viewModel.statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var zoomStrip: some View {
        if !viewModel.zoomPresets.isEmpty {
            HStack(spacing: 10) {
                ForEach(viewModel.zoomPresets, id: \.self) { preset in
                    Button {
                        viewModel.setZoomFactor(preset)
                    } label: {
                        Text(zoomPresetLabel(for: preset))
                            .font(.caption.weight(abs(viewModel.zoomFactor - preset) < 0.1 ? .bold : .semibold))
                            .foregroundStyle(abs(viewModel.zoomFactor - preset) < 0.1 ? Color.yellow : Color.white)
                            .frame(minWidth: 42)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.32), in: Capsule())
            .padding(.bottom, 14)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                UtilityButton(
                    systemName: "arrow.down.circle.fill",
                    title: "Save",
                    isEnabled: viewModel.canSaveReplay,
                    action: viewModel.saveReplay
                )

                Spacer()

                Button {
                    viewModel.toggleRecording()
                } label: {
                    ShutterButton(isRecording: viewModel.isRecording)
                }
                .buttonStyle(.plain)

                Spacer()

                UtilityButton(
                    systemName: "arrow.triangle.2.circlepath.camera.fill",
                    title: viewModel.cameraPosition == .back ? "Flip" : "Rear",
                    isEnabled: viewModel.canSwitchCamera,
                    action: viewModel.switchCamera
                )
            }

            Text("REPLAY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
                .tracking(1.2)
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchStartZoomFactor == nil {
                    pinchStartZoomFactor = viewModel.zoomFactor
                }

                viewModel.handlePinch(scale: scale, startingZoomFactor: pinchStartZoomFactor ?? viewModel.zoomFactor)
            }
            .onEnded { _ in
                pinchStartZoomFactor = nil
            }
    }

    private func toggleMenu(_ menu: ActiveCameraMenu) {
        withAnimation(.easeInOut(duration: 0.18)) {
            activeMenu = activeMenu == menu ? nil : menu
        }
    }
}

private func zoomPresetLabel(for preset: Double) -> String {
    if abs(preset.rounded() - preset) < 0.05 {
        return "\(Int(preset.rounded()))x"
    }

    return String(format: "%.1fx", preset)
}

private struct CameraChromeButton: View {
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background((isSelected ? Color.white.opacity(0.22) : Color.black.opacity(0.24)), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CameraMenuCard<Content: View>: View {
    let title: String
    let accessory: String
    let width: CGFloat
    let content: Content

    init(
        title: String,
        accessory: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text(accessory)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }

            content
        }
        .padding(16)
        .frame(width: width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct CameraChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isSelected
                    ? Color.white
                    : Color.white.opacity(configuration.isPressed ? 0.24 : 0.12),
                in: Capsule()
            )
    }
}

private struct UtilityButton: View {
    let systemName: String
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .medium))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.34))
            .frame(width: 60, height: 60)
            .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct ShutterButton: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.16))
                .frame(width: 90, height: 90)

            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 84, height: 84)

            Group {
                if isRecording {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isRecording)
        }
    }
}

#Preview {
    ContentView()
}
