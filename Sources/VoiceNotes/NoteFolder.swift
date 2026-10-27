import CryptoKit
import Foundation

/// A folder of notes, one JSON file per note. Point it at iCloud Drive, Dropbox,
/// Syncthing or any synced folder to share notes between Macs: devices rarely
/// touch the same file, and when they do the newest `updatedAt` wins.
struct NoteFolder {
    let url: URL
    /// Present when the folder's notes are encrypted (see NoteCrypto.swift).
    private(set) var vault: Vault?
    /// This Mac's key for the vault; nil means locked until the passphrase is entered.
    private(set) var key: SymmetricKey?

    /// Where folder keys are kept (the Keychain; tests swap in memory).
    nonisolated(unsafe) static var keyStore: KeyStore = KeychainKeyStore()
    static let plainExtension = "json"
    static let sealedExtension = "vnote"

    init(url: URL) {
        self.url = url
        refreshVault()
    }

    /// This Mac's memory of which folders are encrypted (by vault id). The vault file in a
    /// synced folder can't be trusted on its own: if it goes missing (deleted, or evicted to
    /// an iCloud placeholder) that must never quietly switch this Mac to writing plain text.
    private var rememberedID: UUID? { Self.keyStore.encryptedVault(forFolder: url.standardizedFileURL.path) }

    private func remember(_ id: UUID?) {
        Self.keyStore.setEncryptedVault(id, forFolder: url.standardizedFileURL.path)
    }

    /// Notes are written encrypted while this Mac knows of a vault (an active one, or an
    /// unproven "turned off" marker) or remembers the folder being encrypted.
    var isEncrypted: Bool { vault != nil || rememberedID != nil }

    var isLocked: Bool { isEncrypted && key == nil }

    /// Picks up encryption turned on (or provably turned off) by another Mac.
    mutating func refreshVault() {
        let file = url.appendingPathComponent(Vault.fileName)
        let placeholder = url.appendingPathComponent(".\(Vault.fileName).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        let onDisk = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Vault.self, from: $0) }
        let remembered = rememberedID

        guard let onDisk else {
            // Missing or unreadable vault: a plain folder only if this Mac never knew otherwise.
            if let remembered, key == nil { key = Self.keyStore.key(for: remembered) }
            if remembered == nil { vault = nil; key = nil }
            return
        }

        if onDisk.isDisabled {
            guard remembered != nil || vault.map({ !$0.isDisabled }) == true else {
                vault = nil; key = nil // never encrypted here: just a plain folder
                return
            }
            let candidate = key ?? Self.keyStore.key(for: onDisk.id)
            if let candidate, onDisk.provesDisabled(with: candidate) {
                forgetEncryption(id: onDisk.id) // turned off on another Mac, verifiably
            } else {
                vault = onDisk // unproven: stay encrypted; the passphrase can confirm it
            }
            return
        }

        if onDisk != vault {
            vault = onDisk
            if onDisk.id != remembered { remember(onDisk.id); key = nil }
        }
        if key == nil {
            key = Self.keyStore.key(for: onDisk.id).flatMap { onDisk.accepts($0) ? $0 : nil }
        }
    }

    private mutating func forgetEncryption(id: UUID) {
        Self.keyStore.delete(for: id)
        remember(nil)
        vault = nil
        key = nil
    }

    /// Turns encryption on for this folder. The caller then rewrites the notes.
    mutating func setUpEncryption(passphrase: String, iterations: Int = Vault.defaultIterations) throws {
        let (vault, key) = try Vault.create(passphrase: passphrase, iterations: iterations)
        try adopt(vault, key: key)
    }

    /// Uses an existing vault and key (e.g. when moving encrypted notes to another folder).
    mutating func adopt(_ vault: Vault, key: SymmetricKey) throws {
        try ensureExists()
        var active = vault
        active.disabled = nil
        active.proof = nil
        try JSONEncoder().encode(active).write(to: url.appendingPathComponent(Vault.fileName), options: .atomic)
        Self.keyStore.save(key, for: active.id)
        remember(active.id)
        self.vault = active
        self.key = key
    }

    /// Unlocks an encrypted folder on this Mac. Returns false for a wrong passphrase.
    /// If another Mac turned encryption off, the passphrase also confirms that.
    mutating func unlock(passphrase: String) -> Bool {
        guard let vault, let key = vault.key(for: passphrase) else { return false }
        if vault.isDisabled {
            guard vault.provesDisabled(with: key) else { return false }
            forgetEncryption(id: vault.id)
            return true
        }
        Self.keyStore.save(key, for: vault.id)
        self.key = key
        return true
    }

    /// Turns encryption off: writes every note back as plain JSON first, then replaces the
    /// vault with an authenticated "turned off" marker and removes the encrypted copies —
    /// so an interruption never loses notes, and other Macs can verify the change.
    mutating func removeEncryption(rewriting notes: [Note]) throws {
        guard let vault, let key else { throw NoteCryptoError.locked }
        for note in notes { try writeFile(note, sealed: false) }
        let marker = try vault.disabledMarker(key: key)
        try JSONEncoder().encode(marker).write(to: url.appendingPathComponent(Vault.fileName), options: .atomic)
        forgetEncryption(id: vault.id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where name.hasSuffix("." + Self.sealedExtension) {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
        }
    }

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
        /// The folder itself couldn't be listed (offline, unmounted): the snapshot says nothing.
        var folderUnavailable = false
        /// Encrypted notes that couldn't be opened because this Mac doesn't have the key yet.
        var lockedCount = 0
    }

    func fileURL(for id: UUID) -> URL {
        url.appendingPathComponent("\(id.uuidString).\(isEncrypted ? Self.sealedExtension : Self.plainExtension)")
    }

    func ensureExists() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func load() -> Snapshot {
        var snapshot = Snapshot()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else {
            snapshot.folderUnavailable = true
            return snapshot
        }
        let decoder = Self.decoder

        for name in names {
            let file = url.appendingPathComponent(name)
            // iCloud Drive may keep only a placeholder (".<name>.json.icloud") until asked to download.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let original = String(name.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: url.appendingPathComponent(original))
                if let id = Self.noteID(fromFileName: original) {
                    snapshot.downloading.insert(id)
                }
                continue
            }
            // Sync services name conflicting copies differently ("<id> 2.json",
            // "<id> (conflicted copy).json"); they're read too and merged by id.
            let sealed = name.hasSuffix("." + Self.sealedExtension)
            guard sealed || name.hasSuffix("." + Self.plainExtension), !name.hasPrefix(".") else { continue }
            guard var data = try? Data(contentsOf: file) else {
                // Not readable yet (e.g. a cloud file still downloading): keep what we have.
                if let id = Self.noteID(fromFileName: name) { snapshot.downloading.insert(id) }
                continue
            }
            if sealed {
                guard let key else {
                    // Locked on this Mac: count it and keep anything already in memory.
                    snapshot.lockedCount += 1
                    if let id = Self.noteID(fromFileName: name) { snapshot.downloading.insert(id) }
                    continue
                }
                guard let opened = try? NoteCrypto.open(data, key: key) else {
                    snapshot.unreadable.append(name)
                    continue
                }
                data = opened
            }
            guard let note = try? decoder.decode(Note.self, from: data) else {
                snapshot.unreadable.append(name)
                continue
            }
            if let existing = snapshot.notes[note.id], existing.updatedAt >= note.updatedAt { continue }
            snapshot.notes[note.id] = note
        }
        return snapshot
    }

    /// Writes the note encrypted if the folder is, otherwise as plain JSON.
    func write(_ note: Note) throws {
        if isLocked { throw NoteCryptoError.locked } // never put plain text into an encrypted folder
        try writeFile(note, sealed: isEncrypted)
    }

    private func writeFile(_ note: Note, sealed: Bool) throws {
        try ensureExists()
        var data = try Self.encoder.encode(note)
        if sealed {
            guard let key else { throw NoteCryptoError.locked }
            data = try NoteCrypto.seal(data, key: key)
        }
        let ext = sealed ? Self.sealedExtension : Self.plainExtension
        try data.write(to: url.appendingPathComponent("\(note.id.uuidString).\(ext)"), options: .atomic)
        // Drop the other format's copy, so a note never exists both encrypted and in plain text.
        let other = sealed ? Self.plainExtension : Self.sealedExtension
        try? FileManager.default.removeItem(at: url.appendingPathComponent("\(note.id.uuidString).\(other)"))
    }

    /// Removes the note's file and any conflict copies a sync service made of it.
    func remove(_ id: UUID) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where (name.hasSuffix("." + Self.plainExtension) || name.hasSuffix("." + Self.sealedExtension))
            && Self.noteID(fromFileName: name) == id {
            try? fm.removeItem(at: url.appendingPathComponent(name))
        }
    }

    /// "<uuid>.json", "<uuid> 2.json", "<uuid> (conflicted copy).json" → uuid.
    static func noteID(fromFileName name: String) -> UUID? {
        UUID(uuidString: String(name.prefix(36)))
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

    // Shared: creating ISO8601DateFormatter per date is slow. Decoding happens on the main actor.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoWhole = ISO8601DateFormatter()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoFractional.date(from: s) ?? isoWhole.date(from: s) { return date } // whole: files from 1.0
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
