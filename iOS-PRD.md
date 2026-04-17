# ReplayBuffer iOS PRD

## Product Summary

ReplayBuffer for iOS is a camera app that continuously keeps a rolling local buffer of recent video while the user chooses when to actively record into that buffer. When the user taps save, the app exports the most recent user-selected duration, such as 30 seconds or 2 minutes, into the Photos library.

The product is designed for moments that happen unexpectedly and need to be captured after the fact, similar to a replay buffer in gaming or action cameras.

## Problem

Important moments often happen before the user can hit record. Traditional camera apps are optimized for recording forward from the moment the user presses the button, not for saving what just happened.

Users need a fast camera tool that:

- shows a live preview
- lets them start and stop buffering intentionally
- keeps only a recent rolling window instead of recording endlessly into storage
- lets them instantly save the last N seconds or minutes after something happens

## Vision

Create an iPhone camera experience focused on one job: saving the recent past.

The app should feel like a simplified native camera app, with a full-screen preview, minimal translucent controls, obvious recording state, and one clear mode: replay buffer.

## Goals

- Let the user start buffering with one tap and stop buffering with one tap.
- Let the user save a recent clip without needing to predict the moment in advance.
- Support configurable replay durations from 10 seconds up to 5 minutes.
- Make the interface feel familiar to iPhone users.
- Keep the saved clip export flow fast and reliable on-device.

## Non-Goals

- Full multi-mode camera functionality like photo, portrait, or standard long-form video mode.
- Social editing tools, filters, stickers, or transitions.
- Cloud backup, sharing feeds, or account systems in v1.
- Background recording while the app is closed or suspended.
- Multi-camera capture in v1.

## Target Users

- Parents trying to capture brief unexpected moments.
- Pet owners who want to save funny behavior after it happens.
- Sports, skating, cycling, and action users who want instant replay-style saves.
- Creators who want a quick “save what just happened” camera utility.

## Core User Stories

- As a user, I want to open the app and see a live camera preview immediately.
- As a user, I want buffering to start only when I choose, not automatically on launch.
- As a user, I want to choose how much recent footage to save.
- As a user, I want to know clearly whether the app is currently buffering.
- As a user, I want to see how full the current replay buffer is relative to my selected target.
- As a user, I want to tap one button and save the last selected duration to Photos.
- As a user, I want the app to stop gracefully and preserve expected behavior if I leave the screen or revoke permission.

## Primary Use Flow

1. User opens the app.
2. App requests camera, microphone, and Photos permissions if needed.
3. User sees a live back-camera preview and idle state.
4. User selects a replay duration, such as 30 seconds, 1 minute, or 2 minutes.
5. User taps record to begin buffering.
6. App continuously records short rolling segments and maintains only the latest configured buffer window.
7. UI shows recording state and buffer-fill progress.
8. User taps save after a moment happens.
9. App finalizes the current segment, stitches the newest qualifying footage, trims to the chosen replay length, and saves the clip to Photos.
10. User receives clear success or failure feedback.

## UX Requirements

### Layout

- Full-screen camera preview.
- Minimal translucent overlays similar to the native iPhone camera feel.
- Single mode only: replay buffer.
- Bottom-centered primary shutter control.
- Secondary controls aligned cleanly and consistently.

### Recording State

- App launches idle by default.
- A red recording indicator is visible only while buffering is active.
- The shutter changes appearance between idle and active buffering states.
- Non-essential controls may fade while actively buffering, but must remain recoverable with a tap.

### Replay Controls

- Quick duration presets should be available, with at least `30s`, `1 min`, and `2 min`.
- A more granular control can also exist for durations between 10 seconds and 5 minutes.
- The save action should be clearly separate from the start/stop buffering action.

### Buffer Progress

- Show progress toward the selected replay duration, not just the current short recording segment.
- Example: if target duration is `30s`, the progress display should fill from `0s / 30s` to `30s / 30s` and then remain capped.

### Camera Controls

- Include lightweight manual-style controls appropriate for iPhone, such as exposure adjustment and optional torch.
- If shutter/exposure presets are supported, they must behave as optional adjustments and not distract from the replay workflow.

## Functional Requirements

### Recording and Buffering

- The app must use the back camera by default.
- The app must support microphone audio capture in saved replay clips.
- The app must record in short segments to simplify rolling-buffer management.
- The app must keep only the most recent configured rolling window, up to a maximum of 5 minutes in v1.
- The app must not begin buffering automatically on launch.

### Saving

- When the user taps save, the app must finalize the current segment before export.
- The app must select the newest footage that satisfies the requested duration.
- The saved clip must be trimmed to the chosen replay duration as closely as practical.
- The exported replay must be written to the Photos library.
- The user must receive a success or failure message after export.

### Permissions

- Camera permission is required.
- Microphone permission is required if replay clips include audio.
- Photos permission is required to save exported clips.
- Permission-denied states must present clear recovery guidance.

### App Lifecycle

- If the app goes inactive, the app should stop buffering safely.
- If buffering stops due to interruption, the UI must reflect the stopped state.
- Temporary cached segments should be cleaned up when no longer needed.

## Technical Requirements

- Platform: iPhone on iOS.
- UI framework: SwiftUI.
- Camera stack: AVFoundation.
- Export pipeline: AVAsset-based segment merge and trim workflow.
- Local storage:
  - temporary rolling segments stored in app-managed cache
  - final replay written to Photos
- Default segment size target:
  - short fixed segments, such as 5 seconds, unless performance testing suggests a better value

## Constraints and Risks

- iOS background execution limits prevent true always-on recording when the app is not active.
- Segment stitching and export time may increase with longer replay durations.
- Storage pressure must be managed carefully because repeated segment creation can grow quickly.
- Real-device camera behavior may differ from Simulator behavior; physical iPhone testing is required.
- Audio and video sync must be verified on exported clips.

## Success Criteria

- User can start buffering within 2 taps from launch.
- User can save a recent clip within 1 tap once the buffer contains enough footage.
- Export succeeds reliably for common preset lengths like 30 seconds, 1 minute, and 2 minutes.
- Buffer progress display never exceeds the selected replay duration.
- The app clearly communicates idle, buffering, saving, success, and failure states.

## V1 Scope

- Back-camera preview
- Start/stop buffering
- Replay duration presets and selection
- Buffer progress indicator
- Save recent replay to Photos
- Red recording indicator
- Basic exposure and torch controls
- Clear permission handling

## Post-V1 Ideas

- Front/back camera switching
- Frame-rate and quality settings
- Optional haptic cues for save and state changes
- Clip review screen before saving
- Lock screen or Action Button shortcut
- Home Screen widget or Shortcut support
- Auto-save highlight events triggered by external accessories

## Open Questions

- Should the default replay duration be 30 seconds or 1 minute?
- Should audio always be recorded, or should there be a mute option?
- Should save export happen silently, or should the user see a lightweight progress indicator during export?
- Should manual exposure controls remain visible in v1, or move behind a compact adjustment drawer?
- Should the app stop buffering automatically after a period of inactivity to reduce battery drain?

## Milestones

### Milestone 1: Core Capture

- live preview
- manual start and stop buffering
- rolling segment capture
- save recent replay

### Milestone 2: Camera UX

- refined full-screen camera UI
- recording indicator
- fade-away controls
- duration presets and buffer progress

### Milestone 3: Reliability

- Photos save handling
- interruption and permission recovery
- real-device validation
- performance and storage cleanup tuning
