# Changelog

## 1.1.0
- **Smart repeating reminders** — "drink water every 10–20 minutes", "get up and walk frequently". Random or fixed intervals, active hours and weekdays; "time at your Mac" reminders restart after a break; habit nudges wait while you're away or on a call; Done counts ("6 today") and keeps repeating.
- **Ask your notes** — type or say a question ("what's the wifi password at mom's?") and get an answer from your notes, locally.
- **Commands** — "mark milk done", "I drank water", "snooze water for an hour", "delete the dentist note", "pause habits until 3".
- **Daily briefing** (optional) — a spoken summary of today's reminders, anything still open, and your habits, once a day at a time you choose.
- **Keyboard control** — ↑/↓ to select, Space to complete, Return to edit, ⌫ to delete, ⌘F search, ⌘1–3 tabs; just start typing to add a note.
- **Reminders even when the app is quit** — upcoming one-time reminders are also scheduled with macOS, so they still pop up if Voice Notes isn't running (no duplicates when it is).
- Reminders say and show just the task ("Walk away from the screen."), without the schedule ("every 30 minutes").
- A banner warns when macOS notifications are switched off for Voice Notes, with a button to turn them on.
- **Checklists** — "buy milk, eggs, bread and coffee" becomes a tickable list; tick items right in the list or edit them in the editor.
- **macOS-native redesign** from Penpot designs: compact popover that fits its content, flat controls, Reminders-style rows, in-popover editor and settings; waveform menu bar icon.
- Copy/paste and other edit shortcuts work in all text fields; the popover saves edits when it closes on its own.
- ⌥⇧N works on the very first press, even when macOS asks for permissions.
- Sync fix: edits made on two Macs within the same millisecond are now ordered correctly.
- Reliability: reminder times are correct across daylight-saving changes and time zones; habit reminders respect their hours after sleep; overnight windows use the right weekday; "tomorrow" said after midnight means the coming morning; the editor never overwrites changes synced from another Mac and keeps edits on Back; an offline notes folder no longer hides notes; lower battery use.
- **Sync across Macs** — store notes in any folder (iCloud Drive, Dropbox, Google Drive, Syncthing). One file per note, newest edit wins, deletions sync, and a reminder rings on only one Mac.
- "Ring reminders on this Mac" setting.
- `install.sh`: one-line installer for non-developers. Needs nothing preinstalled: it fetches Ollama, the models and a ready-made app (or builds from source in a checkout).
- Release workflow publishes a ready-made universal app on every version tag.
- Notes from 1.0 are migrated automatically (the old `notes.json` is kept as `notes.migrated.json`).

## 1.0.0
- Menu bar voice notes with ⌥⇧N hotkey, auto-stop on pause.
- Local LLM (Ollama) turns speech into titled, tagged notes and reminders.
- Notifications with Snooze/Done, reminders read aloud with phonon voices.
- Edit, search, undo delete, menu bar badge for fired reminders.
