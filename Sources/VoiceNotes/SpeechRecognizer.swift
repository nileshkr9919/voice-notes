import AVFoundation
import Speech

/// Live dictation using Apple's speech recognizer (on-device when available).
@MainActor
final class SpeechRecognizer: ObservableObject {
    enum Failure: Equatable {
        case permissionDenied
        case unavailable(String)

        var message: String {
            switch self {
            case .permissionDenied:
                "Voice Notes needs Microphone and Speech Recognition access."
            case .unavailable(let detail):
                detail
            }
        }
    }

    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published var failure: Failure?

    /// Called when the speaker pauses long enough that the note seems finished.
    var onSilence: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gotFinalResult = false
    private var autoStop = false
    private var silenceTimer: Task<Void, Never>?
    /// True while start() awaits permissions or stop() drains the final result,
    /// so overlapping calls can't tear down each other's session.
    private var isBusy = false
    private var startCancelled = false

    /// Abandons a start() that is still waiting on permission prompts
    /// (e.g. the popover closed while the system dialog was up).
    func cancelPendingStart() {
        if isBusy && !isRecording { startCancelled = true }
    }

    func start(autoStop: Bool) async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        startCancelled = false
        failure = nil
        transcript = ""
        gotFinalResult = false
        self.autoStop = autoStop

        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard speechOK, micOK else {
            failure = .permissionDenied
            return
        }
        guard !startCancelled else { return }
        guard let recognizer, recognizer.isAvailable else {
            failure = .unavailable("Speech recognition isn't available right now. Try again in a moment.")
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // installTap raises an exception on an invalid format, e.g. when no microphone is connected.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            failure = .unavailable("No microphone found. Connect one, or type your note instead.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failure = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        isRecording = true
        armSilenceTimer(after: .seconds(8)) // nothing said at all

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            Task { @MainActor in self?.handle(text: text, isFinal: isFinal, error: errorText) }
        }
        self.task = task
    }

    /// Stops listening and returns the final transcript.
    func stop() async -> String {
        guard isRecording, !isBusy else { return transcript }
        isBusy = true
        defer { isBusy = false }
        silenceTimer?.cancel()
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Wait (briefly) for the recognizer to deliver its final, most accurate result.
        for _ in 0..<20 where !gotFinalResult {
            try? await Task.sleep(for: .milliseconds(75))
        }
        task?.cancel()
        task = nil
        request = nil
        return transcript
    }

    private func handle(text: String?, isFinal: Bool, error: String?) {
        guard task != nil else { return } // late callback after stop() finished
        if let text, !text.isEmpty {
            transcript = text
            if isRecording { armSilenceTimer(after: .seconds(2.5)) }
        }
        if isFinal { gotFinalResult = true }
        if let error, isRecording, transcript.isEmpty {
            failure = .unavailable("Couldn't recognize speech: \(error)")
            gotFinalResult = true
            Task { _ = await stop() }
        } else if error != nil {
            gotFinalResult = true
        }
    }

    private func armSilenceTimer(after delay: Duration) {
        silenceTimer?.cancel()
        guard autoStop else { return }
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.onSilence?()
        }
    }
}
