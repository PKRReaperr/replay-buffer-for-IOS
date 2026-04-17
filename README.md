# Replay Buffer iOS

SwiftUI iPhone app for capturing the recent past with a replay-buffer workflow.

## What it does

- Opens the back camera with a live preview.
- Starts idle and waits for the user to tap `Start Buffering`.
- Continuously records short rolling `.mov` segments while buffering is active.
- Keeps the latest five minutes of footage in a local buffer.
- Lets the user choose how much recent footage to save, from 10 seconds to 5 minutes.
- Saves the exported replay clip to the Photos library.

## Run it

- Open [ReplayBuffer.xcodeproj](/C:/Users/rayya/Desktop/apps/extra%20files/pkrreaperr-portfolio/replay-buffer-for-IOS/ReplayBuffer.xcodeproj) in Xcode on macOS.
- Update the bundle identifier and signing team before installing on a device.
- Build and run on a physical iPhone for real camera testing.

## Notes

- Buffering now starts only after the user taps the record control.
- If the app leaves the foreground, buffering stops safely instead of continuing unexpectedly.
- The Android version now lives in its own sibling repo folder, `replay-buffer-android`.
