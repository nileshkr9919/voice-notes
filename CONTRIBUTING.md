# Contributing to Voice Notes

Thanks for helping! Voice Notes is a small, local-first macOS app. Two principles guide every change:

1. **Local and free.** No cloud services, accounts, telemetry or paid APIs. The only network traffic is to Ollama on `localhost`.
2. **Never lose a note.** Anything touching storage must keep unreadable files untouched and survive failed writes. Add a test.

## Getting started
```sh
git clone <this repo> && cd <repo>
./install.sh        # installs Ollama + models, builds from source and launches the app
swift test          # unit tests (no Ollama needed)
VOICENOTES_LIVE=1 swift test --filter LiveOllamaTests   # integration tests against local Ollama
./build.sh --install                                    # rebuild and relaunch after changes
```
Requires macOS 14+ and Swift 6 (Xcode 16+ or the Command Line Tools).

## Code map
| File | What it does |
|---|---|
| `AppDelegate.swift` | Menu bar item, popover, global hotkey (⌥⇧N), wiring |
| `ContentView.swift` | SwiftUI: capture area, note list, editor, settings |
| `Capture.swift` | Listen → parse with the LLM → save flow |
| `SpeechRecognizer.swift` | On-device dictation (Speech + AVAudioEngine) |
| `Ollama.swift` | Prompt, JSON schema, date handling, TTS, health checks |
| `NoteStore.swift` | In-memory notes, sync merge, reminder firing |
| `NoteFolder.swift` | One-JSON-file-per-note storage, legacy migration |
| `Reminders.swift` | Notifications (Snooze/Done) and spoken reminders |

### How sync works
Each note is `<uuid>.json` in the notes folder. Every change bumps `updatedAt` (millisecond precision); on reload the newest copy of each note wins. Deletions are tombstones (`isDeleted`) kept for 30 days so they propagate. A reminder sets `notified` when it fires, which syncs so other Macs don't ring again. Conflict copies created by sync services are read and merged by id.

## Pull requests
- Keep PRs focused; describe the user-visible change.
- `swift test` must pass (CI runs it on every PR).
- If you change the LLM prompt, run the live tests and include a few example inputs/outputs in the PR.
- Match the existing style: small types, comments only where the *why* isn't obvious.

## Reporting bugs
Open an issue with your macOS version, Mac model/memory, the Ollama model you use, and what you said or typed. Please don't paste private note contents.
