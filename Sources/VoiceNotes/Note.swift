import Foundation

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var tag: String
    var remindAt: Date?
    var createdAt = Date()
    /// Bumped on every change; when two devices disagree, the newest edit wins.
    var updatedAt = Date()
    var isDone = false
    /// Set once the reminder has fired (on any device), so it isn't announced twice.
    var notified = false
    /// Deleted notes are kept as tombstones for a while so the deletion syncs to other devices.
    var isDeleted = false
}

extension Note {
    /// Tolerates files written by older versions, which lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? "other"
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? false
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }
}

enum NoteTab: String, CaseIterable {
    case reminders = "Reminders"
    case notes = "Notes"
    case done = "Done"
}

enum Prefs {
    static let voice = "voice"
    static let speakReminders = "speakReminders"
    static let model = "model"
    static let autoStop = "autoStop"
    static let notesFolder = "notesFolder"
    static let ringOnThisMac = "ringOnThisMac"

    static func register() {
        UserDefaults.standard.register(defaults: [
            voice: "Freya",
            speakReminders: true,
            model: "gemma4",
            autoStop: true,
            ringOnThisMac: true,
        ])
    }

    static var modelName: String {
        let name = UserDefaults.standard.string(forKey: model)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "gemma4" : name
    }

    /// The folder notes are stored in: a user-chosen (possibly synced) folder, or the default.
    static var notesFolderURL: URL {
        if let path = UserDefaults.standard.string(forKey: notesFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return NoteFolder.defaultURL
    }
}
