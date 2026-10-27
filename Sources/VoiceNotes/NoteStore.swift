import Foundation

/// Holds all notes, keeps them in sync with a `NoteFolder` (possibly shared with
/// other Macs through a sync service), and fires `onDue` when reminders come due.
@MainActor
final class NoteStore: ObservableObject {
    /// Live (non-deleted) notes.
    @Published private(set) var notes: [Note] = []
    /// The last deleted note, kept so it can be restored.
    @Published private(set) var recentlyDeleted: Note?
    /// Set when some note files couldn't be read; they're left untouched on disk.
    @Published private(set) var loadError: String?
    /// Set when the latest save failed; cleared by the next successful one.
    @Published private(set) var saveError: String?
    @Published private(set) var folder: NoteFolder

    /// Called with every reminder that came due in one check (several after a sleep or relaunch).
    var onDue: (([Note]) -> Void)?
    /// Whether this Mac should announce reminders. When off, other devices handle them.
    var ringsOnThisDevice: () -> Bool = { true }
    /// What the user is doing; habit reminders wait for a good moment.
    var context: () -> UserContext = { .active }
    /// Whether another app is using the camera or mic. Costlier, so asked only when a habit is due.
    var isInCall: () -> Bool = { false }

    /// All records including tombstones, by id.
    private var records: [UUID: Note] = [:]
    /// Notes changed here whose file write failed; retried and never replaced by older disk copies.
    private var unsaved: Set<UUID> = []
    private var timer: Timer?
    /// Whether the user was on a break at the last check (to notice when they come back).
    private var wasOnBreak = false

    static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600
    /// No input for this long means nobody's at the Mac to see a habit reminder.
    static let awayAfter: TimeInterval = 2 * 60
    /// A break this long counts as having got up, restarting "time at your Mac" timers.
    static let breakAfter: TimeInterval = 5 * 60
    /// Habit reminders wait out a call, but not forever.
    static let maxCallDeferral: TimeInterval = 45 * 60

    init(folderURL: URL = Prefs.notesFolderURL,
         legacyFileURL: URL? = NoteFolder.legacyFileURL,
         startTimer: Bool = true) {
        folder = NoteFolder(url: folderURL)
        try? folder.ensureExists()
        if let legacyFileURL { folder.migrateLegacyFile(at: legacyFileURL) }
        reload()
        guard startTimer else { return }
        // .common mode keeps reminders firing while a menu is open.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.checkDue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Queries

    var reminders: [Note] {
        notes.filter { !$0.isDone && $0.remindAt != nil }
            .sorted { $0.remindAt! < $1.remindAt! }
    }

    var plainNotes: [Note] {
        notes.filter { !$0.isDone && $0.remindAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var done: [Note] {
        notes.filter(\.isDone).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Reminders that have gone off but haven't been dealt with yet.
    var firedCount: Int {
        notes.filter { $0.notified && !$0.isDone && $0.remindAt != nil }.count
    }

    func notes(for tab: NoteTab) -> [Note] {
        switch tab {
        case .reminders: reminders
        case .notes: plainNotes
        case .done: done
        }
    }

    func note(id: UUID) -> Note? {
        guard let note = records[id], !note.isDeleted else { return nil }
        return note
    }

    // MARK: Changes

    func add(_ note: Note) {
        var note = note
        note.updatedAt = NoteFolder.now
        persist(note)
    }

    /// Applies user edits. With `original` (the note as the editor first saw it), only fields
    /// the user actually changed are applied, so changes made meanwhile — a reminder firing,
    /// an item ticked on another Mac — aren't overwritten by the editor's stale copy.
    func update(_ note: Note, from original: Note? = nil) {
        guard let current = records[note.id] else { return }
        let base = original ?? current
        let titleChanged = note.title != base.title
        let bodyChanged = note.body != base.body
        let tagChanged = note.tag != base.tag
        let itemsChanged = note.items != base.items
        let reminderChanged = note.remindAt != base.remindAt && note.repeatRule == nil
        let ruleChanged = !(note.repeatRule?.sameSchedule(as: base.repeatRule)
                            ?? (base.repeatRule == nil))
        guard titleChanged || bodyChanged || tagChanged || itemsChanged || reminderChanged || ruleChanged
        else { return } // nothing changed: don't write or sync anything

        mutate(note.id) { current in
            if titleChanged { current.title = note.title }
            if bodyChanged { current.body = note.body }
            if tagChanged { current.tag = note.tag }
            if itemsChanged { current.items = note.items }
            if reminderChanged {
                current.remindAt = note.remindAt
                current.notified = false
            }
            if ruleChanged {
                // Keep today's count; restart the schedule from the new rule.
                var rule = note.repeatRule
                rule?.doneCount = current.repeatRule?.doneCount ?? 0
                rule?.doneDate = current.repeatRule?.doneDate
                current.repeatRule = rule
                if let rule { current.remindAt = rule.nextOccurrence(after: Date()) }
                current.notified = false
            }
        }
    }

    func delete(_ id: UUID) {
        guard let note = self.note(id: id) else { return }
        recentlyDeleted = note
        mutate(id) { $0.isDeleted = true }
    }

    func undoDelete() {
        guard let note = recentlyDeleted else { return }
        recentlyDeleted = nil
        mutate(note.id) { $0.isDeleted = false }
    }

    /// For a repeating reminder, "done" means "did it this time": it's counted and the next one is scheduled.
    func toggleDone(_ id: UUID) {
        if note(id: id)?.isRepeating == true { return completeOccurrence(id) }
        mutate(id) { $0.isDone.toggle() }
    }

    /// Ticks or unticks one item of a checklist note.
    func toggleItem(_ itemID: UUID, in id: UUID) {
        mutate(id) { note in
            guard let i = note.items.firstIndex(where: { $0.id == itemID }) else { return }
            note.items[i].done.toggle()
        }
    }

    func markDone(_ id: UUID) {
        if note(id: id)?.isRepeating == true { return completeOccurrence(id) }
        mutate(id) { $0.isDone = true }
    }

    private func completeOccurrence(_ id: UUID, at now: Date = Date()) {
        mutate(id) {
            $0.repeatRule?.recordDone(at: now)
            $0.remindAt = $0.repeatRule?.nextOccurrence(after: now)
            $0.notified = false
        }
    }

    func setReminder(_ id: UUID, to date: Date?) {
        mutate(id) {
            $0.remindAt = date
            $0.notified = false
            $0.isDone = false
        }
    }

    func snooze(_ id: UUID, minutes: Int) {
        setReminder(id, to: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    // MARK: Reminders

    func checkDue(now: Date = Date()) {
        guard ringsOnThisDevice() else { return }
        // Presence only matters for habits; skip the checks entirely when there are none.
        let hasHabits = records.values.contains { $0.isRepeating && !$0.isDeleted }
        let context = hasHabits ? context() : .active
        let onBreak = context.screenLocked || context.idleSeconds >= Self.breakAfter
        if onBreak {
            wasOnBreak = true
        } else if wasOnBreak {
            wasOnBreak = false
            restartTimeAtMacTimers(now: now) // they just got up, so start counting again
        }
        let away = context.screenLocked || context.idleSeconds >= Self.awayAfter

        let due = records.values.filter {
            !$0.isDeleted && !$0.isDone && !$0.notified && ($0.remindAt.map { $0 <= now } ?? false)
        }
        var fired: [Note] = []
        for note in due.sorted(by: { $0.remindAt! < $1.remindAt! }) {
            guard let rule = note.repeatRule else {
                // One-time reminders always fire on time.
                // Marking it fired syncs to other Macs, so the same reminder doesn't ring everywhere.
                mutate(note.id) { $0.notified = true }
                fired.append(note)
                continue
            }
            // Outside its hours or days (e.g. due while the Mac slept): wait for the next window.
            if !rule.isActive(at: now) {
                mutate(note.id) { $0.remindAt = rule.nextActive(from: now) }
                continue
            }
            // Habit reminders wait for a good moment: not to an empty room, not mid-call.
            if away { continue }
            if now.timeIntervalSince(note.remindAt!) < Self.maxCallDeferral && (context.inCall || isInCall()) {
                continue
            }
            mutate(note.id) {
                $0.remindAt = rule.nextOccurrence(after: now)
                $0.notified = false
            }
            fired.append(note)
        }
        guard !fired.isEmpty else { return }
        onDue?(fired)
    }

    /// After sleep the Mac was certainly left alone, so "time at your Mac" starts over.
    func systemDidWake(now: Date = Date()) {
        restartTimeAtMacTimers(now: now)
    }

    private func restartTimeAtMacTimers(now: Date) {
        for note in records.values where !note.isDeleted && note.repeatRule?.activeTimeOnly == true {
            mutate(note.id) {
                $0.remindAt = $0.repeatRule?.nextOccurrence(after: now)
                $0.notified = false
            }
        }
    }

    // MARK: Sync

    /// Merges the folder's contents into memory: for each note the newest edit wins.
    func reload() {
        let snapshot = folder.load()
        // An unreadable folder (offline, unmounted) says nothing; keep what's in memory.
        guard !snapshot.folderUnavailable else { return }
        var merged = records
        for (id, disk) in snapshot.notes where !unsaved.contains(id) {
            if let mine = merged[id], mine.updatedAt >= disk.updatedAt { continue }
            merged[id] = disk
        }
        // A file removed from the folder (by a purge or the user) removes the note,
        // unless it was changed here and is still waiting to be written.
        for id in merged.keys
        where snapshot.notes[id] == nil && !snapshot.downloading.contains(id) && !unsaved.contains(id) {
            merged[id] = nil
        }
        // Forget old tombstones once every device has had time to see them.
        let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
        for (id, note) in merged where note.isDeleted && note.updatedAt < cutoff {
            merged[id] = nil
            folder.remove(id)
        }
        records = merged
        retryUnsaved()
        loadError = snapshot.unreadable.isEmpty ? nil :
            "\(snapshot.unreadable.count) note file\(snapshot.unreadable.count == 1 ? "" : "s") couldn't be read and \(snapshot.unreadable.count == 1 ? "was" : "were") skipped (left untouched)."
        publish()
    }

    /// Switches to another folder, copying this Mac's notes into it. Notes already
    /// there (e.g. from another Mac) are merged, newest edit winning.
    func changeFolder(to url: URL) throws {
        let target = NoteFolder(url: url)
        try target.ensureExists()
        let existing = target.load().notes
        for note in records.values {
            if let there = existing[note.id], there.updatedAt >= note.updatedAt { continue }
            try target.write(note)
        }
        folder = target
        records = [:]
        unsaved = []
        recentlyDeleted = nil
        reload()
    }

    // MARK: Private

    private func mutate(_ id: UUID, _ change: (inout Note) -> Void) {
        guard var note = records[id] else { return }
        change(&note)
        note.updatedAt = max(NoteFolder.now, NoteFolder.justAfter(note.updatedAt))
        persist(note)
    }

    private func persist(_ note: Note) {
        records[note.id] = note
        do {
            try folder.write(note)
            unsaved.remove(note.id)
            saveError = nil
        } catch {
            unsaved.insert(note.id)
            saveError = "Couldn't save notes to \(folder.url.path): \(error.localizedDescription)"
        }
        publish()
    }

    private func retryUnsaved() {
        for id in unsaved {
            guard let note = records[id] else { continue }
            if (try? folder.write(note)) != nil {
                unsaved.remove(id)
            }
        }
        if unsaved.isEmpty { saveError = nil }
    }

    private func publish() {
        // Only publish real changes, so the UI and badge don't redraw on every 15 s tick.
        let live = records.values.filter { !$0.isDeleted }.sorted { $0.id.uuidString < $1.id.uuidString }
        if live != notes { notes = live }
    }
}
