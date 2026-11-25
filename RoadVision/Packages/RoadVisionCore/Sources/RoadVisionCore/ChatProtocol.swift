import Foundation

public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }

    public var id: UUID
    public var role: Role
    public var content: String
    public var date: Date

    public init(id: UUID = UUID(), role: Role, content: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.date = date
    }
}

public enum ChatStreamEvent: Equatable, Sendable {
    case delta(String)
    case done
    case ignore
    case error(String)
}

/// Encoding/decoding for OpenAI-compatible `/chat/completions` APIs
/// (Pollinations, Gemini OpenAI-compat, Groq, OpenRouter, Ollama, LM Studio).
public enum OpenAIChat {
    public struct CodingError: Error, CustomStringConvertible {
        public let description: String
    }

    /// JSON body for a chat completion request. `extra` adds string fields (e.g. "reasoning_effort": "low").
    public static func requestBody(model: String, messages: [ChatMessage], stream: Bool,
                                   temperature: Double? = 0.7, maxTokens: Int? = nil,
                                   extra: [String: String] = [:]) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if let temperature { body["temperature"] = temperature }
        if let maxTokens { body["max_tokens"] = maxTokens }
        for (k, v) in extra where body[k] == nil { body[k] = v }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Parses one line of a Server-Sent-Events stream. Only `delta.content` is returned;
    /// reasoning fields (`delta.reasoning`, `delta.reasoning_content`) are ignored.
    public static func parseStreamLine(_ rawLine: String) -> ChatStreamEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return .ignore
        }
        if let message = errorMessage(in: obj) { return .error(message) }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return .ignore }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
            return .delta(content)
        }
        // Some servers send a full message in the last chunk.
        if let message = first["message"] as? [String: Any], let content = message["content"] as? String, !content.isEmpty {
            return .delta(content)
        }
        return .ignore
    }

    /// Text of a non-streaming completion: choices[0].message.content.
    public static func parseCompletion(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodingError(description: "Ответ сервера не является JSON-объектом")
        }
        if let message = errorMessage(in: obj) { throw CodingError(description: message) }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CodingError(description: "В ответе нет choices[0].message.content")
        }
        return content
    }

    /// Error message from `{"error":{"message":...}}`, `{"error":"..."}` or `{"message":...}` (best effort).
    public static func parseError(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = errorMessage(in: obj) { return m }
            if let m = obj["message"] as? String { return m }
            if let m = obj["detail"] as? String { return m }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Model ids from `GET /models` (`{"data":[{"id":...}]}`), also accepts `{"models":[{"name"|"id":...}]}`.
    public static func parseModelList(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [[String: Any]] = []
        if let dict = obj as? [String: Any] {
            items = (dict["data"] as? [[String: Any]]) ?? (dict["models"] as? [[String: Any]]) ?? []
        } else if let arr = obj as? [[String: Any]] {
            items = arr
        }
        var seen = Set<String>()
        return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .filter { seen.insert($0).inserted }
    }

    private static func errorMessage(in obj: [String: Any]) -> String? {
        if let err = obj["error"] as? [String: Any] {
            return (err["message"] as? String) ?? (err["code"].map { "\($0)" }) ?? "Ошибка сервера"
        }
        if let err = obj["error"] as? String { return err }
        return nil
    }
}

/// A free or local OpenAI-compatible chat backend.
public struct ChatProviderPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Base URL without trailing slash, e.g. "https://api.groq.com/openai/v1".
    public var baseURL: String
    /// Path appended to `baseURL` for chat, usually "/chat/completions".
    public var chatPath: String
    public var defaultModel: String
    public var requiresAPIKey: Bool
    /// Where the user gets a (free) key.
    public var keyURL: String?
    /// Russian description shown in Settings.
    public var notes: String
    public var extraHeaders: [String: String]
    /// Extra string fields added to the JSON body (e.g. reasoning_effort).
    public var extraBody: [String: String]

    public init(id: String, name: String, baseURL: String, chatPath: String = "/chat/completions",
                defaultModel: String, requiresAPIKey: Bool, keyURL: String? = nil, notes: String,
                extraHeaders: [String: String] = [:], extraBody: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.chatPath = chatPath
        self.defaultModel = defaultModel
        self.requiresAPIKey = requiresAPIKey
        self.keyURL = keyURL
        self.notes = notes
        self.extraHeaders = extraHeaders
        self.extraBody = extraBody
    }

    public var chatURL: URL? { Self.join(baseURL, chatPath) }

    /// `GET /models` URL (OpenAI convention) — not available for every provider.
    public var modelsURL: URL? { Self.join(baseURL, "/models") }

    /// Same preset with another base URL (used for Ollama / LM Studio / custom servers).
    public func withBaseURL(_ url: String) -> ChatProviderPreset {
        var copy = self
        copy.baseURL = url
        return copy
    }

    static func join(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: b + p)
    }
}

public enum ChatPresets {
    public static let autoID = "auto"
    public static let appleOnDeviceID = "apple"

    /// Presets verified against provider documentation in November 2026. Model ids change often —
    /// the app can download the current list (`modelsURL`) and the user can override the model in Settings.
    public static let all: [ChatProviderPreset] = [
        ChatProviderPreset(
            id: "pollinations", name: "Pollinations (без ключа)",
            baseURL: "https://text.pollinations.ai", chatPath: "/openai",
            defaultModel: "openai", requiresAPIKey: false, keyURL: nil,
            notes: "Работает сразу, без регистрации и ключа. Неофициальный бесплатный сервис: скорость и доступность не гарантируются."),
        ChatProviderPreset(
            id: "gemini", name: "Google Gemini (бесплатный ключ)",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-2.5-flash-lite", requiresAPIKey: true,
            keyURL: "https://aistudio.google.com/apikey",
            notes: "Лучшее качество на русском и узбекском. Бесплатный ключ в Google AI Studio; на бесплатном тарифе запросы могут использоваться Google для улучшения сервисов."),
        ChatProviderPreset(
            id: "groq", name: "Groq (бесплатный ключ)",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "openai/gpt-oss-20b", requiresAPIKey: true,
            keyURL: "https://console.groq.com/keys",
            notes: "Очень быстрые ответы. Бесплатный план без карты, лимиты в консоли Groq.",
            extraBody: ["reasoning_effort": "low"]),
        ChatProviderPreset(
            id: "openrouter", name: "OpenRouter (бесплатные модели)",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openrouter/free", requiresAPIKey: true,
            keyURL: "https://openrouter.ai/keys",
            notes: "Модели с суффиксом :free бесплатны (ограничение запросов в день). Нужен бесплатный ключ.",
            extraHeaders: ["X-OpenRouter-Title": "RoadVision"]),
        ChatProviderPreset(
            id: "ollama", name: "Ollama на Mac (Wi‑Fi)",
            baseURL: "http://192.168.1.10:11434/v1",
            defaultModel: "llama3.2", requiresAPIKey: false,
            notes: "Локальная модель на вашем Mac в той же сети Wi‑Fi. На Mac: launchctl setenv OLLAMA_HOST \"0.0.0.0:11434\" и перезапустить Ollama. Укажите IP Mac."),
        ChatProviderPreset(
            id: "lmstudio", name: "LM Studio на Mac (Wi‑Fi)",
            baseURL: "http://192.168.1.10:1234/v1",
            defaultModel: "local-model", requiresAPIKey: false,
            notes: "Включите в LM Studio «Serve on Local Network» и укажите IP Mac."),
        ChatProviderPreset(
            id: "custom", name: "Свой OpenAI‑совместимый сервер",
            baseURL: "", defaultModel: "", requiresAPIKey: false,
            notes: "Любой сервер с API /v1/chat/completions."),
    ]

    public static func preset(id: String) -> ChatProviderPreset? {
        all.first { $0.id == id }
    }

    /// Order used by "auto": providers with a saved key first, then on-device (handled by the app), then keyless.
    public static let autoOrder: [String] = ["gemini", "groq", "openrouter", appleOnDeviceID, "pollinations"]
}

public enum ChatHistory {
    /// Keeps the newest messages whose total content length is ≤ maxCharacters.
    /// System messages are dropped (the caller prepends a fresh system prompt). The last user message is always kept.
    public static func trimmed(_ messages: [ChatMessage], maxCharacters: Int) -> [ChatMessage] {
        let conversation = messages.filter { $0.role != .system }
        var result: [ChatMessage] = []
        var total = 0
        for m in conversation.reversed() {
            let isLastUser = result.isEmpty && m.role == .user
            if !isLastUser && total + m.content.count > maxCharacters { break }
            result.append(m)
            total += m.content.count
        }
        // Do not start with an assistant message.
        var ordered = Array(result.reversed())
        while ordered.count > 1, ordered.first?.role == .assistant { ordered.removeFirst() }
        return ordered
    }
}
