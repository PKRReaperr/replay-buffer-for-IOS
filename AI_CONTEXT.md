# ReplayBuffer iOS: Full AI Context

## Purpose

This document is a single-file context handoff for AI models working on the iOS ReplayBuffer app. It explains what the app is, why it exists, how the UI is supposed to feel, how the internal architecture works, and what constraints matter when changing the code.

The goal is to let another model understand the app quickly without needing to rediscover the entire codebase from scratch.

## One-Sentence Product Summary

ReplayBuffer is an iPhone camera app that continuously keeps a short rolling local buffer of the recent past, then lets the user save the last N seconds or minutes to Photos after the interesting moment has already happened.

## Core Product Idea

Traditional camera apps start recording from the moment the user taps record. ReplayBuffer is designed around the opposite need: a user notices that something important just happened and wants to save the recent past.

The app is intentionally narrow in scope:

- one primary mode: replay buffer
- one primary job: save what just happened
- one main device target: iPhone on a real camera-capable device
- one storage model: temporary rolling cache plus exported clip to Photos

The product is closer to a replay system in gaming, action cams, or dashcam logic than to a full-featured camera suite.

## Design Ideology

The design language is meant to feel close to the native iPhone Camera app, but simplified around replay capture rather than photo/video modes.

Key design principles:

- The camera preview is the product, so the preview should dominate the screen.
- Controls should be minimal, translucent, and camera-like rather than looking like a generic settings form.
- Buffering is intentional. The app should not silently start recording on launch.
- Status should be obvious. Users should always know whether the app is idle, buffering, switching cameras, preparing a replay, or saving.
- Replay-specific controls should stay lightweight and fast to access.
- Manual controls are secondary to the replay workflow. If a control adds clutter without helping replay capture, it should probably be hidden, simplified, or removed.

In practical UI terms, that means:

- full-screen preview
- small chrome in the corners
- bottom-centered shutter
- compact save and camera-flip actions
- replay duration tucked into a menu, not shown as a giant overlay
- zoom and gesture behavior that feels camera-native instead of slider-heavy

## Current App Scope

The current iOS app supports:

- live camera preview
- manual start/stop of buffering
- rolling local capture with short segments
- replay duration selection from 10 seconds to 5 minutes
- save to Photos
- rear/front camera switching
- zoom presets and pinch zoom
- camera stabilization mode selection when supported
- buffer progress feedback
- lifecycle-safe stop behavior when the app leaves the foreground

The app does not currently include:

- cloud sync
- accounts
- social sharing workflows
- background recording while the app is suspended
- a server backend
- true multi-camera capture
- an in-app clip review/editor flow

## Important Reality: There Is No Remote Backend

There is no web server, database, or network API in this app.

When someone says "backend" for this codebase, they really mean the on-device camera/capture/export pipeline. The entire system is local to the phone.

The effective backend layers are:

1. AVFoundation capture session setup
2. camera and microphone sample capture
3. rolling temporary segment writing
4. replay segment selection and composition
5. AVAsset export
6. Photos library save

Everything happens on-device.

## Tech Stack

- Platform: iOS
- Deployment target: iOS 17.0
- Language: Swift 5
- UI framework: SwiftUI
- Lower-level UI bridge: UIKit where needed for preview/gestures
- Camera stack: AVFoundation
- Media export: AVAssetWriter, AVMutableComposition, AVAssetExportSession
- Photo saving: Photos framework

There are no third-party dependencies in the current app.

## Repository Shape

Main files:

- `ReplayBuffer/ReplayBufferApp.swift`
- `ReplayBuffer/ContentView.swift`
- `ReplayBuffer/ReplayBufferViewModel.swift`
- `ReplayBuffer/ReplayBufferRecorder.swift`
- `ReplayBuffer/CameraPreviewView.swift`
- `ReplayBuffer/Info.plist`
- `iOS-PRD.md`
- `README.md`

### File Responsibilities

`ReplayBufferApp.swift`

- minimal app entry point
- launches `ContentView`

`ContentView.swift`

- main camera UI
- owns top menus, bottom controls, status pill, zoom strip, and camera-like chrome
- hosts the full-screen preview layer
- bridges tap and pinch gestures through a `UIViewRepresentable`

`ReplayBufferViewModel.swift`

- UI-facing state holder
- owns published state for status, recording state, saving state, selected replay duration, zoom, stabilization options, and camera position
- forwards user intents to the recorder
- translates recorder callback events into main-thread SwiftUI state

`ReplayBufferRecorder.swift`

- real operational core of the app
- owns `AVCaptureSession`
- configures audio/video inputs and outputs
- manages rolling segment recording
- handles front/rear camera switching
- applies zoom and stabilization
- composes and exports recent replay clips
- saves finished replays to Photos

`CameraPreviewView.swift`

- small UIKit bridge that exposes `AVCaptureVideoPreviewLayer` inside SwiftUI

`Info.plist`

- permission usage strings
- portrait orientation support
- basic app metadata

`iOS-PRD.md`

- high-level product requirements and intended behavior

## Architecture Overview

The app uses a fairly simple three-layer structure:

1. SwiftUI View Layer
2. View Model / UI State Translation Layer
3. Recorder / Capture Pipeline Layer

### 1. SwiftUI View Layer

`ContentView` renders the camera experience.

It does not directly talk to AVFoundation. It reads published state from the view model and sends user actions back into the view model.

Examples of view responsibilities:

- showing the full-screen camera preview
- toggling the replay menu
- toggling the controls menu
- rendering the shutter button
- rendering save and flip buttons
- invoking pinch-to-zoom gestures
- presenting alerts

### 2. View Model Layer

`ReplayBufferViewModel` is the translation layer between UI and recorder internals.

It does three main jobs:

- exposes state in a SwiftUI-friendly form
- converts user interactions into recorder commands
- converts recorder callbacks into `@Published` values on the main actor

The view model is intentionally not where the media pipeline lives. It is primarily orchestration and presentation logic.

### 3. Recorder Layer

`ReplayBufferRecorder` is the actual engine.

This is where the app:

- requests permissions
- configures AVFoundation
- manages temporary segment files
- rolls the buffer window
- finishes segments
- selects recent footage
- builds a replay clip
- saves the final result to Photos

This file is the most important file in the repository.

## High-Level User Flow

1. App launches into `ContentView`.
2. `ReplayBufferViewModel.start()` runs on first appearance.
3. The recorder requests camera, microphone, and Photos-add permissions.
4. The recorder configures the `AVCaptureSession`.
5. The preview becomes live immediately, but buffering is still idle.
6. User taps the shutter to start buffering.
7. The recorder begins rolling segment capture.
8. The app continuously keeps only the newest part of the buffer window.
9. User taps Save.
10. The recorder finalizes the active segment, selects the newest footage needed, stitches it, trims it, exports it, and writes it to Photos.
11. User receives status text and alert feedback if needed.

## UI Structure

The UI is built around a camera-first composition:

- preview in the background
- gesture surface over the preview
- dark top/bottom gradient for readability
- top-left replay menu button
- top-right controls menu button
- center-bottom status pill
- zoom strip above bottom controls
- bottom row with Save, Shutter, and Flip

### Replay Menu

Contains:

- replay duration slider
- quick duration presets
- progress indicator showing buffered duration vs selected replay duration

### Controls Menu

Currently focused on stabilization settings for the active camera.

### Bottom Controls

- Save: export the most recent selected duration
- Shutter: start/stop buffering
- Flip: switch front/rear camera

### Gestures

`CameraInteractionSurface` is a `UIViewRepresentable` used to capture:

- tap to dismiss open menus
- pinch to zoom

This exists because camera-like gestures are easier to handle reliably with UIKit gesture recognizers than with a purely SwiftUI transparent overlay.

## State Model

Primary UI state in `ReplayBufferViewModel`:

- `replayDurationSeconds`
- `statusText`
- `isRecording`
- `isSaving`
- `bufferedDurationSeconds`
- `zoomFactor`
- `minimumZoomFactor`
- `maximumZoomFactor`
- `availableStabilizationModes`
- `selectedStabilizationMode`
- `cameraPosition`
- `showingAlert`
- `alertMessage`

The SwiftUI layer should generally not own capture-state truth directly. The recorder is the source of truth for operational state, and the view model mirrors it into published UI state.

## Recorder Internals

### Session Model

The recorder owns a single `AVCaptureSession`.

It configures:

- one audio input
- one video input
- one `AVCaptureVideoDataOutput`
- one `AVCaptureAudioDataOutput`

Preview is driven by the session through `AVCaptureVideoPreviewLayer`.

### Why Data Outputs Instead of AVCaptureMovieFileOutput

The current recorder uses video/audio sample buffer outputs plus `AVAssetWriter` segments rather than `AVCaptureMovieFileOutput`.

This matters because:

- it gives better control over rolling segments
- it keeps the preview live even when buffering stops
- it allows segment rollover without the camera UI feeling like it is stopping and restarting
- it makes camera switching during recording possible at segment boundaries
- it reduces visible export seams compared with naive stop/start movie recording

### Segment Strategy

The rolling buffer is built from short temporary `.mov` segments.

Current segment target:

- approximately 5 seconds per segment

Important state:

- `segments`: completed rolling segments
- `currentSegment`: segment actively being written
- `segmentDuration`: target length per segment
- `maximumBufferDuration`: cap of 300 seconds

Each completed segment stores:

- temp file URL
- measured media duration

The recorder prunes old segments so only the latest buffer window is retained.

### Segment Timing Detail

The recorder tracks video segment duration using the end time of appended video frames rather than only the last frame timestamp. This is important because boundary timing can otherwise be slightly wrong, which shows up as tiny hitches or cuts in exported replays.

The export path also clamps each stitched segment to the recorder's measured captured duration rather than blindly using the container file's full duration. This helps avoid tiny padded tails at segment boundaries.

## Capture and Buffering Flow

When buffering starts:

1. `shouldContinueRecording` becomes `true`
2. the session remains running
3. on the next video sample, the recorder creates a new `AVAssetWriter` segment
4. video and audio samples are appended in real time
5. once a segment reaches the rollover threshold, it is finished and a new one starts
6. old segments are pruned to keep the overall buffer within the max duration

When buffering stops:

1. `shouldContinueRecording` becomes `false`
2. the active segment is finished
3. preview remains live
4. UI returns to idle/ready state

This separation between preview and buffering is intentional. The app should feel like a camera that is still open even when replay capture is idle.

## Save / Export Flow

When the user taps Save:

1. If there is an active segment, the recorder forces a segment rollover.
2. The active segment is finalized.
3. A snapshot of recent completed segments is selected based on the requested replay duration.
4. A temporary `AVMutableComposition` is built.
5. Video and audio tracks from the selected segments are inserted in order.
6. The final composition is trimmed to the most recent requested duration.
7. `AVAssetExportSession` creates the output `.mov`.
8. The result is saved to Photos using `PHPhotoLibrary`.
9. The temporary exported file is deleted after save.

### Export Selection Logic

The app walks backward through the completed segments until it has enough recent footage to satisfy the requested replay duration, then reverses that list to preserve chronological order.

This means export is "most recent footage first" in terms of selection, but the final clip remains ordered from oldest to newest within the saved replay.

## Camera Switching Behavior

The app supports switching between rear and front cameras.

Behavior:

- if idle: switch immediately
- if actively buffering: mark a pending camera switch, finish the current segment, switch camera, then continue on the next segment boundary

This avoids corrupting a segment mid-write.

## Zoom Model

Zoom is camera-style, not document-style.

Important characteristics:

- zoom is clamped between 1x and the lesser of device max zoom or 10x
- quick presets currently expose values like 1x, 2x, 5x, 10x when supported
- pinch gestures multiply from the zoom level at pinch start
- the view model also contains non-linear/logarithmic mapping helpers for camera-like zoom scaling

Note:

- the current UI primarily exposes quick zoom presets and pinch
- rear zoom currently starts from the wide camera at 1x
- true sub-1x ultra-wide behavior is not currently modeled

## Stabilization Model

The app exposes stabilization mode choices only if the active camera format supports them.

Supported app-level enum values:

- `off`
- `standard`
- `cinematic`
- `auto`

The recorder resolves unsupported selections back to safe supported values.

## Permissions Model

The app asks for:

- camera access
- microphone access
- Photos add-only access

All three are currently treated as required for normal operation.

If permissions are denied:

- startup status text reflects the failure
- an alert explains what is needed

`Info.plist` contains the usage strings for:

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`
- `NSPhotoLibraryAddUsageDescription`

## Lifecycle Behavior

The app should not continue buffering when it is no longer active.

Current behavior:

- preview session is configured and can remain live while the app is active
- if scene phase becomes non-active while buffering is on, the view model tells the recorder to stop

This is meant to be safe, unsurprising, and consistent with iOS lifecycle limitations.

## Storage Model

There are two kinds of stored media:

1. temporary rolling segments
2. final exported replay clip

Temporary segments:

- live in `FileManager.default.temporaryDirectory/ReplayBufferSegments`
- are app-managed cache files
- are pruned as the rolling buffer advances
- are deleted on recorder release

Final exported clip:

- is created temporarily in the app temp directory
- is then saved to the Photos library
- temporary export file is removed after save

There is no long-term in-app media library yet.

## Concurrency Model

The app uses a hybrid concurrency model.

Key pieces:

- UI state lives on `@MainActor` in the view model
- recorder operational work is serialized on `sessionQueue`
- export work uses `exportQueue`
- async permission and export APIs are bridged with continuations

The recorder is marked `@unchecked Sendable`, which means future edits should be careful not to casually introduce race conditions.

General rule:

- UI updates go to main
- capture session and writer state changes stay on `sessionQueue`

## Performance and Reliability Constraints

This app is sensitive to real-device behavior.

Important constraints:

- Simulator is not a reliable test environment for rear-camera behavior
- AVFoundation timing can differ across devices
- segment merge/export cost grows with replay length
- audio/video sync must be preserved across rolling segments
- segment boundaries are the most fragile part of the pipeline
- camera switching during buffering must happen only at safe boundaries

## Known Design/Architecture Tradeoffs

1. Simplicity over generalized camera features
The app intentionally does not try to be a full Blackmagic-style camera or a clone of the full iPhone Camera app. It borrows familiar UX cues but stays replay-first.

2. Segment-based buffering over monolithic recording
Small rolling files are easier to manage and export selectively, but segment boundaries need careful timing work.

3. Local-only architecture
This keeps the app private and simple, but also means there is no server-side recovery, indexing, or sync.

4. SwiftUI UI with targeted UIKit bridges
SwiftUI drives the app, but UIKit is used where it improves camera behavior, such as preview hosting and gesture capture.

## Current Product/Engineering Assumptions

An AI making changes should preserve these assumptions unless explicitly asked to change them:

- the app should open into a live camera preview
- buffering should not auto-start on launch
- the UI should stay camera-first and minimally obstructive
- replay save should feel like a fast one-action operation
- preview should remain live before, during, and after buffering
- no network/backend should be introduced unless explicitly requested
- temporary segment cleanup is required
- changes should be validated with a real iPhone whenever camera behavior is involved

## If Another AI Needs to Modify This App

Read these files first, in this order:

1. `ReplayBuffer/ReplayBufferRecorder.swift`
2. `ReplayBuffer/ReplayBufferViewModel.swift`
3. `ReplayBuffer/ContentView.swift`
4. `iOS-PRD.md`
5. `README.md`

When changing behavior:

- if it affects capture/export correctness, start in the recorder
- if it affects displayed state, start in the view model
- if it affects layout/chrome/interaction, start in `ContentView`

When proposing UI changes:

- keep the preview dominant
- avoid large blocking panels
- prefer compact camera-like controls
- preserve obvious recording/saving state visibility

When proposing architecture changes:

- do not add remote services unless requested
- keep capture session work off the main thread
- preserve the rolling-buffer mental model
- be careful around segment timing and export boundaries

## Gaps and Likely Next Areas of Work

Likely future work includes:

- further smoothing of replay export seams under real-device testing
- ultra-wide or more advanced lens switching
- exposure/torch controls if desired
- haptics
- an optional preview-before-save flow
- more native-camera-like zoom UI behavior
- additional capture quality/frame-rate controls

## Short Summary for Prompting Another Model

If you need a compact prompt-ready summary, use this:

"This is an iOS 17 SwiftUI replay-camera app called ReplayBuffer. It opens to a live preview, stays idle until the user starts buffering, then captures rolling 5-second local video/audio segments with AVFoundation and AVAssetWriter. It keeps up to 5 minutes of recent footage, lets the user choose a replay duration from 10 to 300 seconds, and exports the newest qualifying footage to Photos by stitching recent segments with AVMutableComposition and AVAssetExportSession. The UI is intentionally camera-like: full-screen preview, compact translucent controls, bottom shutter/save/flip controls, pinch zoom, zoom presets, and stabilization options. There is no server backend; all logic is on-device. The most important file is ReplayBufferRecorder.swift."
