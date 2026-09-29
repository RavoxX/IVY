# IVY

**IVY is a private AI assistant that lives in your MacBook's notch.** Hold <kbd>⌘</kbd><kbd>⌥</kbd>, ask a question, and IVY answers from a dark panel that grows out of the notch. Speech recognition, the language model and text-to-speech all run **locally on Apple Silicon** with [MLX](https://github.com/ml-explore/mlx).

- 🎙️ **Voice or text** — hold <kbd>⌘</kbd><kbd>⌥</kbd> for 0.5 s to talk; release <kbd>⌘</kbd> and press it again to type.
- 🧠 **Local LLM** — Qwen3-4B (4-bit) via MLX-LM, with native tool calling.
- 👂 **Local speech-to-text** — MLX Whisper (large-v3-turbo).
- 🗣️ **Local TTS** — Kokoro-82M via MLX (`mlx-audio`). Off by default.
- ✅ **Reminders** — read, create and complete Apple Reminders through EventKit.
- 🎵 **Spotify** — play songs, pause, skip, volume and a now-playing card.
- 🚀 **Apps, files, URLs** — open apps, folders and websites.
- 👩‍💻 **Claude Code** — start a Claude Code (or Codex) session from a sentence.
- 🪄 **Notch dashboard** — hover the notch for a media player, a drag-and-drop file shelf with AirDrop, and history (inspired by [boring.notch](https://github.com/TheBoredTeam/boring.notch)).
- 🔒 **Private by default** — no cloud AI, no telemetry, no stored audio.

> IVY is an independent open-source project and is not affiliated with Apple, Spotify or Anthropic.

## Screenshots

| Assistant | Dashboard | Shelf |
| --- | --- | --- |
| *Answer panel growing out of the notch* | *Hover: media player, battery, settings* | *Drop files, AirDrop them* |

<!-- Add screenshots to docs/ and reference them here. -->

## Requirements

| | |
| --- | --- |
| Mac | Apple Silicon (M1 or later). Tuned for a fanless MacBook Air. |
| macOS | 26 or later |
| Xcode | 26 or later (Swift 6 toolchain) |
| Disk | ~5 GB for the runtime and default models |
| Memory | 8 GB works, 16 GB recommended |

IVY works on displays without a notch too — it attaches to the top center of the screen.

## Build & run

```bash
git clone https://github.com/RavoxX/IVY.git
cd IVY/IVY
open IVY.xcodeproj        # then Product ▸ Run (⌘R)
```

Or from the command line:

```bash
xcodebuild -project IVY/IVY.xcodeproj -scheme IVY -configuration Release build
```

Signing: the project uses automatic signing. Choose your own team under *Signing & Capabilities*. Use a stable identity (e.g. *Apple Development*) so macOS remembers the permissions you grant between builds.

### First launch

IVY opens a compact setup window:

1. Grant **Microphone** access (and optionally **Reminders** and **Input Monitoring**).
2. Detects Spotify and Claude Code.
3. **Install Runtime** creates a private Python environment with MLX packages (~600 MB).
4. **Download** the models. Sizes are shown before anything is downloaded:

| Model | Purpose | Size |
| --- | --- | --- |
| `mlx-community/Qwen3-4B-4bit` | Language model | ~2.3 GB |
| `mlx-community/whisper-large-v3-turbo` | Speech-to-text | ~1.6 GB |
| `mlx-community/Kokoro-82M-bf16` | Text-to-speech | ~0.37 GB |

Everything lives in `~/Library/Application Support/IVY/` (`Runtime/`, `Models/LLM`, `Models/Whisper`, `Models/Kokoro`). Nothing is downloaded silently.

The runtime installer can also be run manually:

```bash
bash IVY/IVY/Resources/Engine/setup_runtime.sh
```

## Using IVY

| Gesture | What happens |
| --- | --- |
| Hold <kbd>⌘</kbd><kbd>⌥</kbd> 0.5 s | IVY opens and listens. Release to ask. |
| Hold <kbd>⌘</kbd><kbd>⌥</kbd>, release <kbd>⌘</kbd>, press <kbd>⌘</kbd> again | Text field opens. Type and press <kbd>Return</kbd>. |
| Hover the notch | Dashboard: media player, shelf, history, battery, settings. |
| Drag files onto the notch | Opens the shelf; drop to keep them handy or AirDrop them. |
| <kbd>Esc</kbd> / click outside | Closes IVY. |

Try:

- “What's on my to-do list today?”
- “Remind me tomorrow at 5 to call Alex.”
- “Play Billie Jean.” · “Pause the music.” · “Next song.” · “What's playing?”
- “Open Safari.” · “Open Downloads.” · “Open github.com.”
- “Open IVY settings.”
- “Open Claude Code and start building a personal website.”

The shortcut, hold time and text-mode window are configurable in **Settings ▸ Shortcuts**.

## Architecture

```
IVY/
├── IVY.xcodeproj
├── Config/                     Info.plist (usage strings), entitlements
├── IVY/                        macOS app target (SwiftUI + AppKit)
│   ├── App/                    Entry point, AppDelegate, composition root
│   ├── Core/
│   │   ├── Engine/             EngineProcess (JSON-lines bridge), RuntimeManager
│   │   ├── LLM/                MLXLLMService (Qwen3 via MLX-LM)
│   │   ├── Speech/             AudioCaptureService, LocalWhisperService
│   │   ├── TTS/                KokoroMLXTTSService, chunked playback
│   │   └── Input/              GlobalShortcutManager (event tap / polling)
│   ├── Services/               Spotify, Reminders, Claude Code, apps, permissions…
│   ├── Tools/                  IVYTool implementations exposed to the model
│   ├── UI/                     Notch panel, dashboard, cards, settings, setup
│   └── Resources/Engine/       ivy_engine.py, setup_runtime.sh
└── IVYKit/                     Swift package: platform-independent core + tests
    └── Sources/IVYCore/
        ├── Input/              ModifierGestureStateMachine
        ├── Agent/              AgentService, CommandRouter, ToolCallParser
        ├── Tools/              IVYTool protocol, registry, risk policy, allowlist
        ├── Services/           HistoryStore, SettingsStore, reminder transforms
        └── Utilities/          Logging, date parsing, notch geometry
```

### Request flow

```
⌘⌥ gesture ─▶ microphone ─▶ MLX Whisper ─▶ transcript
                                              │
typed text ───────────────────────────────────┤
                                              ▼
                         CommandRouter (instant, deterministic)
                           │ match                 │ no match
                           ▼                       ▼
                         tool ◀──── <tool_call> ── Qwen3-4B (MLX-LM)
                           │                       ▲
                           └── result ─────────────┘ (short answer)
                           ▼
                  cards in the notch  ─▶  optional Kokoro speech
```

- **CommandRouter** handles unambiguous commands (“pause”, “open Safari”, “open IVY settings”, “remind me…”) without the model: instant, and works while the model loads.
- Everything else goes to **Qwen3-4B**, which picks tools through its native `<tool_call>` format. Tool results go back to the model for a one-sentence answer, or are shown directly when the tool's summary already is the answer.
- The model never gets a shell. Tools take **validated, structured arguments**.

### The local engine

MLX's most mature LLM, Whisper and Kokoro implementations are Python packages, so IVY bundles a small sidecar (`ivy_engine.py`) and keeps it behind clean Swift protocols (`LocalLLMService`, `SpeechRecognitionService`, `TTSService`). The native implementations can be swapped later without touching the UI.

- One process per role (`llm`, `stt`, `tts`), started lazily and talking **JSON Lines over stdin/stdout**. There's no server and no port, and the user never starts anything manually.
- Engines unload after inactivity (Settings ▸ AI), which frees all model memory.
- The LLM role keeps a **prompt-prefix KV cache**: the system prompt and tool schemas are prefilled once, so follow-up requests reach the first token in ~0.15 s on an M5.
- Runs with `HF_HUB_OFFLINE=1`: models load only from local folders.

### Changing the model

Settings ▸ AI lets you pick Qwen3 1.7B / 4B / 8B or point **Model path** at any MLX-format chat model folder. Tool calling works best with models whose chat template supports `tools` (Qwen2.5/Qwen3 family).

## Integrations

**Reminders** — EventKit. Answers about your to-do list always come from EventKit, never from the model. Due dates are resolved with `NSDataDetector` (“tomorrow at 5” → 17:00).

**Spotify** — The Spotify desktop app is controlled through its AppleScript dictionary: play, pause, next, previous, shuffle, repeat, volume and state. It uses only fixed script templates; model text is never put into a script. To play a specific song without a Spotify developer key, IVY looks the song up with the public iTunes Search API and maps it to a Spotify URI with [song.link](https://odesli.co). Only the song name is sent, and this can be disabled. The closed notch shows album art and animated bars while music plays.

**Claude Code** — IVY finds the `claude` CLI (PATH, Homebrew, npm/nvm, `~/.local/bin`, or the copy bundled with the Claude desktop app) and starts a session in `~/IVY Projects/<project>`. Sessions run either interactively in Terminal or headless in the background (`claude -p`), where the result pops up on the notch when it's done. The task text is passed as a single argument or read from a file, never through a shell command line. Codex CLI is supported too.

## Security model

| Risk | Examples | Behavior |
| --- | --- | --- |
| Low | read reminders, now playing, open app/URL, pause, settings | runs immediately |
| Medium | create/complete reminder, start a coding session | runs immediately |
| High | move file to Trash, allowlisted maintenance commands | **explicit confirmation card** |

- No tool accepts free-form shell, AppleScript or terminal input.
- Commands come from a fixed allowlist (`CommandAllowlist`); the model can only choose an ID.
- Destructive file operations are limited to files inside your home folder, never top-level or `~/Library` paths, and use the Trash instead of deleting.

## Permissions

| Permission | Why | Required? |
| --- | --- | --- |
| Microphone | Voice input | For voice |
| Reminders | To-do list | For reminders |
| Input Monitoring | Listen-only event tap for ⌘⌥ (most efficient) | Optional — without it IVY polls the modifier state, which needs no permission |
| Automation → Spotify | Playback control | For Spotify |
| Accessibility | — | **Not required** |

IVY is not sandboxed because it launches its local engine, Terminal and Claude Code. It uses the hardened runtime.

## Privacy

- Audio stays in memory, goes to a private temp file for Whisper, and is deleted right after transcription.
- Prompts, transcripts and answers are processed locally. There's no analytics or telemetry.
- History is a small local JSON file (last 50 entries) that you can switch off or clear.
- Logs use `os.Logger` with prompts marked private. View them with `log stream --predicate 'subsystem == "com.ravoxx.IVY"'`.
- Network is used only for model downloads, the optional song lookup, and by Spotify/Claude Code themselves.

## Tests

```bash
cd IVY/IVYKit && swift test
```

Covers the gesture state machine (hold → voice, release/re-press → text, quick taps, single modifiers, key chords, key repeat), command routing, tool-call parsing, the agent loop with a fake model, confirmation for high-risk tools, reminder transformations, settings persistence, history, allowlist/path validation, notch geometry and date parsing. In Xcode, ⌘U runs the same suite.

## Known limitations

- The ML runtime is Python-based (MLX's reference implementations). It's isolated behind Swift protocols so it can move to `mlx-swift` later.
- Playing a *specific* song needs an internet lookup (Spotify itself streams online anyway). Without it, IVY opens Spotify's search.
- Headless Claude Code sessions need the CLI to be logged in (`claude` → `/login`).
- Without Input Monitoring, ⌘⌥ chords combined with other keys (e.g. ⌘⌥Esc) can't be told apart from a hold, so grant it for the best experience.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| “Local AI runtime isn't installed” | Settings ▸ AI ▸ Install Runtime (needs Python ≥ 3.10 or it installs `uv`). |
| Model missing | Settings ▸ AI/Voice ▸ Download. |
| ⌘⌥ does nothing | Check Settings ▸ Shortcuts ▸ Detection; grant Input Monitoring; make sure IVY isn't paused. |
| Spotify commands fail | Allow *IVY → Spotify* in System Settings ▸ Privacy & Security ▸ Automation. |
| Permissions reset after every build | Sign with a stable Apple Development identity instead of “Sign to Run Locally”. |
| Engine errors | Settings ▸ Advanced ▸ Show Logs. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). AI coding agents: read [AGENTS.md](AGENTS.md). Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
