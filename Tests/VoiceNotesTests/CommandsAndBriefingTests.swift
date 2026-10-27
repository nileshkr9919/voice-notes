import XCTest
@testable import VoiceNotes

@MainActor
final class CommandTests: XCTestCase {
    private var store: NoteStore!
    private var capture: CaptureModel!

    override func setUp() async throws {
        store = NoteStore(folderURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                          legacyFileURL: nil, startTimer: false)
        capture = CaptureModel(store: store, speech: SpeechRecognizer())
        UserDefaults.standard.removeObject(forKey: Prefs.habitsPausedUntil)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: Prefs.habitsPausedUntil)
    }

    private func groceries() -> Note {
        var note = Note(title: "Groceries", body: "Groceries", tag: "shopping")
        note.items = [ChecklistItem(text: "Milk"), ChecklistItem(text: "Eggs")]
        store.add(note)
        return note
    }

    func testCompleteChecklistItem() {
        let note = groceries()
        let status = capture.apply(.init(action: .complete, noteNumber: 1, itemNumber: 1), to: [note])
        XCTAssertEqual(store.note(id: note.id)?.items.map(\.done), [true, false])
        XCTAssertEqual(status.text, "Checked off “Milk”.")
    }

    func testCompleteHabitCountsIt() {
        let habit = Note(title: "Drink water", body: "", tag: "health", remindAt: Date().addingTimeInterval(600),
                         repeatRule: RepeatRule(minMinutes: 20, maxMinutes: 20))
        store.add(habit)
        let status = capture.apply(.init(action: .complete, noteNumber: 1), to: [habit])
        XCTAssertEqual(store.note(id: habit.id)?.repeatRule?.doneToday, 1)
        XCTAssertFalse(store.note(id: habit.id)!.isDone)
        XCTAssertTrue(status.text.contains("1 today"))
    }

    func testSnoozeForMinutes() {
        let note = Note(title: "Call bank", body: "", tag: "finance", remindAt: Date())
        store.add(note)
        let now = Date()
        _ = capture.apply(.init(action: .snooze, noteNumber: 1, minutes: 60), to: [note], now: now)
        XCTAssertEqual(store.note(id: note.id)!.remindAt!.timeIntervalSince(now), 3600, accuracy: 1)
    }

    func testDeleteCanBeUndone() {
        let note = groceries()
        let status = capture.apply(.init(action: .delete, noteNumber: 1), to: [note])
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(status.canUndoDelete)
        capture.undoDelete()
        XCTAssertEqual(store.notes.count, 1)
    }

    func testPauseAndResumeHabits() {
        let now = Date()
        _ = capture.apply(.init(action: .pauseHabits, minutes: 30), to: [], now: now)
        XCTAssertEqual(Prefs.pausedUntil!.timeIntervalSince(now), 1800, accuracy: 1)

        var fired = 0
        store.onDue = { fired += $0.count }
        store.habitsPausedUntil = { Prefs.pausedUntil }
        store.add(Note(title: "Water", body: "", tag: "health", remindAt: now.addingTimeInterval(-1),
                       repeatRule: RepeatRule(minMinutes: 10, maxMinutes: 10)))
        store.checkDue(now: now)
        XCTAssertEqual(fired, 0, "paused")

        _ = capture.apply(.init(action: .resumeHabits), to: [], now: now)
        XCTAssertNil(Prefs.pausedUntil)
        store.checkDue(now: now)
        XCTAssertEqual(fired, 1)
    }

    func testUnknownNoteIsReportedNotGuessed() {
        let status = capture.apply(.init(action: .complete, noteNumber: 9), to: [groceries()])
        XCTAssertTrue(status.isError)
    }
}

final class BriefingTests: XCTestCase {
    private let cal = Calendar.current

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    func testBriefingText() {
        let now = at(8, 30)
        let notes = [
            Note(title: "Call the bank", body: "", tag: "finance", remindAt: at(11)),
            Note(title: "Dentist", body: "", tag: "health", remindAt: at(16)),
            Note(title: "Washer", body: "", tag: "personal", remindAt: at(7)),
            Note(title: "Drink water", body: "", tag: "health", remindAt: at(9),
                 repeatRule: RepeatRule(minMinutes: 20, maxMinutes: 20)),
        ]
        let text = Briefing.text(for: notes, now: now)
        XCTAssertTrue(text.hasPrefix("Good morning."), text)
        XCTAssertTrue(text.contains("Today you have 2 reminders: Call the bank at"), text)
        XCTAssertTrue(text.contains("Still open from earlier: Washer."), text)
        XCTAssertTrue(text.contains("Habits: Drink water."), text)
    }

    func testEmptyDay() {
        XCTAssertTrue(Briefing.text(for: [], now: at(9)).contains("Nothing is scheduled for today."))
    }

    func testDueOncePerDayWithinFourHours() {
        let minute = 8 * 60 + 30
        XCTAssertFalse(Briefing.isDue(now: at(8, 29), enabled: true, minuteOfDay: minute, lastDay: nil))
        XCTAssertTrue(Briefing.isDue(now: at(8, 30), enabled: true, minuteOfDay: minute, lastDay: nil))
        XCTAssertTrue(Briefing.isDue(now: at(12, 0), enabled: true, minuteOfDay: minute, lastDay: nil))
        XCTAssertFalse(Briefing.isDue(now: at(13, 0), enabled: true, minuteOfDay: minute, lastDay: nil))
        XCTAssertFalse(Briefing.isDue(now: at(9), enabled: true, minuteOfDay: minute,
                                      lastDay: Briefing.dayKey(at(9))))
        XCTAssertFalse(Briefing.isDue(now: at(9), enabled: false, minuteOfDay: minute, lastDay: nil))
    }
}
