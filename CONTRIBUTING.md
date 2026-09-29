# Contributing to IVY

Thanks for helping make IVY better! Bug reports, ideas and pull requests are all welcome.

## Getting started

1. Fork and clone the repository.
2. Open `IVY/IVY.xcodeproj` in Xcode 26 or later and set your own signing team.
3. Run the app (⌘R) and follow the setup window to install the local runtime and models.
4. Run the tests: `cd IVY/IVYKit && swift test` (or ⌘U in Xcode).

## Reporting bugs

Please include:

- macOS version and Mac model (e.g. MacBook Air M5, 16 GB)
- What you said or typed, what you expected, and what happened
- Relevant logs from **Settings ▸ Advanced ▸ Show Logs** (check them for personal data first)

## Pull requests

- Keep PRs focused: one feature or fix per PR.
- Add or update tests in `IVYKit` for logic changes (gesture handling, routing, parsing, policies).
- The build must stay **warning-free** and `swift test` must pass.
- Update `README.md` when you change user-visible behavior.
- Describe *why* in the PR description, and include screenshots or a short video for UI changes.

### Code style

- Swift with SwiftUI for views and AppKit where macOS needs it (panels, event taps, status items).
- `@MainActor` for UI state, actors or locks for shared mutable state, `async/await` throughout.
- Never block the main thread (model calls, AppleScript, processes, EventKit).
- Doc comments where a macOS API is non-obvious. Otherwise, let clear names do the talking.

### New tools and integrations

Read the *Adding a tool* section in [AGENTS.md](AGENTS.md). In short: structured and validated arguments, a correct risk level, a short factual summary, and no shell or AppleScript built from model output.

## Privacy expectations

IVY is local-first. Contributions must not add analytics, telemetry or silent network calls. Any feature that needs the network must be explicit, documented in the README and, where reasonable, switchable in Settings.

## Code of conduct

Be kind and constructive. Harassment or discrimination of any kind isn't tolerated.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
