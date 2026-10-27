import XCTest
@testable import VoiceNotes

/// Regression tests for issues found in code review.
final class TimeRegressionTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testWindowStartIsWallClockOnDSTDay() {
        // 2026-11-01 is the US fall-back day (25 hours long).
        let rule = RepeatRule(minMinutes: 30, maxMinutes: 30, startMinute: 9 * 60, endMinute: 18 * 60)
        let next = rule.nextActive(from: date(2026, 11, 1, 7))
        XCTAssertEqual(Calendar.current.dateComponents([.day, .hour, .minute], from: next),
                       DateComponents(day: 1, hour: 9, minute: 0))
    }

    func testOvernightWindowUsesTheStartingDaysWeekday() {
        // 22:00–06:00, Monday–Friday. 2026-11-07 is a Saturday, 2026-11-09 a Monday.
        let rule = RepeatRule(minMinutes: 60, maxMinutes: 60, startMinute: 22 * 60, endMinute: 6 * 60,
                              weekdays: [2, 3, 4, 5, 6])
        XCTAssertTrue(rule.isActive(at: date(2026, 11, 7, 1)), "Saturday 1 AM is Friday night")
        XCTAssertFalse(rule.isActive(at: date(2026, 11, 9, 1)), "Monday 1 AM is Sunday night")
        XCTAssertTrue(rule.isActive(at: date(2026, 11, 9, 23)))
    }

    func testPromptListsLocalDates() {
        let now = date(2026, 10, 28, 21) // 01:00 UTC on the 29th
        let prompt = Ollama.systemPrompt(now: now)
        XCTAssertTrue(prompt.contains("= 2026-10-28 (today)"), prompt)
        XCTAssertTrue(prompt.contains("2026-10-28T21:00"), "local time, no UTC offset")
    }

    func testHalfAWindowIsIgnored() {
        let rule = Ollama.makeRule(.init(minMinutes: 30, maxMinutes: 30, activeTimeOnly: false,
                                         startTime: nil, endTime: "18:00", days: nil))
        XCTAssertNil(rule?.startMinute)
        XCTAssertNil(rule?.endMinute)
        let withSeconds = Ollama.makeRule(.init(minMinutes: 30, maxMinutes: 30, activeTimeOnly: false,
                                                startTime: "09:00:00", endTime: "18:00:00", days: nil))
        XCTAssertEqual(withSeconds?.startMinute, 540)
    }
}

@MainActor
final class StoreRegressionTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func makeStore(_ url: URL? = nil) -> NoteStore {
        NoteStore(folderURL: url ?? folder, legacyFileURL: nil, startTimer: false)
    }

    func testHabitDueOutsideItsHoursWaitsForTheWindow() {
        let store = makeStore()
        var fired = 0
        store.onDue = { fired += $0.count }
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        // A one-hour window that is definitely not now.
        let start = ((hour + 3) % 24) * 60
        let rule = RepeatRule(minMinutes: 10, maxMinutes: 10, startMinute: start, endMinute: (start + 60) % 1440)
        let note = Note(title: "Water", body: "", tag: "health", remindAt: now.addingTimeInterval(-60), repeatRule: rule)
        store.add(note)
        store.checkDue(now: now)
        XCTAssertEqual(fired, 0)
        XCTAssertTrue(rule.isActive(at: store.note(id: note.id)!.remindAt!))
    }

    func testEditorSaveKeepsChangesMadeMeanwhile() {
        let store = makeStore()
        var note = Note(title: "Groceries", body: "Groceries", tag: "shopping")
        note.items = [ChecklistItem(text: "Milk"), ChecklistItem(text: "Eggs")]
        store.add(note)
        let original = store.note(id: note.id)!

        // Meanwhile (e.g. on another Mac) an item is ticked.
        store.toggleItem(note.items[0].id, in: note.id)

        var edited = original
        edited.title = "Weekly groceries"
        store.update(edited, from: original)

        let saved = store.note(id: note.id)!
        XCTAssertEqual(saved.title, "Weekly groceries")
        XCTAssertEqual(saved.items.map(\.done), [true, false], "tick made meanwhile survives")
    }

    func testSavingWithoutChangesWritesNothing() {
        let store = makeStore()
        let note = Note(title: "Idea", body: "Something", tag: "idea")
        store.add(note)
        let before = store.note(id: note.id)!.updatedAt
        store.update(store.note(id: note.id)!, from: store.note(id: note.id)!)
        XCTAssertEqual(store.note(id: note.id)!.updatedAt, before)
    }

    func testUnavailableFolderKeepsNotesInMemory() throws {
        let store = makeStore()
        store.add(Note(title: "Keep me", body: "", tag: "other"))
        try FileManager.default.removeItem(at: folder) // e.g. an unmounted or offline folder
        store.reload()
        XCTAssertEqual(store.notes.map(\.title), ["Keep me"])
    }

    func testPurgeRemovesConflictCopies() throws {
        var note = Note(title: "Old", body: "", tag: "other")
        let noteFolder = NoteFolder(url: folder)
        try noteFolder.write(note)
        note.isDeleted = true
        try NoteFolder.encoder.encode(note)
            .write(to: folder.appendingPathComponent("\(note.id.uuidString) 2.json"))
        noteFolder.remove(note.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
