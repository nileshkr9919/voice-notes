# Changelog

## 1.1.0
- **Smart repeating reminders** — "drink water every 10–20 minutes", "get up and walk frequently". Random or fixed intervals, active hours and weekdays; "time at your Mac" reminders restart after a break; habit nudges wait while you're away or on a call; Done counts ("6 today") and keeps repeating.
- **Checklists** — "buy milk, eggs, bread and coffee" becomes a tickable list; tick items right in the list or edit them in the editor.
- **macOS-native redesign** from Penpot designs: compact popover that fits its content, flat controls, Reminders-style rows, in-popover editor and settings; waveform menu bar icon.
- Copy/paste and other edit shortcuts work in all text fields; the popover saves edits when it closes on its own.
- ⌥⇧N works on the very first press, even when macOS asks for permissions.
- Sync fix: edits made on two Macs within the same millisecond are now ordered correctly.
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
