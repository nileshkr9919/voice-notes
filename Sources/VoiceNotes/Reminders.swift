import AVFoundation
import UserNotifications

/// Shows macOS notifications for due reminders, with Snooze / Done actions.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let store: NoteStore
    var onOpen: (() -> Void)?

    private static let category = "REMINDER"
    private static let snooze = "SNOOZE_10"
    private static let done = "DONE"

    init(store: NoteStore) {
        self.store = store
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.snooze, title: "Snooze 10 min"),
                    UNNotificationAction(identifier: Self.done, title: "Done"),
                ],
                intentIdentifiers: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ note: Note) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["id": note.id.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: note.id.uuidString, content: content, trigger: nil)
        )
    }

    func postBriefing(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Today"
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "briefing-\(Briefing.dayKey(Date()))", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard let idString = response.notification.request.content.userInfo["id"] as? String,
              let id = UUID(uuidString: idString) else { return }
        await MainActor.run {
            switch action {
            case Self.snooze: store.snooze(id, minutes: 10)
            case Self.done: store.markDone(id)
            default: onOpen?()
            }
        }
    }
}

/// Speaks text through phonon, falling back to the system voice if Ollama is unreachable.
@MainActor
final class Speaker {
    static let shared = Speaker()
    private var player: AVAudioPlayer?
    private let fallback = AVSpeechSynthesizer()
    /// Bumped on every call; audio for a superseded request is discarded.
    private var generation = 0

    func say(_ text: String) {
        let voice = UserDefaults.standard.string(forKey: Prefs.voice) ?? "Freya"
        generation += 1
        let current = generation
        player?.stop()
        fallback.stopSpeaking(at: .immediate)
        Task {
            do {
                let wav = try await Ollama.speech(text, voice: voice)
                guard current == generation else { return }
                player = try AVAudioPlayer(data: wav)
                player?.play()
            } catch {
                guard current == generation else { return }
                fallback.speak(AVSpeechUtterance(string: text))
            }
        }
    }
}
