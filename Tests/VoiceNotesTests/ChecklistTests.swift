import XCTest
@testable import VoiceNotes

@MainActor
final class ChecklistTests: XCTestCase {
    private func makeStore() -> NoteStore {
        NoteStore(folderURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                  legacyFileURL: nil, startTimer: false)
    }

    func testParsedItemsBecomeAChecklist() {
        let parsed = Ollama.ParsedNote(title: "Groceries", body: "Groceries", remindAt: nil, tag: "shopping",
                                       items: ["Milk", " Eggs ", "", "Bread"])
        let note = Ollama.makeNote(from: parsed, original: "", now: Date())
        XCTAssertEqual(note.items.map(\.text), ["Milk", "Eggs", "Bread"])
        XCTAssertTrue(note.isChecklist)
    }

    func testASingleItemIsNotAChecklist() {
        let parsed = Ollama.ParsedNote(title: "Call bank", body: "Call the bank.", remindAt: nil, tag: "finance",
                                       items: ["Call the bank"])
        XCTAssertFalse(Ollama.makeNote(from: parsed, original: "", now: Date()).isChecklist)
    }

    func testTickingAnItemPersistsAndSyncs() {
        let store = makeStore()
        var note = Note(title: "Groceries", body: "Groceries", tag: "shopping")
        note.items = [ChecklistItem(text: "Milk"), ChecklistItem(text: "Eggs")]
        store.add(note)
        store.toggleItem(note.items[1].id, in: note.id)
        XCTAssertEqual(store.note(id: note.id)?.doneItemCount, 1)

        let otherMac = NoteStore(folderURL: store.folder.url, legacyFileURL: nil, startTimer: false)
        XCTAssertEqual(otherMac.note(id: note.id)?.items.map(\.done), [false, true])
    }

    func testEditingItemsIsSaved() {
        let store = makeStore()
        var note = Note(title: "Packing", body: "Packing", tag: "personal")
        note.items = [ChecklistItem(text: "Passport")]
        store.add(note)
        note.items.append(ChecklistItem(text: "Charger"))
        store.update(note)
        XCTAssertEqual(store.note(id: note.id)?.items.map(\.text), ["Passport", "Charger"])
    }

    func testPlainTextIncludesItems() {
        var note = Note(title: "Groceries", body: "Groceries", tag: "shopping")
        note.items = [ChecklistItem(text: "Milk", done: true), ChecklistItem(text: "Eggs")]
        XCTAssertEqual(note.plainText, "✓ Milk\n- Eggs")
    }

    func testOldNotesDecodeWithoutItems() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"t","body":"b"}"#
        XCTAssertEqual(try NoteFolder.decoder.decode(Note.self, from: Data(json.utf8)).items, [])
    }
}
