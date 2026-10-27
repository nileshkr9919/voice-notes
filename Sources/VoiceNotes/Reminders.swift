import AVFoundation
import os
@preconcurrency import UserNotifications

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

    /// Shows a reminder now — unless macOS already showed it from the backup schedule below.
    func post(_ note: Note) {
        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(identifier: note.id.uuidString, content: Self.content(for: note),
                                            trigger: nil)
        let scheduledPrefix = Self.scheduledPrefix + note.id.uuidString
        center.getDeliveredNotifications { delivered in
            guard !delivered.contains(where: { $0.request.identifier.hasPrefix(scheduledPrefix) }) else { return }
            center.add(request)
        }
    }

    // MARK: Backup schedule
    //
    // The app's own timer fires reminders while it runs. As a safety net, every upcoming
    // one-time reminder is also scheduled with macOS, which shows it even if the app has
    // been quit. Habits stay app-only: they depend on whether the person is at the Mac.

    nonisolated private static let scheduledPrefix = "scheduled-"
    /// macOS keeps at most 64 pending notifications per app.
    static let scheduleLimit = 60

    /// The one-time reminders macOS should hold right now, soonest first, keyed by request id.
    /// The id includes the time, so a changed time replaces the old request.
    static func plannedSchedule(for notes: [Note], now: Date, ringsHere: Bool) -> [(id: String, note: Note)] {
        guard ringsHere else { return [] }
        return notes
            .filter { !$0.isDeleted && !$0.isDone && !$0.isRepeating && !$0.notified
                      && ($0.remindAt.map { $0 > now } ?? false) }
            .sorted { $0.remindAt! < $1.remindAt! }
            .prefix(scheduleLimit)
            .map { (scheduledPrefix + "\($0.id.uuidString)-\(Int($0.remindAt!.timeIntervalSince1970))", $0) }
    }

    /// Brings macOS's pending notifications in line with the notes: adds new or moved
    /// reminders and removes ones that were completed, snoozed, edited or deleted.
    func syncSchedule(_ notes: [Note], ringsHere: Bool) {
        let planned = Self.plannedSchedule(for: notes, now: Date(), ringsHere: ringsHere)
        let requests = planned.map { id, note in
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                        from: note.remindAt!)
            return UNNotificationRequest(identifier: id, content: Self.content(for: note),
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        }
        let wanted = Set(requests.map(\.identifier))
        let center = UNUserNotificationCenter.current()
        let prefix = Self.scheduledPrefix
        center.getPendingNotificationRequests { pending in
            let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            center.removePendingNotificationRequests(withIdentifiers: Array(existing.subtracting(wanted)))
            for request in requests where !existing.contains(request.identifier) {
                center.add(request)
            }
            Logger(subsystem: "VoiceNotes", category: "schedule")
                .notice("macOS holds \(wanted.count) scheduled reminders")
        }
    }

    private static func content(for note: Note) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.reminderText
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["id": note.id.uuidString]
        return content
    }

    /// Whether macOS will actually show our notifications (people can switch them off,
    /// and macOS may reset the choice after an app update).
    func notificationsEnabled() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return settings.alertSetting == .enabled
        default: return false
        }
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
