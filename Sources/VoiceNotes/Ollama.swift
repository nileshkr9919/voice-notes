import Foundation

enum OllamaError: LocalizedError, Equatable {
    case notRunning
    case modelMissing(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Ollama isn't running. Open the Ollama app or run `ollama serve`."
        case .modelMissing(let model): "Model “\(model)” isn't installed. Run `ollama pull \(model)`."
        case .badResponse(let detail): "Ollama returned an unexpected response: \(detail)"
        }
    }
}

/// Talks to the local Ollama server: a language model for understanding notes,
/// phonon for speaking them aloud.
enum Ollama {
    static let baseURL = URL(string: "http://localhost:11434")!
    static let speechModel = "phonon"
    static let tags = ["personal", "work", "shopping", "health", "finance", "idea", "other"]

    struct ParsedNote: Decodable {
        let title: String
        let body: String
        let remindAt: String?
        let tag: String
        var `repeat`: ParsedRepeat? = nil
        var items: [String]? = nil
        var isQuestion: Bool? = nil
    }

    /// What the user meant: a new note, or a question about their existing notes.
    enum Interpretation {
        case note(Note)
        case question
    }

    /// Reads dictated or typed text as either a new note or a question about the notes.
    static func interpret(_ text: String, model: String, now: Date = Date()) async throws -> Interpretation {
        let parsed = try await requestParse(text, model: model, now: now)
        if parsed.isQuestion == true { return .question }
        return .note(makeNote(from: parsed, original: text, now: now))
    }

    struct ParsedRepeat: Decodable {
        let minMinutes: Int
        let maxMinutes: Int
        let activeTimeOnly: Bool?
        let startTime: String?
        let endTime: String?
        let days: [String]?
    }

    /// Turns raw dictated text into a structured note.
    static func parse(_ text: String, model: String, now: Date = Date()) async throws -> Note {
        makeNote(from: try await requestParse(text, model: model, now: now), original: text, now: now)
    }

    private static func requestParse(_ text: String, model: String, now: Date) async throws -> ParsedNote {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "body": ["type": "string"],
                "remindAt": ["type": ["string", "null"]],
                "tag": ["type": "string", "enum": tags],
                "items": ["type": ["array", "null"], "items": ["type": "string"]],
                "isQuestion": ["type": "boolean"],
                "repeat": [
                    "type": ["object", "null"],
                    "properties": [
                        "minMinutes": ["type": "integer"],
                        "maxMinutes": ["type": "integer"],
                        "activeTimeOnly": ["type": "boolean"],
                        "startTime": ["type": ["string", "null"]],
                        "endTime": ["type": ["string", "null"]],
                        "days": ["type": ["array", "null"], "items": ["type": "string", "enum": weekdayNames]],
                    ],
                    "required": ["minMinutes", "maxMinutes", "activeTimeOnly", "startTime", "endTime", "days"],
                ],
            ],
            "required": ["isQuestion", "title", "body", "remindAt", "tag", "repeat", "items"],
        ]
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "format": schema,
            "keep_alive": "15m",
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": systemPrompt(now: now)],
                ["role": "user", "content": text],
            ],
        ]

        let data = try await send("api/chat", payload, model: model)
        struct ChatResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        guard let content = try? JSONDecoder().decode(ChatResponse.self, from: data).message.content,
              let parsed = try? JSONDecoder().decode(ParsedNote.self, from: Data(content.utf8)) else {
            throw OllamaError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return parsed
    }

    /// Answers a question from the user's notes only. Runs locally like everything else.
    static func answer(_ question: String, notes: [Note], model: String, now: Date = Date()) async throws -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let context = notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(300).map { note in
            var line = "- \(note.title): \(note.plainText.replacingOccurrences(of: "\n", with: "; "))"
            if let rule = note.repeatRule {
                line += " (repeats \(rule.summary))"
            } else if let at = note.remindAt {
                line += " (reminder \(iso.string(from: at)))"
            }
            if note.isDone { line += " (done)" }
            return line + " [\(note.tag)]"
        }.joined(separator: "\n")
        let system = """
        You answer the user's question using ONLY their notes below. Current local date-time: \(iso.string(from: now)).
        Reply in one or two short sentences of plain text. Copy exact details (passwords, numbers, names, dates, times) verbatim.
        If the notes don't contain the answer, reply exactly: I couldn't find that in your notes.

        Notes:
        \(context.isEmpty ? "(no notes yet)" : context)
        """
        let payload: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "15m",
            "options": ["temperature": 0],
            "messages": [["role": "system", "content": system], ["role": "user", "content": question]],
        ]
        let data = try await send("api/chat", payload, model: model)
        struct ChatResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data).message.content else {
            throw OllamaError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeNote(from parsed: ParsedNote, original: String, now: Date) -> Note {
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = Note(
            title: title.isEmpty ? String(original.prefix(40)) : title,
            body: body.isEmpty ? original : body,
            tag: tags.contains(parsed.tag) ? parsed.tag : "other",
            remindAt: normalizeReminder(adjustLateNightTomorrow(parseDate(parsed.remindAt), text: original, now: now),
                                        now: now),
            createdAt: now
        )
        let items = (parsed.items ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if items.count >= 2 {
            note.items = items.map { ChecklistItem(text: $0) }
        }
        if let rule = parsed.repeat.flatMap(makeRule) {
            note.repeatRule = rule
            note.remindAt = rule.nextOccurrence(after: now)
        }
        return note
    }

    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    static func makeRule(_ parsed: ParsedRepeat) -> RepeatRule? {
        // Sanity limits: at least every minute, at most once a week.
        let low = min(max(parsed.minMinutes, 1), 7 * 24 * 60)
        let high = min(max(parsed.maxMinutes, low), 7 * 24 * 60)
        guard parsed.minMinutes > 0 || parsed.maxMinutes > 0 else { return nil }
        let days = parsed.days?.compactMap { weekdayNames.firstIndex(of: $0.lowercased()).map { $0 + 1 } }
        let hours = minuteOfDay(parsed.startTime).flatMap { start in
            minuteOfDay(parsed.endTime).map { (start, $0) }
        }
        return RepeatRule(
            minMinutes: low, maxMinutes: high,
            activeTimeOnly: parsed.activeTimeOnly ?? false,
            // Active hours only when both ends are usable; half a window is ignored.
            startMinute: hours.map(\.0), endMinute: hours.map(\.1),
            weekdays: (days?.isEmpty ?? true) || days?.count == 7 ? nil : days?.sorted()
        )
    }

    /// "09:30" → 570.
    static func minuteOfDay(_ s: String?) -> Int? {
        // "09:00" or "09:00:00".
        guard let parts = s?.split(separator: ":").compactMap({ Int($0) }), (2...3).contains(parts.count),
              (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func systemPrompt(now: Date) -> String {
        // Everything in local wall-clock time: no UTC offsets, which go wrong across DST changes.
        // Same time zone as the reminder scheduling (Calendar.current), so they always agree.
        func formatter(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Calendar.current.timeZone
            f.dateFormat = format
            return f
        }
        let local = formatter("yyyy-MM-dd'T'HH:mm")
        let dayFormat = formatter("yyyy-MM-dd")
        let weekdayName = formatter("EEEE")
        let weekday = weekdayName.string(from: now)
        // Small models are bad at weekday arithmetic, so spell out the coming week.
        let week = (0..<8).map { offset -> String in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: now)!
            let label = offset == 0 ? " (today)" : offset == 1 ? " (tomorrow)" : ""
            return "\(weekdayName.string(from: day)) = \(dayFormat.string(from: day))\(label)"
        }.joined(separator: "\n")

        return """
        You turn a short spoken note into JSON.
        - isQuestion: true ONLY if the user is asking about something they saved earlier ("what's the wifi password at mom's?", "when is my dentist appointment?", "what do I need to buy?"); false when they are dictating a new note, list or reminder (including "remind me to…"). When true, fill the other fields minimally.
        Current local date-time: \(local.string(from: now)) (\(weekday)).
        Upcoming dates:
        \(week)

        - title: short summary, at most 6 words.
        - body: the full note, cleaned up (fix punctuation, drop filler words like "remind me to"), keep every detail.
        - remindAt: set it whenever the note mentions ANY day or time (an appointment, a deadline, "remind me", "on Friday at 4"). Local date-time as "yyyy-MM-ddTHH:mm" with NO timezone offset, always in the future. Use the upcoming dates list for weekdays. A day without a time means 09:00. "in 20 minutes" is relative to now. "tonight" means 20:00. If no day or time is mentioned, null.
        - repeat: ONLY for recurring reminders/habits ("every 20 minutes", "every hour", "regularly", "frequently", "throughout the day", "keep reminding me"); otherwise null. When set, remindAt is null.
          - minMinutes/maxMinutes: the gap. "every 10-20 minutes" → 10 and 20. A fixed interval uses the same number for both. Vague wording: drink water/hydrate "frequently/regularly" → 30 and 45; get up, walk, stretch, move, posture, rest your eyes, take a break "frequently/regularly" → 45 and 60; anything else vague → 60 and 60.
          - activeTimeOnly: true for reminders about breaking up sitting or screen time (get up, walk, stretch, move, posture, rest your eyes, take a break), since the timer should only count time at the computer; false otherwise (e.g. drink water, take medicine).
          - startTime/endTime: "HH:mm" if the user limits the hours ("during work hours" → 09:00 and 18:00, "in the morning" → 08:00 and 12:00), else null.
          - days: weekday codes if limited ("on weekdays" / "during work hours" → mon tue wed thu fri), else null.
        - items: when the note lists several separate things to buy, pack, do or remember ("buy milk, eggs and bread", "pack passport, charger, headphones", "to do: call bank, email Sam, book flights"), one short item each, capitalized, without the verb repeated ("Milk", "Eggs", "Bread"); the title names the list ("Groceries", "Packing list", "To-dos") and body is a short summary or the title. Otherwise null. A single task is NOT a list.
        - tag: personal (family, home, chores, passwords, general life), work (job, office, clients, meetings), shopping (things to buy), health (doctor, medicine, exercise), finance (bills, bank, money, rent), idea (thoughts, plans, inspiration), other.
        """
    }

    /// Said between midnight and 4 AM, "tomorrow" means the coming morning (people haven't
    /// slept yet), so a reminder the model put on the calendar's tomorrow moves back a day.
    static func adjustLateNightTomorrow(_ date: Date?, text: String, now: Date) -> Date? {
        let cal = Calendar.current
        guard let date, cal.component(.hour, from: now) < 4,
              text.lowercased().contains("tomorrow"),
              let calendarTomorrow = cal.date(byAdding: .day, value: 1, to: now),
              cal.isDate(date, inSameDayAs: calendarTomorrow),
              let earlier = cal.date(byAdding: .day, value: -1, to: date), earlier > now else { return date }
        return earlier
    }

    /// Keeps reminders in the future. A time that already passed today
    /// ("at 9" said at 10 PM) moves to tomorrow; anything older is dropped.
    static func normalizeReminder(_ date: Date?, now: Date) -> Date? {
        guard let date else { return nil }
        if date > now.addingTimeInterval(-60) { return max(date, now) }
        if now.timeIntervalSince(date) < 24 * 3600,
           let next = Calendar.current.date(byAdding: .day, value: 1, to: date), next > now {
            return next
        }
        return nil
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "null" else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // No offset given: treat as local time.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = Calendar.current.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: s) { return d }
        }
        return nil
    }

    /// Returns WAV audio of `text` spoken in `voice`.
    static func speech(_ text: String, voice: String) async throws -> Data {
        try await send("v1/audio/speech", ["model": speechModel, "input": text, "voice": voice], model: speechModel)
    }

    static func voices() async throws -> [String] {
        let data = try await send("api/show", ["model": speechModel], model: speechModel)
        struct Show: Decodable { let voices: [String]? }
        return try JSONDecoder().decode(Show.self, from: data).voices ?? []
    }

    /// Loads the model into memory ahead of time so the first note isn't slow.
    static func warmUp(model: String) {
        Task.detached {
            _ = try? await send("api/generate", ["model": model, "keep_alive": "15m"], model: model)
        }
    }

    /// Describes what's missing for the app to work fully, or nil if all is well.
    static func healthProblem(model: String) async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return OllamaError.notRunning.errorDescription
        }
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let installed = (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
        let missing = [model, speechModel].filter { !isInstalled($0, in: installed) }
        guard !missing.isEmpty else { return nil }
        return "Missing model\(missing.count > 1 ? "s" : ""). Run " +
            missing.map { "`ollama pull \($0)`" }.joined(separator: " and ") + "."
    }

    static func isInstalled(_ model: String, in installed: [String]) -> Bool {
        let wanted = model.contains(":") ? model : model + ":latest"
        return installed.contains(wanted) || installed.contains(model)
    }

    private static func send(_ path: String, _ body: [String: Any], model: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(error.code) {
            throw OllamaError.notRunning
        }
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return data }
        let message = String(decoding: data, as: UTF8.self)
        if http.statusCode == 404, message.localizedCaseInsensitiveContains("not found") {
            throw OllamaError.modelMissing(model)
        }
        throw OllamaError.badResponse("HTTP \(http.statusCode) \(message.prefix(200))")
    }
}
