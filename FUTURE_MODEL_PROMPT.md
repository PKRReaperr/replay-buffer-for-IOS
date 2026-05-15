# Future Model Recovery Prompt

Copy and paste the prompt below into a future Codex/ChatGPT session after opening this repository:

```text
You are working on this ReplayBuffer iOS repository. Before doing anything else, rebuild your understanding of the project from the repo itself rather than relying on assumptions.

First, read these files in this order:
1. AI_CONTEXT.md
2. README.md
3. iOS-PRD.md
4. ReplayBuffer/ReplayBufferRecorder.swift
5. ReplayBuffer/ReplayBufferViewModel.swift
6. ReplayBuffer/ContentView.swift
7. ReplayBuffer/CameraPreviewView.swift
8. ReplayBuffer/Info.plist

Then check:
- git status
- any uncommitted changes
- any differences between the codebase and AI_CONTEXT.md

After that, give me a concise project orientation that includes:
- what the app does
- the design ideology
- the architecture and on-device "backend" structure
- the most important files
- any important current caveats, risks, or local changes

Important project assumptions to preserve unless I explicitly ask you to change them:
- This is an iOS replay-buffer camera app, not a general-purpose camera app.
- The preview should remain dominant and the UI should feel close to the native iPhone Camera app.
- Buffering should not auto-start on launch.
- The camera preview should stay live before, during, and after buffering whenever possible.
- The app is local-first and has no remote backend; the "backend" is the on-device AVFoundation capture/export pipeline.
- Replay export correctness, segment timing, and audio/video sync are sensitive areas.
- Real iPhone behavior matters more than Simulator behavior for camera issues.
- Avoid large blocking overlays; prefer compact camera-like controls.

If AI_CONTEXT.md and the code disagree, trust the current code, point out the mismatch, and update your understanding accordingly.

If there are uncommitted changes, summarize them before making new edits so we do not lose important local work.

Once you have done the orientation, wait for my next instruction or continue directly if I already asked for a specific change.
```

## Notes

- `AI_CONTEXT.md` is the main long-form handoff file for this project.
- This prompt is designed to help a future model recover context quickly even if prior chat history is gone.
- If the project grows, update both this file and `AI_CONTEXT.md` together.
