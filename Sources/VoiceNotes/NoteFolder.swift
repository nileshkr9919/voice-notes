import Foundation

/// A folder of notes, one JSON file per note. Point it at iCloud Drive, Dropbox,
/// Syncthing or any synced folder to share notes between Macs: devices rarely
/// touch the same file, and when they do the newest `updatedAt` wins.
struct NoteFolder {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceNotes", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// Where versions before 1.1 kept all notes in a single file.
    static var legacyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceNotes", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    struct Snapshot {
        var notes: [UUID: Note] = [:]
        /// Files that exist but couldn't be parsed. They're skipped, never overwritten.
        var unreadable: [String] = []
        /// Notes that exist only as not-yet-downloaded cloud placeholders.
        var downloading: Set<UUID> = []
    }

    func fileURL(for id: UUID) -> URL {
        url.appendingPathComponent("\(id.uuidString).json")
    }

    func ensureExists() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func load() -> Snapshot {
        var snapshot = Snapshot()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return snapshot }
        let decoder = Self.decoder

        for name in names {
            let file = url.appendingPathComponent(name)
            // iCloud Drive may keep only a placeholder (".<name>.json.icloud") until asked to download.
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let original = String(name.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: url.appendingPathComponent(original))
                if let id = UUID(uuidString: String(original.dropLast(".json".count))) {
                    snapshot.downloading.insert(id)
                }
                continue
            }
            // Sync services name conflicting copies differently ("<id> 2.json",
            // "<id> (conflicted copy).json"); they're read too and merged by id.
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            guard let data = try? Data(contentsOf: file),
                  let note = try? decoder.decode(Note.self, from: data) else {
                snapshot.unreadable.append(name)
                continue
            }
            if let existing = snapshot.notes[note.id], existing.updatedAt >= note.updatedAt { continue }
            snapshot.notes[note.id] = note
        }
        return snapshot
    }

    func write(_ note: Note) throws {
        try ensureExists()
        try Self.encoder.encode(note).write(to: fileURL(for: note.id), options: .atomic)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Converts a pre-1.1 `notes.json` into one file per note, then renames the old file.
    func migrateLegacyFile(at legacy: URL) {
        guard FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy),
              let notes = try? Self.decoder.decode([Note].self, from: data) else { return }
        do {
            for note in notes where !FileManager.default.fileExists(atPath: fileURL(for: note.id).path) {
                try write(note)
            }
            try FileManager.default.moveItem(
                at: legacy, to: legacy.deletingPathExtension().appendingPathExtension("migrated.json"))
        } catch {
            // Leave the legacy file in place; migration retries on next launch.
        }
    }

    // Dates keep milliseconds: whole seconds aren't precise enough to order edits
    // made on two Macs within the same second.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601Milliseconds(date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: s) { return date }
            iso.formatOptions = [.withInternetDateTime] // files from 1.0
            if let date = iso.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date: \(s)")
        }
        return d
    }()

    /// Now, rounded to the millisecond precision that's stored on disk.
    static var now: Date { roundedToMillisecond(Date()) }

    /// One millisecond after `date`, so an edit always sorts after the version it replaces.
    static func justAfter(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (milliseconds(date) + 1) / 1000)
    }

    static func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: milliseconds(date) / 1000)
    }

    private static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }

    /// "2026-10-27T18:04:05.123Z", written from whole milliseconds. (Formatters truncate,
    /// which could make an edit made 1 ms later look the same age as the one it replaced.)
    private static func iso8601Milliseconds(_ date: Date) -> String {
        let ms = Int64(milliseconds(date))
        let seconds = Date(timeIntervalSince1970: TimeInterval(ms.quotientAndRemainder(dividingBy: 1000).quotient))
        let whole = ISO8601DateFormatter().string(from: seconds) // ends in "Z"
        return whole.dropLast() + String(format: ".%03lldZ", ms % 1000)
    }
}
