import Foundation

/// The optional daily spoken summary: today's reminders, anything overdue, and habits.
enum Briefing {
    /// The words to say, built from the notes (no model call, so it's instant and predictable).
    static func text(for notes: [Note], now: Date = Date()) -> String {
        let cal = Calendar.current
        let open = notes.filter { !$0.isDone }
        let habits = open.filter(\.isRepeating)
        let timed = open.filter { !$0.isRepeating && $0.remindAt != nil }
        let overdue = timed.filter { $0.remindAt! < now }.sorted { $0.remindAt! < $1.remindAt! }
        let today = timed.filter { $0.remindAt! >= now && cal.isDate($0.remindAt!, inSameDayAs: now) }
            .sorted { $0.remindAt! < $1.remindAt! }

        var parts = [greeting(at: now) + "."]
        if today.isEmpty && overdue.isEmpty {
            parts.append("Nothing is scheduled for today.")
        }
        if !today.isEmpty {
            let list = today.map { "\($0.title) at \($0.remindAt!.formatted(date: .omitted, time: .shortened))" }
            parts.append("Today you have \(count(today.count, "reminder")): \(spokenList(list)).")
        }
        if !overdue.isEmpty {
            parts.append("Still open from earlier: \(spokenList(overdue.map(\.title))).")
        }
        if !habits.isEmpty {
            parts.append("Habits: \(spokenList(habits.map(\.title))).")
        }
        parts.append("Have a good day.")
        return parts.joined(separator: " ")
    }

    /// Whether to give today's briefing now: on, not given yet today, past the chosen time,
    /// and not more than four hours late (a Mac opened at 3 PM shouldn't say "good morning").
    static func isDue(now: Date, enabled: Bool, minuteOfDay: Int, lastDay: String?) -> Bool {
        guard enabled, lastDay != dayKey(now) else { return false }
        let cal = Calendar.current
        guard let start = cal.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: now)
        else { return false }
        return now >= start && now < start.addingTimeInterval(4 * 3600)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "one \(noun)" : "\(n) \(noun)s"
    }

    /// "a", "a and b", "a, b, and c".
    private static func spokenList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
