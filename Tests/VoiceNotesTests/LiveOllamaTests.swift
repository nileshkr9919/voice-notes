import XCTest
@testable import VoiceNotes

/// Hits the real local Ollama server. Run with: VOICENOTES_LIVE=1 swift test --filter LiveOllamaTests
final class LiveOllamaTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOICENOTES_LIVE"] == "1", "set VOICENOTES_LIVE=1")
    }

    func testParsesReminderAndPlainNote() async throws {
        let reminder = try await Ollama.parse("remind me to call the bank tomorrow at 11", model: "gemma4")
        let at = try XCTUnwrap(reminder.remindAt)
        // Before 4 AM people mean the coming morning by "tomorrow".
        let earlyHours = Calendar.current.component(.hour, from: Date()) < 4
        XCTAssertTrue(earlyHours ? Calendar.current.isDateInToday(at) : Calendar.current.isDateInTomorrow(at))
        XCTAssertEqual(Calendar.current.component(.hour, from: at), 11)

        let plain = try await Ollama.parse("buy milk eggs and bread", model: "gemma4")
        XCTAssertNil(plain.remindAt)
        XCTAssertEqual(plain.tag, "shopping")
    }

    func testParsesHabits() async throws {
        let water = try await Ollama.parse("remind me to drink water every 10-20 minutes", model: "gemma4")
        let waterRule = try XCTUnwrap(water.repeatRule)
        XCTAssertEqual([waterRule.minMinutes, waterRule.maxMinutes], [10, 20])
        XCTAssertFalse(waterRule.activeTimeOnly)

        let walk = try await Ollama.parse("remind me to get up and walk frequently", model: "gemma4")
        let walkRule = try XCTUnwrap(walk.repeatRule)
        XCTAssertTrue(walkRule.activeTimeOnly)
        XCTAssertTrue((30...90).contains(walkRule.minMinutes), "\(walkRule)")

        let once = try await Ollama.parse("remind me to call the bank tomorrow at 11", model: "gemma4")
        XCTAssertNil(once.repeatRule)
    }

    func testParsesLists() async throws {
        let list = try await Ollama.parse("buy milk, eggs, bread and coffee", model: "gemma4")
        XCTAssertEqual(list.items.map { $0.text.lowercased() }, ["milk", "eggs", "bread", "coffee"])
        let single = try await Ollama.parse("call the bank about the card fee", model: "gemma4")
        XCTAssertFalse(single.isChecklist)
    }

    func testAnswersQuestionsFromNotes() async throws {
        guard case .question = try await Ollama.interpret("what's the wifi password at mom's place?", model: "gemma4")
        else { return XCTFail("expected a question") }
        guard case .note = try await Ollama.interpret("remind me to buy milk tomorrow", model: "gemma4")
        else { return XCTFail("expected a note") }

        let notes = [
            Note(title: "Mom's Wi-Fi", body: "The wifi password at mom's place is sunflower42.", tag: "personal"),
            Note(title: "Dentist", body: "Dentist appointment on Friday at 4 pm.", tag: "health"),
        ]
        let reply = try await Ollama.answer("what's the wifi password at mom's place?", notes: notes, model: "gemma4")
        XCTAssertTrue(reply.contains("sunflower42"), reply)
        let unknown = try await Ollama.answer("what's my passport number?", notes: notes, model: "gemma4")
        XCTAssertTrue(unknown.lowercased().contains("couldn't find"), unknown)
    }

    func testUnderstandsCommands() async throws {
        guard case .command = try await Ollama.interpret("mark milk as done", model: "gemma4")
        else { return XCTFail("expected a command") }
        guard case .command = try await Ollama.interpret("pause habits until 3", model: "gemma4")
        else { return XCTFail("expected a command") }

        var groceries = Note(title: "Groceries", body: "Groceries", tag: "shopping")
        groceries.items = [ChecklistItem(text: "Eggs"), ChecklistItem(text: "Milk")]
        let water = Note(title: "Drink water", body: "", tag: "health",
                         repeatRule: RepeatRule(minMinutes: 20, maxMinutes: 20))
        let notes = [water, groceries]

        let tick = try await Ollama.command("mark milk as done", notes: notes, model: "gemma4")
        XCTAssertEqual(tick.action, .complete)
        XCTAssertEqual(tick.noteNumber, 2)
        XCTAssertEqual(tick.itemNumber, 2)

        let drank = try await Ollama.command("I drank water", notes: notes, model: "gemma4")
        XCTAssertEqual(drank.action, .complete)
        XCTAssertEqual(drank.noteNumber, 1)

        let snooze = try await Ollama.command("snooze water for an hour", notes: notes, model: "gemma4")
        XCTAssertEqual(snooze.action, .snooze)
        XCTAssertEqual(snooze.minutes, 60)
    }

    func testNoteTextLeavesOutTheSchedule() async throws {
        let habit = try await Ollama.parse("walk away from screen every 30 minutes", model: "gemma4")
        XCTAssertNotNil(habit.repeatRule)
        XCTAssertFalse(habit.body.lowercased().contains("30"), habit.body)
        XCTAssertFalse(habit.reminderText.lowercased().contains("every"), habit.reminderText)
    }

    func testMissingModelIsReported() async {
        do {
            _ = try await Ollama.parse("hello", model: "no-such-model-xyz")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OllamaError, .modelMissing("no-such-model-xyz"))
        }
    }

    func testHealthAndSpeech() async throws {
        let problem = await Ollama.healthProblem(model: "gemma4")
        XCTAssertNil(problem)
        let wav = try await Ollama.speech("Hello", voice: "Freya")
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }
}
