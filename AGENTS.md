# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, …) working on IVY.

## Project in one paragraph

IVY is a native macOS (Swift, SwiftUI + AppKit) assistant that lives in the MacBook notch. Local inference (Qwen3-4B via MLX-LM, MLX Whisper, Kokoro via mlx-audio) runs in a bundled Python sidecar (`IVY/IVY/Resources/Engine/ivy_engine.py`). The app talks to it over JSON Lines on stdio (`EngineProcess.swift`). Platform-independent logic lives in the `IVYKit` Swift package (`IVYCore`) and is unit-tested.

## Layout

| Path | What |
| --- | --- |
| `IVY/IVY.xcodeproj` | Xcode project. The `IVY/IVY` folder is a *file-system synchronized group*: new files there are compiled automatically, with no pbxproj edits needed. |
| `IVY/Config/` | `Info.plist` (usage strings) and entitlements. Keep these out of `IVY/IVY/` (a synchronized plist would be copied as a resource). |
| `IVY/IVY/` | App target: `App/`, `Core/` (engine, LLM, speech, TTS, input), `Services/`, `Tools/`, `UI/`. |
| `IVY/IVYKit/` | `IVYCore` library + `IVYCoreTests`. |
| `IVY/IVY/Resources/Engine/` | Python engine and runtime installer (bundled as resources). |

## Commands

```bash
# Unit tests (fast, no app launch)
cd IVY/IVYKit && swift test

# Build the app
cd IVY && xcodebuild -project IVY.xcodeproj -scheme IVY -configuration Debug build

# Smoke-test the engine directly (after the runtime + models are installed)
~/Library/Application\ Support/IVY/Runtime/venv/bin/python3 IVY/IVY/Resources/Engine/ivy_engine.py --role doctor
```

Debug builds include `DebugBridge` (distributed notification `com.ravoxx.IVY.debug`) for driving the UI without a keyboard: `submit`, `text`, `dashboard`, `dismiss`, `settings`, `audio`, and `demo scene=<reminders|music|listening|typing|claude|dashboard|shelf|live>` (sample content for README screenshots in `docs/screenshots/`). `faceid state=<armed|scanning|blink|success|failure|hide>` previews the Face ID notch overlay without a camera, and `askfile path=<file>` starts the shelf's "Ask IVY about this file" chat. It isn't compiled into Release builds.

## Conventions

- **Swift 5 language mode** with approachable concurrency. Default actor isolation is *nonisolated*. UI types and services that publish state are explicitly `@MainActor`; shared mutable state uses actors or locks.
- The project enables `MemberImportVisibility`: import what you use (`import os` for `Log`, `import Combine` for `ObservableObject`).
- Keep the build **warning-free**.
- Logging: use `Log.<category>` from `IVYCore`. Never log audio. Mark user text as `privacy: .private` (the default).
- Match the surrounding style: small focused types, doc comments where macOS behavior is non-obvious, no drive-by reformatting.

## Adding a tool

1. Add a name to `ToolName` (IVYCore) if the router or tests reference it.
2. Implement `IVYTool` in `IVY/IVY/Tools/`: a short `description`, typed `parameters`, `baseRisk`, and `isTerminal` (true when the summary is already the final answer).
3. Validate every argument. Never pass model text to a shell, AppleScript or Terminal. Use fixed templates and allowlists (`CommandAllowlist`).
4. Return a factual `summary` (one sentence) and an optional `ResultCard`.
5. Register it in `AppEnvironment.registerTools()`.
6. If the command is unambiguous, add a fast path in `CommandRouter` with tests in `CommandRouterTests`.

## Safety rules (do not weaken)

- High-risk actions must go through `SecurityPolicy` confirmation.
- IVY must never claim an action succeeded unless a tool result says so.
- No network access outside explicit features (model download, song lookup, web search tools) and never on by stealth.
- Voice responses (TTS) stay **off by default**.
- Face ID stays **off by default**, keeps its security notice and enable confirmation, never stores camera frames, and only types the password after a match plus liveness while `CGSession` reports the screen locked.

## Before you finish

- `swift test` passes, the app builds without warnings, and the README is updated if behavior changed.
