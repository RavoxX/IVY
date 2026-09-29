# IVY

**IVY is a private AI assistant that lives in your MacBook's notch.** Hold <kbd>⌘</kbd><kbd>⌥</kbd>, ask a question, and IVY answers from a dark panel that grows out of the notch. Speech recognition, the language model and text-to-speech all run **locally on Apple Silicon** with [MLX](https://github.com/ml-explore/mlx).

- 🎙️ **Voice or text** — hold <kbd>⌘</kbd><kbd>⌥</kbd> for 0.5 s to talk; release <kbd>⌘</kbd> and press it again to type.
- 🧠 **Local LLM** — Qwen3-4B (4-bit) via MLX-LM, with native tool calling.
- 👂 **Local speech-to-text** — MLX Whisper (large-v3-turbo).
- 🗣️ **Local TTS** — Kokoro-82M via MLX (`mlx-audio`). Off by default.
- ✅ **Reminders** — read, create and complete Apple Reminders through EventKit.
- 🎵 **Spotify** — play songs, pause, skip, volume and a now-playing card.
- 🚀 **Apps, files, URLs, browser** — open apps, folders and websites, or run a Google search in Chrome/Safari.
- 🌐 **Web search** — when IVY doesn't know something or it needs current info, it searches in the background and answers from the results (with sources).
- ⏱️ **Timers & alarms** — countdown in the closed notch and an alert when time's up.
- 🌤️ **Weather, calendar, system** — forecast (Open-Meteo), today's events (EventKit), volume/mute, dark mode, battery, disk space, math.
- 👩‍💻 **Claude Code** — open an interactive Claude Code (or Codex) session, or start one on a task.
- 🪄 **Notch dashboard** — hover the notch for a media player, a drag-and-drop file shelf with AirDrop, and history (inspired by [boring.notch](https://github.com/TheBoredTeam/boring.notch)).
- 🔒 **Private by default** — no cloud AI, no telemetry, no stored audio.

> IVY is an independent open-source project and is not affiliated with Apple, Spotify or Anthropic.

## Screenshots

<p align="center">
  <img src="docs/screenshots/reminders.png" alt="IVY answering “What's on my to-do list for today?” with three reminders" width="32%">
  <img src="docs/screenshots/music.png" alt="IVY playing Billie Jean with the Spotify playback card" width="32%">
  <img src="docs/screenshots/dashboard.png" alt="Hover dashboard with media player, battery and quick actions" width="32%">
</p>

| Closed notch while music plays | Listening | Typing |
| --- | --- | --- |
| ![Album art and audio bars in the closed notch](docs/screenshots/live.png) | ![IVY listening to a spoken question](docs/screenshots/listening.png) | ![Typing a question into IVY](docs/screenshots/typing.png) |

| Timer | Weather | Claude Code |
| --- | --- | --- |
| ![A 25-minute pasta timer counting down](docs/screenshots/timer.png) | ![Current weather in Berlin](docs/screenshots/weather.png) | ![Claude Code building a personal website in the background](docs/screenshots/claude.png) |

| File shelf with AirDrop |
| --- |
| ![Drag-and-drop file shelf with an AirDrop target](docs/screenshots/shelf.png) |

## Requirements

| | |
| --- | --- |
| Mac | Apple Silicon (M1 or later). Tuned for a fanless MacBook Air. |
| macOS | 26 or later |
| Xcode | 26 or later (Swift 6 toolchain) |
| Disk | ~6 GB for the runtime and default models |
| Memory | 8 GB works, 16 GB recommended |

IVY works on displays without a notch too — it attaches to the top center of the screen.

## Install (DMG)

1. Download `IVY-<version>.dmg` from the [Releases](https://github.com/RavoxX/IVY/releases) page, open it and drag **IVY** into **Applications**.
2. Open IVY. If macOS says it can't verify the developer, right-click IVY ▸ **Open** (needed once for builds that aren't notarized).
3. In the setup window click **Install Everything**. IVY downloads its local AI once from the web: the MLX runtime (~1.5 GB) and the models (~4.3 GB). The size is shown before anything starts. After that, everything runs offline.
4. Hold <kbd>⌘</kbd><kbd>⌥</kbd> and talk.

The DMG itself is small (~3 MB) because models are never bundled into the app.

### Building the DMG

```bash
scripts/build_dmg.sh            # → dist/IVY-<version>.dmg
```

The script builds a Release version (Apple Silicon), signs it with a *Developer ID Application* identity when your keychain has one (otherwise with your Apple Development identity), and creates a drag-to-Applications DMG. For public releases, notarize it:

```bash
xcrun notarytool store-credentials ivy-notary --apple-id <id> --team-id <team> --password <app-specific-password>
IVY_NOTARY_PROFILE=ivy-notary scripts/build_dmg.sh
```

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
3. **Install Runtime** creates a private Python environment with MLX packages (~1.5 GB).
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
- “Open Claude Code.” · “Open Claude Code and start building a personal website.”
- “Set a timer for 10 minutes.” · “Wake me up at 7.” · “How much time is left?”
- “Open Chrome and search for the Eiffel Tower.” · “Who won the Champions League final?”
- “What's the weather tomorrow?” · “What's on my calendar today?”
- “Turn on dark mode.” · “Mute.” · “How much battery do I have?” · “What's 15% of 80?”

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

- **CommandRouter** handles unambiguous commands (“pause”, “open Safari”, “open IVY settings”, “remind me…”, timers, math) without the model: instant, and works while the model loads.
- An **action-claim guard** stops the model from saying it did something (“I opened Chrome…”) without calling a tool. It re-prompts once, then answers honestly that it can't.
- Everything else goes to **Qwen3-4B**, which picks tools through its native `<tool_call>` format. Tool results go back to the model for a one-sentence answer, or are shown directly when the tool's summary already is the answer.
- The model never gets a shell. Tools take **validated, structured arguments**.

### The notch animation

The window has a fixed size and never resizes. The notch silhouette is a Core Animation `CAShapeLayer` mask whose path springs (`CASpringAnimation`) from the camera housing to the panel. SwiftUI content is laid out at its final size and revealed by the mask, so the panel grows out of the notch without text re-flowing. Clicks pass through everywhere outside the visible shape.

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

**Spotify** — The Spotify desktop app is controlled through its AppleScript dictionary: play, pause, next, previous, shuffle, repeat, volume and state. It uses only fixed script templates; model text is never put into a script. To play a specific song, IVY resolves it to Spotify track IDs:

1. the **Spotify Web API**, if you add your own free client ID/secret in Settings (the secret is stored in the Keychain), then
2. **Deezer + iTunes Search** for the canonical title/artist/album, mapped to Spotify IDs with **ListenBrainz**, then
3. a DuckDuckGo `site:open.spotify.com` lookup as a fallback.

Spotify silently substitutes region-locked tracks, so IVY plays candidates one by one and **verifies the title and artist that actually start**. Only the song name is sent, and the lookup can be disabled. The closed notch shows album art and animated bars while music plays.

**Web search** — `web_search` queries DuckDuckGo's HTML endpoint (Wikipedia as a fallback), reads the top page, and lets the model answer from real text. Sources are shown as a card. **Weather** comes from Open-Meteo. There are no API keys, and only the query is sent. Both can be switched off (Settings ▸ Integrations ▸ Web).

**Timers** — `TimerService` schedules a single timer for the next deadline (zero idle cost). The closed notch shows the countdown, and a finished timer pops up with a Stop button and a sound.

**Claude Code** — IVY finds the `claude` CLI (PATH, Homebrew, npm/nvm, `~/.local/bin`, or the copy bundled with the Claude desktop app). “Open Claude Code” opens an interactive session in Terminal. With a task (“…and start building a personal website”) the session starts in `~/IVY Projects/<project>` with that task: interactively in Terminal by default, or headless in the background (`claude -p`, result pops up on the notch). The task text is read from a file at runtime and never spliced into a shell command line. Codex CLI is supported too.

## Security model

| Risk | Examples | Behavior |
| --- | --- | --- |
| Low | read reminders/calendar, now playing, open app/URL, browser/web search, timers, volume, pause, settings | runs immediately |
| Medium | create/complete reminder, start a coding session, dark mode | runs immediately |
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
| Calendars | “What's on my calendar?” | For calendar |
| Automation → Spotify | Playback control | For Spotify |
| Automation → System Events | Dark mode toggle | For dark mode |
| Accessibility | — | **Not required** |

IVY is not sandboxed because it launches its local engine, Terminal and Claude Code. It uses the hardened runtime.

## Privacy

- Audio stays in memory, goes to a private temp file for Whisper, and is deleted right after transcription.
- Prompts, transcripts and answers are processed locally. There's no analytics or telemetry.
- History is a small local JSON file (last 50 entries) that you can switch off or clear.
- Logs use `os.Logger` with prompts marked private. View them with `log stream --predicate 'subsystem == "com.ravoxx.IVY"'`.
- Network is used only for model downloads, the optional song lookup, web search and weather (switchable), and by Spotify/Claude Code themselves.

## Tests

```bash
cd IVY/IVYKit && swift test
```

Covers the gesture state machine (hold → voice, release/re-press → text, quick taps, single modifiers, key chords, key repeat), command routing, tool-call parsing, the agent loop with a fake model, confirmation for high-risk tools, reminder transformations, settings persistence, history, allowlist/path validation, notch geometry and date parsing. In Xcode, ⌘U runs the same suite.

## Known limitations

- The ML runtime is Python-based (MLX's reference implementations). It's isolated behind Swift protocols so it can move to `mlx-swift` later.
- Playing a *specific* song needs an internet lookup (Spotify itself streams online anyway). Public catalogs don't cover every track; add Spotify API credentials for the best matching. If nothing can be verified, IVY opens Spotify's search and says so.
- Web search scrapes DuckDuckGo's HTML page, which can rate-limit heavy use; IVY then falls back to Wikipedia.
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
