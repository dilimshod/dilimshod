import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Protocol & errors

/// A chat model the assistant can talk to. `stream(messages:)` yields text deltas of the answer
/// (only the visible answer — never reasoning tokens) and finishes, throws `ChatBackendError`,
/// or throws `CancellationError` when the consuming task is cancelled.
protocol ChatBackend {
    /// Short name for the UI, e.g. "Gemini · gemini-2.5-flash-lite".
    var displayName: String { get }
    /// Preset id ("gemini", "pollinations", …) or `ChatPresets.appleOnDeviceID`.
    var providerID: String { get }
    /// How many characters of conversation history fit comfortably into this model's context.
    var historyCharacterBudget: Int { get }
    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

extension ChatBackend {
    var providerID: String { "" }
    var historyCharacterBudget: Int { 6000 }
}

/// Errors of the chat backends; `message` is Russian text ready for the UI.
struct ChatBackendError: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unauthorized
        case rateLimited
        case http(Int)
        case timeout
        case network
        case invalidConfiguration
        case emptyResponse
        case server
        case unavailable
    }

    let kind: Kind
    let message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Short provider name without the parenthesised hint: "Google Gemini (бесплатный ключ)" → "Google Gemini".
func chatProviderShortName(_ preset: ChatProviderPreset) -> String {
    let name = preset.name
    if let range = name.range(of: " (") {
        return String(name[..<range.lowerBound])
    }
    return name
}

/// Human-readable text of any error thrown by the chat layer.
func chatErrorDescription(_ error: Error) -> String {
    if let backendError = error as? ChatBackendError { return backendError.message }
    if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
    return error.localizedDescription
}

// MARK: - OpenAI-compatible backend

/// Streams `POST {baseURL}{chatPath}` (`"stream": true`, Server-Sent Events) from any OpenAI-compatible server:
/// Pollinations, Gemini (OpenAI compatibility endpoint), Groq, OpenRouter, Ollama, LM Studio or a custom server.
final class OpenAICompatibleBackend: ChatBackend, Sendable {
    let preset: ChatProviderPreset
    let model: String
    let displayName: String
    let firstByteTimeout: TimeInterval
    private let apiKey: String?
    private let session: URLSession

    var providerID: String { preset.id }
    var historyCharacterBudget: Int { 6000 }

    /// - Parameters:
    ///   - preset: provider preset (already carrying a custom base URL if needed, see `ChatProviderPreset.withBaseURL`).
    ///   - apiKey: Bearer key; nil/empty → no `Authorization` header.
    ///   - model: model id; empty → `preset.defaultModel`.
    ///   - firstByteTimeout: seconds to wait for the first line of the response before giving up.
    init(preset: ChatProviderPreset, apiKey: String?, model: String,
         session: URLSession = .shared, firstByteTimeout: TimeInterval = 15) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preset = preset
        self.model = trimmedModel.isEmpty ? preset.defaultModel : trimmedModel
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmedKey?.isEmpty ?? true) ? nil : trimmedKey
        self.session = session
        self.firstByteTimeout = firstByteTimeout
        let shortName = chatProviderShortName(preset)
        self.displayName = self.model.isEmpty ? shortName : "\(shortName) · \(self.model)"
    }

    var shortName: String { chatProviderShortName(preset) }

    /// Builds the streaming request; throws `.invalidConfiguration` for a bad URL or a missing model.
    func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        guard let url = preset.chatURL, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            let shown = preset.baseURL.isEmpty ? "не указан" : preset.baseURL
            throw ChatBackendError(kind: .invalidConfiguration,
                                   message: "\(shortName): неверный адрес сервера (\(shown)). Укажите его в настройках.")
        }
        guard !model.isEmpty else {
            throw ChatBackendError(kind: .invalidConfiguration,
                                   message: "\(shortName): не указана модель. Укажите её в настройках.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Idle timeout between packets while streaming; the first byte has its own, shorter watchdog.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in preset.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try OpenAIChat.requestBody(model: model, messages: messages, stream: true,
                                                      temperature: 0.7, maxTokens: nil, extra: preset.extraBody)
        return request
    }

    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(messages: messages)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let session = self.session
        let name = shortName
        let timeout = firstByteTimeout
        return AsyncThrowingStream { continuation in
            let gate = FirstByteGate()
            let worker = Task {
                do {
                    try await OpenAICompatibleBackend.performStreaming(request: request, session: session,
                                                                       providerName: name, gate: gate,
                                                                       continuation: continuation)
                    continuation.finish()
                } catch {
                    if gate.didTimeOut {
                        continuation.finish(throwing: ChatBackendError(
                            kind: .timeout,
                            message: "\(name): сервер не ответил за \(Int(timeout)) с"))
                    } else if Task.isCancelled || error is CancellationError
                                || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: OpenAICompatibleBackend.transportError(
                            error, providerName: name, url: request.url))
                    }
                }
            }
            let watchdog = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                } catch {
                    return
                }
                if gate.expire() {
                    worker.cancel()
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                watchdog.cancel()
            }
        }
    }

    /// Reads the SSE response line by line and yields `delta.content` pieces.
    private static func performStreaming(request: URLRequest, session: URLSession, providerName: String,
                                         gate: FirstByteGate,
                                         continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatBackendError(kind: .server, message: "\(providerName): некорректный ответ сервера")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            _ = gate.markReceived()
            throw httpError(status: http.statusCode, body: body, providerName: providerName)
        }

        var receivedContent = false
        // Lines that are not SSE events — a server that ignored "stream": true and answered with plain JSON.
        var plainBody = ""
        for try await line in bytes.lines {
            guard gate.markReceived() else { throw CancellationError() }
            try Task.checkCancellation()
            switch OpenAIChat.parseStreamLine(line) {
            case .delta(let text):
                receivedContent = true
                continuation.yield(text)
            case .done:
                return
            case .error(let message):
                throw ChatBackendError(kind: .server, message: "\(providerName): \(message)")
            case .ignore:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("data:"), !trimmed.hasPrefix(":"), !trimmed.hasPrefix("event:"),
                   !trimmed.hasPrefix("id:"), !trimmed.hasPrefix("retry:"), plainBody.count < 65_536 {
                    plainBody += line + "\n"
                }
            }
        }
        if !receivedContent {
            let trimmedBody = plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBody.isEmpty {
                let data = Data(trimmedBody.utf8)
                if let text = try? OpenAIChat.parseCompletion(data),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.yield(text)
                    return
                }
                if let message = OpenAIChat.parseError(data) {
                    throw ChatBackendError(kind: .server, message: "\(providerName): \(message)")
                }
            }
            throw ChatBackendError(kind: .emptyResponse, message: "\(providerName): пустой ответ")
        }
    }

    /// Maps a non-2xx HTTP status (and up to 4 KB of its body) to a Russian error.
    static func httpError(status: Int, body: Data, providerName: String) -> ChatBackendError {
        let detail = OpenAIChat.parseError(body).map { raw -> String in
            let flat = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > 180 ? String(flat.prefix(180)) + "…" : flat
        }
        let suffix = detail.map { " (\($0))" } ?? ""
        switch status {
        case 401, 403:
            return ChatBackendError(kind: .unauthorized,
                                    message: "\(providerName): Неверный или отсутствующий ключ API\(suffix)")
        case 400 where detail?.lowercased().contains("api key") == true:
            return ChatBackendError(kind: .unauthorized,
                                    message: "\(providerName): Неверный или отсутствующий ключ API\(suffix)")
        case 429:
            return ChatBackendError(kind: .rateLimited,
                                    message: "\(providerName): Превышен лимит бесплатных запросов, попробуйте позже")
        case 404:
            return ChatBackendError(kind: .http(status),
                                    message: "\(providerName): модель или адрес не найдены (404)\(suffix)")
        case 500...599:
            return ChatBackendError(kind: .http(status),
                                    message: "\(providerName): сервис временно недоступен (код \(status))\(suffix)")
        default:
            return ChatBackendError(kind: .http(status),
                                    message: "\(providerName): ошибка сервера \(status)\(suffix)")
        }
    }

    /// Maps URLSession errors to Russian messages (with a hint for servers in the local network).
    static func transportError(_ error: Error, providerName: String, url: URL?) -> Error {
        if error is ChatBackendError || error is CancellationError { return error }
        guard let urlError = error as? URLError else {
            return ChatBackendError(kind: .network, message: "\(providerName): \(error.localizedDescription)")
        }
        let host = url?.host ?? ""
        let isLocal = isLocalNetworkHost(host)
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            if isLocal {
                return ChatBackendError(kind: .network,
                                        message: "\(providerName): нет связи с \(host). Телефон и Mac должны быть в одной сети Wi‑Fi.")
            }
            return ChatBackendError(kind: .network, message: "Нет подключения к интернету")
        case .timedOut:
            return ChatBackendError(kind: .timeout, message: "\(providerName): сервер не отвечает")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            if isLocal {
                return ChatBackendError(
                    kind: .network,
                    message: "Не удаётся подключиться к \(host). Проверьте IP‑адрес Mac, что он в той же сети Wi‑Fi, сервер слушает сеть (не только localhost) и приложению разрешён доступ к локальной сети (Настройки → Конфиденциальность → Локальная сеть).")
            }
            return ChatBackendError(kind: .network, message: "\(providerName): не удаётся подключиться к \(host)")
        case .appTransportSecurityRequiresSecureConnection:
            return ChatBackendError(kind: .invalidConfiguration,
                                    message: "\(providerName): адрес http:// разрешён только для серверов в локальной сети. Используйте https://.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return ChatBackendError(kind: .network, message: "\(providerName): ошибка защищённого соединения")
        default:
            return ChatBackendError(kind: .network, message: "\(providerName): \(urlError.localizedDescription)")
        }
    }

    /// True for private IPv4 ranges, loopback and `.local` names (Ollama / LM Studio on a Mac in the same Wi‑Fi).
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") {
            return true
        }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}

/// Shared flag between the streaming task and its first-byte watchdog.
private final class FirstByteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    private var timedOut = false

    /// Marks that data arrived. Returns false if the watchdog already fired (the stream must stop).
    func markReceived() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if timedOut { return false }
        received = true
        return true
    }

    /// Called by the watchdog. Returns true if nothing arrived yet (the request is now considered timed out).
    func expire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if received { return false }
        timedOut = true
        return true
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

// MARK: - Model list

/// Downloads the current model ids of a provider (`GET {baseURL}/models`). Model ids change often.
enum ChatModelCatalog {
    static func fetchModels(for preset: ChatProviderPreset, apiKey: String?,
                            session: URLSession = .shared) async throws -> [String] {
        let name = chatProviderShortName(preset)
        guard let url = preset.modelsURL else {
            throw ChatBackendError(kind: .invalidConfiguration, message: "\(name): не указан адрес сервера")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in preset.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw OpenAICompatibleBackend.transportError(error, providerName: name, url: url)
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw ChatBackendError(kind: .server, message: "\(name): некорректный ответ сервера")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleBackend.httpError(status: http.statusCode, body: result.0.prefix(4096), providerName: name)
        }
        return refine(OpenAIChat.parseModelList(result.0), preset: preset)
    }

    /// Normalises and filters a raw model list: strips Gemini's "models/" prefix, drops non-chat models,
    /// keeps only free models for OpenRouter, puts the preset default first.
    static func refine(_ ids: [String], preset: ChatProviderPreset) -> [String] {
        let nonChatMarkers = ["embed", "whisper", "tts", "imagen", "veo", "moderation", "guard", "aqa", "image-generation"]
        var seen = Set<String>()
        var result: [String] = []
        for raw in ids {
            var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.hasPrefix("models/") { id.removeFirst("models/".count) }
            guard !id.isEmpty else { continue }
            let lower = id.lowercased()
            if nonChatMarkers.contains(where: { lower.contains($0) }) { continue }
            if preset.id == "openrouter", !(lower.hasSuffix(":free") || lower == "openrouter/free") { continue }
            if seen.insert(id).inserted { result.append(id) }
        }
        result.sort { lhs, rhs in
            if lhs == preset.defaultModel { return rhs != preset.defaultModel }
            if rhs == preset.defaultModel { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return result
    }
}

// MARK: - Apple on-device model (FoundationModels, iOS 26+)

/// State of Apple Intelligence's on-device model for a given speech language.
enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    case requiresNewerSystem
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unsupportedLanguage
    case unavailable

    var isAvailable: Bool { self == .available }

    /// Russian explanation for Settings / error messages.
    var message: String {
        switch self {
        case .available:
            return "Модель Apple Intelligence на устройстве: работает без интернета, бесплатно и приватно."
        case .requiresNewerSystem:
            return "Нужна iOS 26 или новее и iPhone с поддержкой Apple Intelligence."
        case .deviceNotEligible:
            return "Это устройство не поддерживает Apple Intelligence."
        case .notEnabled:
            return "Включите Apple Intelligence в Настройках iPhone."
        case .modelNotReady:
            return "Модель Apple Intelligence ещё загружается. Попробуйте позже."
        case .unsupportedLanguage:
            return "Apple Intelligence не поддерживает русский/узбекский язык. Выберите другой сервис или язык English."
        case .unavailable:
            return "Apple Intelligence сейчас недоступна."
        }
    }
}

/// Apple's on-device foundation model. On systems / SDKs without FoundationModels it reports
/// `.requiresNewerSystem` and its stream fails immediately, so the resolver never offers it there.
final class AppleOnDeviceBackend: ChatBackend, Sendable {
    let displayName = "Apple Intelligence (на устройстве)"
    var providerID: String { ChatPresets.appleOnDeviceID }
    /// The on-device context window is 4096 tokens per session — keep the history short.
    var historyCharacterBudget: Int { 2500 }

    init() {}

    /// Availability of the model for the given speech locale (e.g. "ru-RU").
    static func status(localeIdentifier: String) -> AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleFoundationModelRunner.status(localeIdentifier: localeIdentifier)
        }
        #endif
        return .requiresNewerSystem
    }

    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            let conversation = messages.filter { $0.role != .system }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await AppleFoundationModelRunner.run(system: system, conversation: conversation,
                                                                 continuation: continuation)
                        continuation.finish()
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } else {
                            continuation.finish(throwing: AppleFoundationModelRunner.wrap(error))
                        }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        #endif
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ChatBackendError(kind: .unavailable,
                                                           message: AppleIntelligenceStatus.requiresNewerSystem.message))
        }
    }
}

#if canImport(FoundationModels)
/// All FoundationModels calls live here so that the rest of the app compiles with older SDKs.
@available(iOS 26.0, *)
private enum AppleFoundationModelRunner {
    static func status(localeIdentifier: String) -> AppleIntelligenceStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let identifier = localeIdentifier.replacingOccurrences(of: "_", with: "-")
            return model.supportsLocale(Locale(identifier: identifier)) ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .modelNotReady:
                return .modelNotReady
            default:
                return .unavailable
            }
        default:
            return .unavailable
        }
    }

    /// Answers the last user message. The earlier turns go into the session instructions; a fresh session is
    /// created per request, and on `exceededContextWindowSize` a new session with a shorter history is tried.
    static func run(system: String, conversation: [ChatMessage],
                    continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            throw ChatBackendError(kind: .unavailable, message: AppleIntelligenceStatus.unavailable.message)
        }
        guard let last = conversation.last, last.role == .user else {
            throw ChatBackendError(kind: .invalidConfiguration, message: "Нет вопроса для ответа")
        }
        var earlier = Array(conversation.dropLast())
        var emittedAny = false
        while true {
            do {
                try await respond(instructions: instructions(system: system, earlier: earlier),
                                  prompt: last.content, emittedAny: &emittedAny, continuation: continuation)
                return
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, !emittedAny, !earlier.isEmpty {
                    // Start over in a new session with the older half of the history dropped.
                    earlier = Array(earlier.dropFirst(max(2, earlier.count / 2)))
                    continue
                }
                throw error
            }
        }
    }

    private static func respond(instructions: String, prompt: String, emittedAny: inout Bool,
                                continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: prompt)
        var emitted = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            // Each snapshot carries the cumulative text so far — emit only the new part.
            let text: String = snapshot.content
            if text.hasPrefix(emitted) {
                let delta = String(text.dropFirst(emitted.count))
                if !delta.isEmpty {
                    emittedAny = true
                    continuation.yield(delta)
                }
            } else if text.count > emitted.count {
                emittedAny = true
                continuation.yield(String(text.dropFirst(emitted.count)))
            }
            emitted = text
        }
    }

    private static func instructions(system: String, earlier: [ChatMessage]) -> String {
        guard !earlier.isEmpty else { return system }
        let transcript = earlier.map { message -> String in
            let speaker = message.role == .user ? "User" : "Assistant"
            return "\(speaker): \(message.content)"
        }.joined(separator: "\n")
        return system + "\n\nEarlier in this conversation:\n" + transcript
    }

    static func wrap(_ error: Error) -> Error {
        if error is ChatBackendError { return error }
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generationError {
            return ChatBackendError(kind: .server, message: "Apple Intelligence: слишком длинный разговор, очистите чат")
        }
        return ChatBackendError(kind: .server, message: "Apple Intelligence: \(error.localizedDescription)")
    }
}
#endif

// MARK: - Resolver

/// Ordered list of backends to try for the current settings (plus a reason when none is usable).
struct ChatBackendResolution {
    var backends: [any ChatBackend]
    /// Why nothing can be used (nil when `backends` is not empty).
    var problem: String?
}

/// Builds chat backends from `AppSettings` and the Keychain.
enum ChatBackendResolver {
    /// Presets whose server address is configured by the user (`settings.aiCustomBaseURL`).
    static let customBaseURLPresetIDs: Set<String> = ["ollama", "lmstudio", "custom"]

    /// Provider ids offered in Settings, in display order.
    static var selectableProviderIDs: [String] {
        [ChatPresets.autoID, ChatPresets.appleOnDeviceID] + ChatPresets.all.map(\.id)
    }

    /// Picker title for a provider id.
    static func providerTitle(for id: String) -> String {
        switch id {
        case ChatPresets.autoID: return "Авто"
        case ChatPresets.appleOnDeviceID: return "Apple (на устройстве)"
        default: return ChatPresets.preset(id: id)?.name ?? id
        }
    }

    static func usesCustomBaseURL(_ presetID: String) -> Bool {
        customBaseURLPresetIDs.contains(presetID)
    }

    /// Whether Settings should offer an API-key field for the preset (required or optional).
    static func acceptsAPIKey(_ presetID: String) -> Bool {
        guard let preset = ChatPresets.preset(id: presetID) else { return false }
        return preset.requiresAPIKey || presetID == "custom"
    }

    static func apiKeyAccount(for presetID: String) -> String {
        KeychainStore.apiKeyAccount(for: presetID)
    }

    static func apiKey(for presetID: String, keychain: KeychainStore = .shared) -> String? {
        keychain.string(for: apiKeyAccount(for: presetID))
    }

    /// Preset with the user's base URL applied (Ollama / LM Studio / custom server).
    static func effectivePreset(_ preset: ChatProviderPreset, settings: AppSettings) -> ChatProviderPreset {
        let base = settings.aiCustomBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesCustomBaseURL(preset.id), !base.isEmpty {
            return preset.withBaseURL(base)
        }
        return preset
    }

    /// Backends for `settings.aiProviderID`: one specific provider, or the "auto" chain
    /// (keyed providers only with a saved key, Apple only when available for the speech language, Pollinations last).
    static func resolve(settings: AppSettings, keychain: KeychainStore = .shared) -> ChatBackendResolution {
        let id = settings.aiProviderID
        if id == ChatPresets.autoID {
            return resolveAuto(settings: settings, keychain: keychain)
        }
        if id == ChatPresets.appleOnDeviceID {
            let status = AppleOnDeviceBackend.status(localeIdentifier: settings.speechLocaleIdentifier)
            return status.isAvailable
                ? ChatBackendResolution(backends: [AppleOnDeviceBackend()], problem: nil)
                : ChatBackendResolution(backends: [], problem: status.message)
        }
        guard let preset = ChatPresets.preset(id: id) else {
            return ChatBackendResolution(backends: [], problem: "Неизвестный ИИ‑сервис «\(id)». Выберите сервис в настройках.")
        }
        let key = apiKey(for: id, keychain: keychain)
        if preset.requiresAPIKey && key == nil {
            return ChatBackendResolution(
                backends: [],
                problem: "Для «\(chatProviderShortName(preset))» нужен бесплатный ключ API — добавьте его в Настройках → ИИ‑помощник или выберите «Авто».")
        }
        let effective = effectivePreset(preset, settings: settings)
        if effective.chatURL == nil {
            return ChatBackendResolution(backends: [], problem: "Укажите адрес сервера для «\(chatProviderShortName(preset))» в настройках.")
        }
        let model = settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty && effective.defaultModel.isEmpty {
            return ChatBackendResolution(backends: [], problem: "Укажите модель для «\(chatProviderShortName(preset))» в настройках.")
        }
        let backend = OpenAICompatibleBackend(preset: effective, apiKey: key, model: model)
        return ChatBackendResolution(backends: [backend], problem: nil)
    }

    private static func resolveAuto(settings: AppSettings, keychain: KeychainStore) -> ChatBackendResolution {
        var backends: [any ChatBackend] = []
        for id in ChatPresets.autoOrder {
            if id == ChatPresets.appleOnDeviceID {
                if AppleOnDeviceBackend.status(localeIdentifier: settings.speechLocaleIdentifier).isAvailable {
                    backends.append(AppleOnDeviceBackend())
                }
                continue
            }
            guard let preset = ChatPresets.preset(id: id) else { continue }
            let key = apiKey(for: id, keychain: keychain)
            if preset.requiresAPIKey && key == nil { continue }
            // Model ids are provider-specific, so "auto" always uses the preset defaults.
            backends.append(OpenAICompatibleBackend(preset: preset, apiKey: key, model: ""))
        }
        return ChatBackendResolution(backends: backends,
                                     problem: backends.isEmpty ? "Нет доступных ИИ‑сервисов. Проверьте подключение к интернету." : nil)
    }

    /// "Gemini → Apple Intelligence → Pollinations" — the order "auto" would try right now.
    static func autoChainDescription(settings: AppSettings, keychain: KeychainStore = .shared) -> String {
        let names = resolveAuto(settings: settings, keychain: keychain).backends.map { backend -> String in
            if let preset = ChatPresets.preset(id: backend.providerID) { return chatProviderShortName(preset) }
            return "Apple Intelligence"
        }
        return names.isEmpty ? "нет доступных сервисов" : names.joined(separator: " → ")
    }
}

// MARK: - Connection test

/// Result of "Проверить соединение" in Settings.
struct ChatConnectionTestResult: Equatable {
    var success: Bool
    var providerName: String
    /// Seconds until the first text arrived.
    var latencySeconds: Double?
    var reply: String
    /// Russian one-line summary for the UI.
    var summary: String
}

/// Sends a tiny request ("Скажи «готово»") to the configured provider(s).
enum ChatConnectionTester {
    @MainActor
    static func run(settings: AppSettings, timeout: TimeInterval = 30) async -> ChatConnectionTestResult {
        let resolution = ChatBackendResolver.resolve(settings: settings)
        guard !resolution.backends.isEmpty else {
            return ChatConnectionTestResult(success: false, providerName: "", latencySeconds: nil, reply: "",
                                            summary: resolution.problem ?? "ИИ‑сервис не настроен")
        }
        let messages = [
            ChatMessage(role: .system, content: "Ты проверяешь связь. Ответь одним словом, без пояснений."),
            ChatMessage(role: .user, content: "Скажи «готово»"),
        ]
        var failures: [String] = []
        for backend in resolution.backends {
            do {
                let (reply, latency) = try await collect(backend: backend, messages: messages, timeout: timeout)
                let shortReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = shortReply.count > 60 ? String(shortReply.prefix(60)) + "…" : shortReply
                let seconds = RVFormat.decimal(latency, digits: 1)
                var summary = "\(backend.displayName) ответил за \(seconds) с: «\(clipped)»"
                if !failures.isEmpty {
                    summary += "\nНедоступны: " + failures.joined(separator: "; ")
                }
                return ChatConnectionTestResult(success: true, providerName: backend.displayName,
                                                latencySeconds: latency, reply: shortReply, summary: summary)
            } catch {
                failures.append(chatErrorDescription(error))
            }
        }
        return ChatConnectionTestResult(success: false, providerName: resolution.backends.last?.displayName ?? "",
                                        latencySeconds: nil, reply: "", summary: failures.joined(separator: "\n"))
    }

    /// Collects the whole answer; returns the text and the time to the first delta.
    @MainActor
    private static func collect(backend: any ChatBackend, messages: [ChatMessage],
                                timeout: TimeInterval) async throws -> (String, Double) {
        let name = backend.displayName
        let stream = backend.stream(messages: messages)
        let started = Date()
        let collector = Task { () throws -> (String, Double) in
            var text = ""
            var firstDelta: Double?
            for try await delta in stream {
                if firstDelta == nil { firstDelta = Date().timeIntervalSince(started) }
                text += delta
            }
            // A cancelled iteration ends silently — report it as a timeout instead of a partial answer.
            try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatBackendError(kind: .emptyResponse, message: "\(name): пустой ответ")
            }
            return (text, firstDelta ?? Date().timeIntervalSince(started))
        }
        let watchdog = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            collector.cancel()
        }
        defer { watchdog.cancel() }
        do {
            return try await collector.value
        } catch is CancellationError {
            throw ChatBackendError(kind: .timeout, message: "\(name): нет ответа за \(Int(timeout)) с")
        }
    }
}
