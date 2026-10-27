# Changelog

## 1.1.0
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
