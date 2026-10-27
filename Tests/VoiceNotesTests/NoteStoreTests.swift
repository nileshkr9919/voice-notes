import XCTest
@testable import VoiceNotes

@MainActor
final class NoteStoreTests: XCTestCase {
    private var dir: URL!
    private var folder: URL { dir.appendingPathComponent("Notes") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Each store is like a separate Mac looking at the same synced folder.
    private func makeStore(_ url: URL? = nil, legacy: URL? = nil) -> NoteStore {
        NoteStore(folderURL: url ?? folder, legacyFileURL: legacy, startTimer: false)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: Basics

    func testNotesPersistAcrossLaunches() throws {
        let store = makeStore()
        store.add(Note(title: "Milk", body: "Buy milk", tag: "shopping"))
        store.add(Note(title: "Bank", body: "Call bank", tag: "finance", remindAt: Date().addingTimeInterval(60)))
        XCTAssertEqual(try files().count, 2, "one file per note")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.plainNotes.map(\.title), ["Milk"])
        XCTAssertEqual(reloaded.reminders.map(\.title), ["Bank"])
    }

    func testDueReminderFiresExactlyOnce() {
        let store = makeStore()
        var fired: [String] = []
        store.onDue = { fired += $0.map(\.title) }
        store.add(Note(title: "Now", body: "", tag: "other", remindAt: Date().addingTimeInterval(-1)))
        store.add(Note(title: "Later", body: "", tag: "other", remindAt: Date().addingTimeInterval(3600)))

        store.checkDue()
        store.checkDue()
        XCTAssertEqual(fired, ["Now"])
        XCTAssertEqual(store.firedCount, 1)
    }

    func testBacklogIsDeliveredAsOneBatch() {
        let store = makeStore()
        var batches: [[Note]] = []
        store.onDue = { batches.append($0) }
        for i in 0..<3 {
            store.add(Note(title: "R\(i)", body: "", tag: "other", remindAt: Date().addingTimeInterval(-60)))
        }
        store.checkDue()
        XCTAssertEqual(batches.map(\.count), [3])
    }

    func testSnoozeRearmsReminder() {
        let store = makeStore()
        var fired = 0
        store.onDue = { fired += $0.count }
        let note = Note(title: "Pill", body: "", tag: "health", remindAt: Date().addingTimeInterval(-1))
        store.add(note)
        store.checkDue()
        store.snooze(note.id, minutes: 10)

        XCTAssertEqual(store.firedCount, 0)
        store.checkDue(now: Date().addingTimeInterval(11 * 60))
        XCTAssertEqual(fired, 2)
    }

    func testDoneRemindersDontFire() {
        let store = makeStore()
        var fired = 0
        store.onDue = { fired += $0.count }
        let note = Note(title: "Done", body: "", tag: "other", remindAt: Date().addingTimeInterval(-1))
        store.add(note)
        store.toggleDone(note.id)
        store.checkDue()
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(store.done.count, 1)
    }

    func testStaleEditorCopyDoesNotRearmOrUndoState() {
        let store = makeStore()
        let note = Note(title: "Call", body: "", tag: "other", remindAt: Date().addingTimeInterval(-1))
        store.add(note)
        let editorCopy = store.note(id: note.id)! // editor opened before the reminder fired
        var fired = 0
        store.onDue = { fired += $0.count }
        store.checkDue()
        store.markDone(note.id)

        var edited = editorCopy
        edited.title = "Call the bank"
        store.update(edited)
        store.checkDue()

        let saved = store.note(id: note.id)!
        XCTAssertEqual(saved.title, "Call the bank")
        XCTAssertTrue(saved.notified)
        XCTAssertTrue(saved.isDone)
        XCTAssertEqual(fired, 1)
    }

    func testEditingReminderTimeRearmsIt() {
        let store = makeStore()
        var note = Note(title: "Call", body: "", tag: "other", remindAt: Date().addingTimeInterval(-1))
        store.add(note)
        store.checkDue()
        note.remindAt = Date().addingTimeInterval(600)
        store.update(note)
        XCTAssertFalse(store.note(id: note.id)!.notified)
    }

    func testMarkDoneIsIdempotent() {
        let store = makeStore()
        let note = Note(title: "Pay", body: "", tag: "finance")
        store.add(note)
        store.markDone(note.id)
        store.markDone(note.id)
        XCTAssertTrue(store.note(id: note.id)!.isDone)
    }

    func testDeleteAndUndo() {
        let store = makeStore()
        let note = Note(title: "Temp", body: "", tag: "other")
        store.add(note)
        store.delete(note.id)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(makeStore().notes.isEmpty, "deletion is persisted")
        store.undoDelete()
        XCTAssertEqual(store.notes.map(\.id), [note.id])
        XCTAssertEqual(makeStore().notes.count, 1)
    }

    // MARK: Robustness

    func testCorruptFileIsSkippedAndNeverOverwritten() throws {
        let store = makeStore()
        store.add(Note(title: "Good", body: "", tag: "other"))
        let bad = folder.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: bad)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.notes.map(\.title), ["Good"])
        XCTAssertNotNil(reloaded.loadError)
        reloaded.add(Note(title: "New", body: "", tag: "other"))
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "not json")
    }

    func testLegacySingleFileIsMigrated() throws {
        let legacy = dir.appendingPathComponent("notes.json")
        try Data("""
        [{"id":"\(UUID().uuidString)","title":"Old","body":"From 1.0","tag":"idea",
          "createdAt":"2026-10-01T10:00:00Z","isDone":false,"notified":false}]
        """.utf8).write(to: legacy)

        let store = makeStore(legacy: legacy)
        XCTAssertEqual(store.notes.map(\.title), ["Old"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("notes.migrated.json").path))
    }

    func testFailedWriteIsReportedAndRetried() throws {
        let store = makeStore()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        store.add(Note(title: "Pending", body: "", tag: "other"))
        XCTAssertNotNil(store.saveError)
        store.reload()
        XCTAssertEqual(store.notes.map(\.title), ["Pending"], "unsaved note survives a reload")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        store.reload()
        XCTAssertNil(store.saveError)
        XCTAssertEqual(makeStore().notes.map(\.title), ["Pending"])
    }

    // MARK: Sync between Macs

    func testNoteAddedOnOneMacAppearsOnTheOther() {
        let macA = makeStore()
        let macB = makeStore()
        macA.add(Note(title: "From A", body: "", tag: "other"))
        XCTAssertTrue(macB.notes.isEmpty)
        macB.reload()
        XCTAssertEqual(macB.notes.map(\.title), ["From A"])
    }

    func testNewestEditWins() {
        let macA = makeStore()
        let note = Note(title: "Original", body: "", tag: "other")
        macA.add(note)
        let macB = makeStore()

        var edit = macB.note(id: note.id)!
        edit.title = "Edited on B"
        macB.update(edit)

        macA.reload()
        XCTAssertEqual(macA.note(id: note.id)?.title, "Edited on B")
    }

    func testDeletionSyncs() {
        let macA = makeStore()
        let note = Note(title: "Gone", body: "", tag: "other")
        macA.add(note)
        let macB = makeStore()
        macA.delete(note.id)
        macB.reload()
        XCTAssertTrue(macB.notes.isEmpty)
    }

    func testReminderRingsOnOnlyOneMac() {
        let macA = makeStore()
        macA.add(Note(title: "Once", body: "", tag: "other", remindAt: Date().addingTimeInterval(-1)))
        let macB = makeStore()
        var firedA = 0, firedB = 0
        macA.onDue = { firedA += $0.count }
        macB.onDue = { firedB += $0.count }

        macA.checkDue()
        macB.reload()
        macB.checkDue()
        XCTAssertEqual(firedA + firedB, 1)
    }

    func testMacWithRingingOffLeavesReminderForOthers() {
        let macA = makeStore()
        macA.ringsOnThisDevice = { false }
        macA.add(Note(title: "Elsewhere", body: "", tag: "other", remindAt: Date().addingTimeInterval(-1)))
        var firedA = 0
        macA.onDue = { firedA += $0.count }
        macA.checkDue()

        let macB = makeStore()
        var firedB = 0
        macB.onDue = { firedB += $0.count }
        macB.checkDue()
        XCTAssertEqual([firedA, firedB], [0, 1])
    }

    func testConflictCopyFromSyncServiceIsMergedByNewest() throws {
        let store = makeStore()
        let note = Note(title: "Mine", body: "", tag: "other")
        store.add(note)

        var theirs = store.note(id: note.id)!
        theirs.title = "Theirs (newer)"
        theirs.updatedAt = Date().addingTimeInterval(60)
        try NoteFolder.encoder.encode(theirs)
            .write(to: folder.appendingPathComponent("\(note.id.uuidString) (conflicted copy).json"))

        store.reload()
        XCTAssertEqual(store.notes.map(\.title), ["Theirs (newer)"])
    }

    func testChangingFolderMergesNotesIntoIt() throws {
        let local = makeStore()
        local.add(Note(title: "Local", body: "", tag: "other"))

        let shared = dir.appendingPathComponent("iCloud/Voice Notes")
        let otherMac = makeStore(shared)
        otherMac.add(Note(title: "Other Mac", body: "", tag: "other"))

        try local.changeFolder(to: shared)
        XCTAssertEqual(Set(local.notes.map(\.title)), ["Local", "Other Mac"])
        otherMac.reload()
        XCTAssertEqual(Set(otherMac.notes.map(\.title)), ["Local", "Other Mac"])
    }

    func testOldTombstonesArePurged() throws {
        let store = makeStore()
        var note = Note(title: "Ancient", body: "", tag: "other")
        note.isDeleted = true
        note.updatedAt = Date().addingTimeInterval(-NoteStore.tombstoneLifetime - 60)
        try NoteFolder(url: folder).write(note)

        store.reload()
        XCTAssertTrue(try files().isEmpty)
    }
}
