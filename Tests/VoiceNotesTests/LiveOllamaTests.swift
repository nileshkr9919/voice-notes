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
        XCTAssertTrue(Calendar.current.isDateInTomorrow(at))
        XCTAssertEqual(Calendar.current.component(.hour, from: at), 11)

        let plain = try await Ollama.parse("buy milk eggs and bread", model: "gemma4")
        XCTAssertNil(plain.remindAt)
        XCTAssertEqual(plain.tag, "shopping")
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
