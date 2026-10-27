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
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "body": ["type": "string"],
                "remindAt": ["type": ["string", "null"]],
                "tag": ["type": "string", "enum": tags],
                "items": ["type": ["array", "null"], "items": ["type": "string"]],
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
            "required": ["title", "body", "remindAt", "tag", "repeat", "items"],
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
        return makeNote(from: parsed, original: text, now: now)
    }

    static func makeNote(from parsed: ParsedNote, original: String, now: Date) -> Note {
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = Note(
            title: title.isEmpty ? String(original.prefix(40)) : title,
            body: body.isEmpty ? original : body,
            tag: tags.contains(parsed.tag) ? parsed.tag : "other",
            remindAt: normalizeReminder(parseDate(parsed.remindAt), now: now),
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
        return RepeatRule(
            minMinutes: low, maxMinutes: high,
            activeTimeOnly: parsed.activeTimeOnly ?? false,
            startMinute: minuteOfDay(parsed.startTime), endMinute: minuteOfDay(parsed.endTime),
            weekdays: (days?.isEmpty ?? true) || days?.count == 7 ? nil : days?.sorted()
        )
    }

    /// "09:30" → 570.
    static func minuteOfDay(_ s: String?) -> Int? {
        guard let parts = s?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2,
              (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func systemPrompt(now: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let weekday = now.formatted(.dateTime.weekday(.wide))
        // Small models are bad at weekday arithmetic, so spell out the coming week.
        let week = (0..<8).map { offset -> String in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: now)!
            let label = offset == 0 ? " (today)" : offset == 1 ? " (tomorrow)" : ""
            return "\(day.formatted(.dateTime.weekday(.wide))) = \(day.formatted(.iso8601.year().month().day()))\(label)"
        }.joined(separator: "\n")

        return """
        You turn a short spoken note into JSON.
        Current local date-time: \(iso.string(from: now)) (\(weekday)).
        Upcoming dates:
        \(week)

        - title: short summary, at most 6 words.
        - body: the full note, cleaned up (fix punctuation, drop filler words like "remind me to"), keep every detail.
        - remindAt: set it whenever the note mentions ANY day or time (an appointment, a deadline, "remind me", "on Friday at 4"). ISO-8601 date-time with the same UTC offset as the current time, always in the future. Use the upcoming dates list for weekdays. A day without a time means 09:00. "in 20 minutes" is relative to now. "tonight" means 20:00. If no day or time is mentioned, null.
        - repeat: ONLY for recurring reminders/habits ("every 20 minutes", "every hour", "regularly", "frequently", "throughout the day", "keep reminding me"); otherwise null. When set, remindAt is null.
          - minMinutes/maxMinutes: the gap. "every 10-20 minutes" → 10 and 20. A fixed interval uses the same number for both. Vague wording: drink water/hydrate "frequently/regularly" → 30 and 45; get up, walk, stretch, move, posture, rest your eyes, take a break "frequently/regularly" → 45 and 60; anything else vague → 60 and 60.
          - activeTimeOnly: true for reminders about breaking up sitting or screen time (get up, walk, stretch, move, posture, rest your eyes, take a break), since the timer should only count time at the computer; false otherwise (e.g. drink water, take medicine).
          - startTime/endTime: "HH:mm" if the user limits the hours ("during work hours" → 09:00 and 18:00, "in the morning" → 08:00 and 12:00), else null.
          - days: weekday codes if limited ("on weekdays" / "during work hours" → mon tue wed thu fri), else null.
        - items: when the note lists several separate things to buy, pack, do or remember ("buy milk, eggs and bread", "pack passport, charger, headphones", "to do: call bank, email Sam, book flights"), one short item each, capitalized, without the verb repeated ("Milk", "Eggs", "Bread"); the title names the list ("Groceries", "Packing list", "To-dos") and body is a short summary or the title. Otherwise null. A single task is NOT a list.
        - tag: personal (family, home, chores, passwords, general life), work (job, office, clients, meetings), shopping (things to buy), health (doctor, medicine, exercise), finance (bills, bank, money, rent), idea (thoughts, plans, inspiration), other.
        """
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
        local.timeZone = .current
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
