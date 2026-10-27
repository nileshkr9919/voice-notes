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
            ],
            "required": ["title", "body", "remindAt", "tag"],
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
        return Note(
            title: title.isEmpty ? String(original.prefix(40)) : title,
            body: body.isEmpty ? original : body,
            tag: tags.contains(parsed.tag) ? parsed.tag : "other",
            remindAt: normalizeReminder(parseDate(parsed.remindAt), now: now),
            createdAt: now
        )
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
