import XCTest
@testable import VoiceNotes

final class ReminderTextTests: XCTestCase {
    private func clean(_ s: String) -> String { Note.removingScheduleWords(from: s) }

    func testStripsScheduleWords() {
        XCTAssertEqual(clean("walk away from screen every 30 minutes"), "Walk away from screen.")
        XCTAssertEqual(clean("Drink water every 10-20 minutes."), "Drink water.")
        XCTAssertEqual(clean("Remind me to stretch every hour during work hours"), "Stretch.")
        XCTAssertEqual(clean("Get up and walk frequently."), "Get up and walk.")
        XCTAssertEqual(clean("Call the bank tomorrow at 11 about the card fee"), "Call the bank about the card fee.")
        XCTAssertEqual(clean("Dentist appointment on Friday at 4 pm."), "Dentist appointment.")
        XCTAssertEqual(clean("Take the clothes out of the washer in 20 minutes"), "Take the clothes out of the washer.")
        XCTAssertEqual(clean("Water the plants on weekdays"), "Water the plants.")
    }

    func testKeepsNormalText() {
        XCTAssertEqual(clean("The wifi password is sunflower42."), "The wifi password is sunflower42.")
        XCTAssertEqual(clean("Buy a birthday gift for Priya"), "Buy a birthday gift for Priya.")
    }

    func testReminderTextFallsBackToTitle() {
        let note = Note(title: "Stretch", body: "every hour", tag: "health")
        XCTAssertEqual(note.reminderText, "Stretch.")
    }
}
