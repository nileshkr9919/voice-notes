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
    /// Set for habits like "drink water every 10–20 minutes"; `remindAt` is then the next occurrence.
    var repeatRule: RepeatRule?
    /// Set for list notes ("buy milk, eggs and bread"); empty means a plain note.
    var items: [ChecklistItem] = []

    var isRepeating: Bool { repeatRule != nil }
    var isChecklist: Bool { !items.isEmpty }
    var doneItemCount: Int { items.filter(\.done).count }

    /// What a reminder says and shows when it fires: the note without its schedule words
    /// ("Walk away from the screen", not "…every 30 minutes"), which are already in the reminder.
    var reminderText: String {
        let cleaned = Self.removingScheduleWords(from: body)
        let text = cleaned.isEmpty ? Self.removingScheduleWords(from: title) : cleaned
        guard !isChecklist else { return title + ": " + items.filter { !$0.done }.map(\.text).joined(separator: ", ") }
        return text.isEmpty ? title : text
    }

    private static let schedulePatterns: [String] = [
        #"\b(remind me to|remind me|don't forget to|do not forget to)\b"#,
        #"\b(every|each)\s+((\d+|a few|few|couple of)\s*((–|-|to)\s*\d+\s*)?)?(minutes?|mins?|hours?|hrs?|days?|mornings?|evenings?|weeks?)\b"#,
        #"\b(frequently|regularly|periodically|throughout the day|from time to time|now and then|every now and then)\b"#,
        #"\b(during|in)\s+(my\s+)?(work(ing)?\s+hours|office\s+hours|the\s+(morning|afternoon|evening))\b"#,
        #"\bon\s+(weekdays|weekends|week\s?days)\b"#,
        #"\b(today|tomorrow|tonight|this\s+(morning|afternoon|evening))(\s+(morning|afternoon|evening|night))?\b"#,
        #"\b(on\s+)?(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        #"\b(at|by|around)\s+\d{1,2}([:.]\d{2})?\s*(am|pm|a\.m\.|p\.m\.|o'clock)?"#,
        #"\bin\s+(\d+|an?|half an?)\s*(minutes?|mins?|hours?|hrs?)\b"#,
    ]

    /// Strips timing phrases; tidies spacing and punctuation that's left behind.
    static func removingScheduleWords(from text: String) -> String {
        var result = text
        for pattern in schedulePatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–").union(.whitespacesAndNewlines))
        while let last = result.last, ",;:-–".contains(last) { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespaces)
        guard let first = result.first else { return "" }
        result = first.uppercased() + result.dropFirst()
        if let last = result.last, !".!?".contains(last) { result += "." }
        return result
    }

    /// The title as shown in the list: schedule words removed (older notes may contain them).
    var displayTitle: String {
        guard remindAt != nil || isRepeating else { return title }
        var cleaned = Self.removingScheduleWords(from: title)
        if cleaned.hasSuffix("."), !title.hasSuffix(".") { cleaned.removeLast() }
        return cleaned.isEmpty ? title : cleaned
    }

    /// The note as plain text, for copying, speaking and searching.
    var plainText: String {
        guard isChecklist else { return body }
        let list = items.map { "\($0.done ? "✓" : "-") \($0.text)" }.joined(separator: "\n")
        return body.isEmpty || body == title ? list : body + "\n" + list
    }
}

struct ChecklistItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
}

/// How a repeating reminder recurs.
struct RepeatRule: Codable, Equatable {
    /// Gap between reminders. When min < max, each gap is picked at random in the range.
    var minMinutes: Int
    var maxMinutes: Int
    /// Counts only time spent at the Mac: a break restarts the timer ("get up and walk").
    var activeTimeOnly = false
    /// Active hours as minutes since midnight; nil means all day. A start after the end wraps past midnight.
    var startMinute: Int?
    var endMinute: Int?
    /// Allowed weekdays (Calendar numbering, 1 = Sunday); nil means every day.
    var weekdays: [Int]?
    /// How many times it was marked done on `doneDate`'s day.
    var doneCount = 0
    var doneDate: Date?

    /// Same schedule, ignoring the done counters.
    func sameSchedule(as other: RepeatRule?) -> Bool {
        guard var other else { return false }
        other.doneCount = doneCount
        other.doneDate = doneDate
        return other == self
    }

    var doneToday: Int {
        guard let doneDate, Calendar.current.isDateInToday(doneDate) else { return 0 }
        return doneCount
    }

    mutating func recordDone(at date: Date = Date()) {
        doneCount = doneToday + 1
        doneDate = date
    }

    /// The next reminder after `date`, inside the active hours and weekdays.
    func nextOccurrence(after date: Date, randomMinutes: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Date {
        let low = max(1, min(minMinutes, maxMinutes))
        let gap = randomMinutes(low...max(low, maxMinutes))
        return nextActive(from: date.addingTimeInterval(TimeInterval(gap * 60)))
    }

    /// `date` if it's inside the active window, otherwise the start of the next window.
    func nextActive(from date: Date) -> Date {
        if isActive(at: date) { return date }
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let start = startMinute ?? 0
        for offset in 0...8 {
            // Wall-clock time on each day, so DST changes don't shift the window by an hour.
            guard let candidateDay = cal.date(byAdding: .day, value: offset, to: day),
                  let candidate = cal.date(bySettingHour: start / 60, minute: start % 60, second: 0,
                                           of: candidateDay) else { continue }
            if candidate > date && isActive(at: candidate) { return candidate }
        }
        return date
    }

    func isActive(at date: Date) -> Bool {
        let cal = Calendar.current
        let parts = cal.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = parts.hour! * 60 + parts.minute!
        var weekday = parts.weekday!
        if let start = startMinute, let end = endMinute, start != end {
            let inWindow = start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
            guard inWindow else { return false }
            // The after-midnight part of an overnight window belongs to the day it started.
            if start > end && minute < end { weekday = weekday == 1 ? 7 : weekday - 1 }
        }
        return weekdays.map { $0.contains(weekday) } ?? true
    }

    /// Short description, e.g. "every 10–20 min · 9:00–18:00 · weekdays".
    var summary: String {
        let range = minMinutes % 60 == 0 && maxMinutes % 60 == 0
            ? "\(minMinutes / 60)–\(maxMinutes / 60) hours" : "\(minMinutes)–\(maxMinutes) min"
        var parts = ["every " + (minMinutes == maxMinutes ? Self.duration(minMinutes) : range)]
        if activeTimeOnly { parts[0] += " at your Mac" }
        if let start = startMinute, let end = endMinute {
            parts.append("\(Self.clock(start))–\(Self.clock(end))")
        }
        if let weekdays {
            let set = Set(weekdays)
            parts.append(set == [2, 3, 4, 5, 6] ? "weekdays" : set == [1, 7] ? "weekends"
                : weekdays.filter { (1...7).contains($0) }.sorted()
                    .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "hour" : "\(minutes / 60) hours" }
        return "\(minutes) min"
    }

    private static func clock(_ minute: Int) -> String {
        String(format: "%d:%02d", minute / 60, minute % 60)
    }
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
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule)
        items = try c.decodeIfPresent([ChecklistItem].self, forKey: .items) ?? []
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
    /// Habit reminders are paused on this Mac until this time (seconds since 1970; 0 = not paused).
    static let habitsPausedUntil = "habitsPausedUntil"
    static let briefingEnabled = "briefingEnabled"
    /// Minutes after midnight for the daily briefing.
    static let briefingMinute = "briefingMinute"
    static let lastBriefingDay = "lastBriefingDay"

    static func register() {
        UserDefaults.standard.register(defaults: [
            voice: "Freya",
            speakReminders: true,
            model: "gemma4",
            autoStop: true,
            ringOnThisMac: true,
            briefingEnabled: false,
            briefingMinute: 8 * 60 + 30,
        ])
    }

    static var pausedUntil: Date? {
        let t = UserDefaults.standard.double(forKey: habitsPausedUntil)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
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
