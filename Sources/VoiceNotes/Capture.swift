import Foundation

/// The capture flow: listen → understand with the LLM → save. Lives outside the view
/// so the hotkey and popover-close can finish a recording too.
@MainActor
final class CaptureModel: ObservableObject {
    struct Status: Equatable {
        var text: String
        var isError = false
        var canUndoDelete = false
    }

    @Published private(set) var isProcessing = false
    @Published var status: Status?
    /// The latest answer to a question about the notes ("what's mom's wifi password?").
    @Published var answer: Answer?

    struct Answer: Equatable {
        var question: String
        var text: String
    }
    /// Tab to switch to after saving, so the new note is visible.
    @Published var focusTab: NoteTab?
    /// Why Ollama can't be used right now, if anything.
    @Published private(set) var ollamaProblem: String?

    let store: NoteStore
    let speech: SpeechRecognizer

    init(store: NoteStore, speech: SpeechRecognizer) {
        self.store = store
        self.speech = speech
        speech.onSilence = { [weak self] in
            Task { await self?.finish() }
        }
    }

    func toggleRecording() async {
        speech.isRecording ? await finish() : await start()
    }

    func start() async {
        guard !isProcessing, !speech.isRecording else { return }
        status = nil
        answer = nil
        Ollama.warmUp(model: Prefs.modelName) // load the model while the user talks
        await speech.start(autoStop: UserDefaults.standard.bool(forKey: Prefs.autoStop))
    }

    func finish() async {
        guard speech.isRecording else {
            speech.cancelPendingStart()
            return
        }
        let text = await speech.stop()
        await save(text)
    }

    func save(_ raw: String) async {
        speech.failure = nil // a new action supersedes an old mic error
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if speech.failure == nil { status = Status(text: "Didn't catch anything. Try again.") }
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        answer = nil

        let note: Note
        do {
            switch try await Ollama.interpret(text, model: Prefs.modelName) {
            case .question:
                await answerQuestion(text)
                return
            case .note(let parsed):
                note = parsed
            }
            ollamaProblem = nil
            let when = note.repeatRule?.summary ?? note.remindAt.map(Self.format)
                ?? (note.isChecklist ? "\(note.items.count) items" : nil)
            status = Status(text: when.map { "Saved “\(note.title)” · \($0)" } ?? "Saved “\(note.title)”")
        } catch {
            // Never lose a note just because the model isn't available.
            note = Note(title: String(text.prefix(40)), body: text, tag: "other")
            status = Status(text: "Saved as a plain note. \(error.localizedDescription)", isError: true)
            await refreshHealth()
        }
        store.add(note)
        focusTab = note.remindAt == nil ? .notes : .reminders
    }

    private func answerQuestion(_ question: String) async {
        do {
            let reply = try await Ollama.answer(question, notes: store.notes, model: Prefs.modelName)
            answer = Answer(question: question, text: reply)
            status = nil
            ollamaProblem = nil
        } catch {
            status = Status(text: "Couldn't answer that. \(error.localizedDescription)", isError: true)
            await refreshHealth()
        }
    }

    func delete(_ id: UUID) {
        store.delete(id)
        speech.failure = nil
        status = Status(text: "Note deleted.", canUndoDelete: true)
    }

    func undoDelete() {
        store.undoDelete()
        status = nil
    }

    func refreshHealth() async {
        ollamaProblem = await Ollama.healthProblem(model: Prefs.modelName)
    }

    static func format(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
