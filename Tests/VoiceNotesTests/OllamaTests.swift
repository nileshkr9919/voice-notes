import XCTest
@testable import VoiceNotes

final class OllamaTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    func testParseDateWithOffset() {
        let date = Ollama.parseDate("2026-10-28T11:00:00+05:30")
        XCTAssertEqual(date, iso.date(from: "2026-10-28T05:30:00Z"))
    }

    func testParseDateWithoutOffsetUsesLocalTime() {
        let date = Ollama.parseDate("2026-10-28T11:00")!
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        XCTAssertEqual(parts.hour, 11)
        XCTAssertEqual(parts.minute, 0)
    }

    func testParseDateRejectsEmptyAndNull() {
        XCTAssertNil(Ollama.parseDate(nil))
        XCTAssertNil(Ollama.parseDate(""))
        XCTAssertNil(Ollama.parseDate("null"))
        XCTAssertNil(Ollama.parseDate("next tuesday"))
    }

    func testFutureReminderIsKept() {
        let now = Date()
        let later = now.addingTimeInterval(3600)
        XCTAssertEqual(Ollama.normalizeReminder(later, now: now), later)
    }

    func testReminderEarlierTodayMovesToTomorrow() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3 * 3600)
        let result = Ollama.normalizeReminder(earlier, now: now)
        XCTAssertEqual(result, Calendar.current.date(byAdding: .day, value: 1, to: earlier))
    }

    func testStaleReminderIsDropped() {
        let now = Date()
        XCTAssertNil(Ollama.normalizeReminder(now.addingTimeInterval(-3 * 24 * 3600), now: now))
    }

    func testReminderJustNowIsKept() {
        let now = Date()
        XCTAssertEqual(Ollama.normalizeReminder(now.addingTimeInterval(-10), now: now), now)
    }

    func testMakeNoteFallsBackForEmptyFieldsAndUnknownTag() {
        let parsed = Ollama.ParsedNote(title: " ", body: "", remindAt: nil, tag: "groceries")
        let note = Ollama.makeNote(from: parsed, original: "buy milk", now: Date())
        XCTAssertEqual(note.title, "buy milk")
        XCTAssertEqual(note.body, "buy milk")
        XCTAssertEqual(note.tag, "other")
        XCTAssertNil(note.remindAt)
    }

    func testSystemPromptListsUpcomingWeek() {
        let prompt = Ollama.systemPrompt(now: Date())
        XCTAssertTrue(prompt.contains("(today)"))
        XCTAssertTrue(prompt.contains("(tomorrow)"))
    }

    func testModelInstalledMatching() {
        let installed = ["gemma4:latest", "phonon:latest", "llama3:8b"]
        XCTAssertTrue(Ollama.isInstalled("gemma4", in: installed))
        XCTAssertTrue(Ollama.isInstalled("llama3:8b", in: installed))
        XCTAssertFalse(Ollama.isInstalled("llama3", in: installed))
        XCTAssertFalse(Ollama.isInstalled("mistral", in: installed))
    }

    func testTomorrowSaidAfterMidnightMeansTheComingMorning() {
        let cal = Calendar.current
        let lateNight = cal.date(bySettingHour: 0, minute: 40, second: 0, of: Date())!
        let calendarTomorrow11 = cal.date(bySettingHour: 11, minute: 0, second: 0,
                                          of: cal.date(byAdding: .day, value: 1, to: lateNight)!)!
        let adjusted = Ollama.adjustLateNightTomorrow(calendarTomorrow11, text: "call the bank tomorrow at 11",
                                                      now: lateNight)!
        XCTAssertTrue(cal.isDate(adjusted, inSameDayAs: lateNight))
        XCTAssertEqual(cal.component(.hour, from: adjusted), 11)

        let evening = cal.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        let tomorrowFromEvening = cal.date(byAdding: .day, value: 1, to: evening)!
        XCTAssertEqual(Ollama.adjustLateNightTomorrow(tomorrowFromEvening, text: "tomorrow", now: evening),
                       tomorrowFromEvening)
    }
}
