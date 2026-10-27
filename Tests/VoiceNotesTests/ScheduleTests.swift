import XCTest
@testable import VoiceNotes

@MainActor
final class ScheduleTests: XCTestCase {
    func testOnlyUpcomingOneTimeRemindersAreHandedToMacOS() {
        let now = Date()
        var done = Note(title: "Done", body: "", tag: "other", remindAt: now.addingTimeInterval(600))
        done.isDone = true
        var fired = Note(title: "Fired", body: "", tag: "other", remindAt: now.addingTimeInterval(600))
        fired.notified = true
        let notes = [
            Note(title: "Later", body: "", tag: "other", remindAt: now.addingTimeInterval(7200)),
            Note(title: "Soon", body: "", tag: "other", remindAt: now.addingTimeInterval(600)),
            Note(title: "Past", body: "", tag: "other", remindAt: now.addingTimeInterval(-60)),
            Note(title: "Plain", body: "", tag: "other"),
            Note(title: "Habit", body: "", tag: "health", remindAt: now.addingTimeInterval(600),
                 repeatRule: RepeatRule(minMinutes: 20, maxMinutes: 20)),
            done, fired,
        ]
        let planned = Notifier.plannedSchedule(for: notes, now: now, ringsHere: true)
        XCTAssertEqual(planned.map(\.note.title), ["Soon", "Later"])
        XCTAssertTrue(Notifier.plannedSchedule(for: notes, now: now, ringsHere: false).isEmpty)
    }

    func testMovingAReminderChangesItsRequestID() {
        let now = Date()
        var note = Note(title: "Call", body: "", tag: "other", remindAt: now.addingTimeInterval(600))
        let before = Notifier.plannedSchedule(for: [note], now: now, ringsHere: true)[0].id
        note.remindAt = now.addingTimeInterval(1200)
        let after = Notifier.plannedSchedule(for: [note], now: now, ringsHere: true)[0].id
        XCTAssertNotEqual(before, after)
    }

    func testRespectsMacOSPendingLimit() {
        let now = Date()
        let notes = (1...100).map {
            Note(title: "R\($0)", body: "", tag: "other", remindAt: now.addingTimeInterval(Double($0) * 60))
        }
        let planned = Notifier.plannedSchedule(for: notes, now: now, ringsHere: true)
        XCTAssertEqual(planned.count, Notifier.scheduleLimit)
        XCTAssertEqual(planned.first?.note.title, "R1")
    }
}
