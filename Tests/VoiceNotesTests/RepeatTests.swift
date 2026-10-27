import XCTest
@testable import VoiceNotes

final class RepeatRuleTests: XCTestCase {
    private let cal = Calendar.current

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // 2026-11-02 is a Monday.
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testRandomGapStaysInRange() {
        let rule = RepeatRule(minMinutes: 10, maxMinutes: 20)
        let start = date(2, 10)
        for _ in 0..<50 {
            let gap = rule.nextOccurrence(after: start).timeIntervalSince(start) / 60
            XCTAssertTrue((10...20).contains(gap), "gap \(gap)")
        }
    }

    func testOutsideActiveHoursMovesToNextWindow() {
        let rule = RepeatRule(minMinutes: 30, maxMinutes: 30, startMinute: 9 * 60, endMinute: 18 * 60)
        XCTAssertEqual(rule.nextOccurrence(after: date(2, 17, 45)), date(3, 9))
        XCTAssertEqual(rule.nextOccurrence(after: date(2, 7)), date(2, 9))
        XCTAssertEqual(rule.nextOccurrence(after: date(2, 10)), date(2, 10, 30))
    }

    func testWeekdaysSkipTheWeekend() {
        let rule = RepeatRule(minMinutes: 60, maxMinutes: 60, startMinute: 9 * 60, endMinute: 18 * 60,
                              weekdays: [2, 3, 4, 5, 6])
        // Friday 6 Nov, 17:30 → Monday 9 Nov, 09:00.
        XCTAssertEqual(rule.nextOccurrence(after: date(6, 17, 30)), date(9, 9))
    }

    func testOvernightWindow() {
        let rule = RepeatRule(minMinutes: 60, maxMinutes: 60, startMinute: 22 * 60, endMinute: 2 * 60)
        XCTAssertTrue(rule.isActive(at: date(2, 23)))
        XCTAssertTrue(rule.isActive(at: date(3, 1)))
        XCTAssertFalse(rule.isActive(at: date(3, 12)))
    }

    func testDoneTodayResetsOnANewDay() {
        var rule = RepeatRule(minMinutes: 10, maxMinutes: 10)
        rule.recordDone()
        rule.recordDone()
        XCTAssertEqual(rule.doneToday, 2)
        rule.doneDate = Date().addingTimeInterval(-2 * 24 * 3600)
        XCTAssertEqual(rule.doneToday, 0)
        rule.recordDone()
        XCTAssertEqual(rule.doneToday, 1)
    }

    func testSummary() {
        XCTAssertEqual(RepeatRule(minMinutes: 10, maxMinutes: 20).summary, "every 10–20 min")
        XCTAssertEqual(RepeatRule(minMinutes: 60, maxMinutes: 60, activeTimeOnly: true).summary, "every hour at your Mac")
        XCTAssertEqual(RepeatRule(minMinutes: 45, maxMinutes: 60).summary, "every 45–60 min")
        XCTAssertEqual(RepeatRule(minMinutes: 30, maxMinutes: 30, startMinute: 540, endMinute: 1080,
                                  weekdays: [2, 3, 4, 5, 6]).summary, "every 30 min · 9:00–18:00 · weekdays")
    }

    func testParsedRepeatBecomesRule() {
        let parsed = Ollama.ParsedNote(
            title: "Drink water", body: "Drink water.", remindAt: nil, tag: "health",
            repeat: .init(minMinutes: 10, maxMinutes: 20, activeTimeOnly: false,
                          startTime: "09:00", endTime: "18:00", days: ["mon", "tue", "wed", "thu", "fri"]))
        let note = Ollama.makeNote(from: parsed, original: "", now: date(2, 10))
        XCTAssertEqual(note.repeatRule, RepeatRule(minMinutes: 10, maxMinutes: 20, startMinute: 540,
                                                   endMinute: 1080, weekdays: [2, 3, 4, 5, 6]))
        XCTAssertNotNil(note.remindAt)
    }

    func testOldNoteFilesStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"t","body":"b"}"#
        let note = try NoteFolder.decoder.decode(Note.self, from: Data(json.utf8))
        XCTAssertNil(note.repeatRule)
    }
}

@MainActor
final class SmartReminderTests: XCTestCase {
    private var store: NoteStore!
    private var context = UserContext.active
    private var fired: [String] = []

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = NoteStore(folderURL: dir, legacyFileURL: nil, startTimer: false)
        store.context = { [unowned self] in self.context }
        store.onDue = { [unowned self] in self.fired += $0.map(\.title) }
        fired = []
    }

    private func addHabit(_ title: String, activeTimeOnly: Bool = false, dueIn seconds: TimeInterval = -1) -> UUID {
        let note = Note(title: title, body: title, tag: "health", remindAt: Date().addingTimeInterval(seconds),
                        repeatRule: RepeatRule(minMinutes: 10, maxMinutes: 20, activeTimeOnly: activeTimeOnly))
        store.add(note)
        return note.id
    }

    func testHabitFiresAndSchedulesTheNextOne() {
        let id = addHabit("Water")
        store.checkDue()
        XCTAssertEqual(fired, ["Water"])
        let next = store.note(id: id)!.remindAt!
        XCTAssertGreaterThan(next, Date().addingTimeInterval(9 * 60))
        XCTAssertFalse(store.note(id: id)!.notified)
        store.checkDue()
        XCTAssertEqual(fired, ["Water"], "doesn't fire again until the next occurrence")
    }

    func testDoneCountsAndKeepsRepeating() {
        let id = addHabit("Water", dueIn: 600)
        store.markDone(id)
        store.toggleDone(id)
        let note = store.note(id: id)!
        XCTAssertFalse(note.isDone)
        XCTAssertEqual(note.repeatRule?.doneToday, 2)
        XCTAssertTrue(store.done.isEmpty)
    }

    func testHabitWaitsWhileAwayButOneTimeReminderDoesNot() {
        _ = addHabit("Water")
        store.add(Note(title: "Call bank", body: "", tag: "finance", remindAt: Date().addingTimeInterval(-1)))
        context.idleSeconds = 3 * 60
        store.checkDue()
        XCTAssertEqual(fired, ["Call bank"])
        context.idleSeconds = 0
        store.checkDue()
        XCTAssertEqual(fired, ["Call bank", "Water"])
    }

    func testHabitWaitsOutACallButNotForever() {
        let id = addHabit("Water")
        context.inCall = true
        store.checkDue()
        XCTAssertEqual(fired, [])
        store.checkDue(now: store.note(id: id)!.remindAt!.addingTimeInterval(NoteStore.maxCallDeferral + 1))
        XCTAssertEqual(fired, ["Water"])
    }

    func testBreakRestartsTimeAtMacTimer() {
        let id = addHabit("Walk", activeTimeOnly: true, dueIn: 60)
        context.idleSeconds = NoteStore.breakAfter + 1
        store.checkDue()
        context.idleSeconds = 0
        let back = Date().addingTimeInterval(30)
        store.checkDue(now: back)
        XCTAssertGreaterThanOrEqual(store.note(id: id)!.remindAt!, back.addingTimeInterval(10 * 60),
                                    "coming back from a break starts a fresh interval")
        XCTAssertEqual(fired, [])
    }

    func testClockHabitIsNotResetByABreak() {
        let id = addHabit("Water", dueIn: 60)
        let due = store.note(id: id)!.remindAt
        context.idleSeconds = NoteStore.breakAfter + 1
        store.checkDue()
        context.idleSeconds = 0
        store.checkDue()
        XCTAssertEqual(store.note(id: id)!.remindAt, due)
    }

    func testEditingTheRuleReschedules() {
        let id = addHabit("Water", dueIn: 3600)
        var edited = store.note(id: id)!
        edited.repeatRule = RepeatRule(minMinutes: 5, maxMinutes: 5)
        store.update(edited)
        let next = store.note(id: id)!.remindAt!.timeIntervalSinceNow
        XCTAssertTrue((4 * 60...5 * 60 + 1).contains(next))
    }
}
