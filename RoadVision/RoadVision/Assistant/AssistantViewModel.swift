import Foundation
import Observation

/// State and logic of the AI voice assistant: conversation, streaming replies from the configured chat backend(s),
/// push-to-talk speech input and sentence-by-sentence spoken output.
@Observable
@MainActor
final class AssistantViewModel {
    /// Supplies the current trip facts for the system prompt (set by `AppState`).
    @ObservationIgnored var contextProvider: (@MainActor () -> DrivingContext)?

    /// Visible conversation (no system messages). The assistant reply being streamed is the last element.
    private(set) var messages: [ChatMessage] = []
    /// A request is in flight.
    private(set) var isThinking = false
    /// Name of the backend that produced the latest reply, or the configured provider before the first reply.
    private(set) var activeProviderName: String
    /// Text typed in the input field.
    var draft = ""

    /// Speech input (exposed for permission state and notices in the UI).
    let recognizer: SpeechRecognizerService

    /// The microphone is open.
    var isListening: Bool { recognizer.isListening }
    /// Permissions are being requested / the microphone is starting.
    var isStartingListening: Bool { recognizer.isStarting }
    /// Live partial transcript while listening.
    var partialTranscript: String { recognizer.transcript }
    /// Russian error for the UI (chat errors first, then speech-input errors).
    var errorMessage: String? { chatErrorMessage ?? recognizer.errorMessage }
    /// E.g. "iOS пока не распознаёт узбекскую речь…" when recognition falls back to Russian.
    var recognitionNotice: String? { recognizer.fallbackNotice }
    /// Microphone / speech permission was denied (the UI offers a button to iOS Settings).
    var speechPermissionDenied: Bool { recognizer.authorizationDenied }
    /// Text-to-speech is talking (assistant reply or a navigation prompt).
    var isSpeaking: Bool { speech.isSpeaking }

    private var chatErrorMessage: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    /// Incremented for every new request / cancellation; a stream only writes while its generation is current.
    @ObservationIgnored private var responseGeneration = 0
    @ObservationIgnored private var streamingPlaceholderID: UUID?
    @ObservationIgnored private var streamingText = ""
    @ObservationIgnored private var speakCurrentReply = true
    @ObservationIgnored private var pendingSpeech = ""

    /// Minimum interval between UI updates of the streamed reply (≈ 10 Hz).
    private let uiUpdateInterval: TimeInterval = 0.1

    init(settings: AppSettings, speech: SpeechService) {
        self.settings = settings
        self.speech = speech
        self.recognizer = SpeechRecognizerService(speech: speech)
        self.activeProviderName = ChatBackendResolver.providerTitle(for: settings.aiProviderID)
    }

    // MARK: Input

    /// Mic button: starts push-to-talk (stopping any spoken reply and the request in flight) or stops listening.
    /// The final transcript is sent automatically.
    func toggleListening() {
        if recognizer.isListening || recognizer.isStarting {
            recognizer.stop()
            return
        }
        cancelResponse()
        stopSpeaking()
        chatErrorMessage = nil
        recognizer.clearError()
        let locale = settings.speechLocaleIdentifier
        Task { [weak self] in
            guard let self else { return }
            await self.recognizer.start(localeIdentifier: locale) { [weak self] text in
                guard let self else { return }
                Task { await self.send(text) }
            }
        }
    }

    /// Sends the typed text.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await send(text) }
    }

    /// Appends the user message and streams the reply. A request still in flight is cancelled first.
    /// Returns when the reply is complete, failed or was cancelled.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if recognizer.isListening { recognizer.cancel() }
        cancelResponse()
        stopSpeaking()
        chatErrorMessage = nil
        recognizer.clearError()
        messages.append(ChatMessage(role: .user, content: trimmed))

        let resolution = ChatBackendResolver.resolve(settings: settings)
        guard !resolution.backends.isEmpty else {
            chatErrorMessage = resolution.problem ?? "ИИ‑сервис не настроен. Откройте Настройки → ИИ‑помощник."
            return
        }

        let conversation = messages.filter { !$0.content.isEmpty }
        let placeholder = ChatMessage(role: .assistant, content: "")
        messages.append(placeholder)
        isThinking = true
        responseGeneration += 1
        let generation = responseGeneration
        streamingPlaceholderID = placeholder.id
        streamingText = ""
        pendingSpeech = ""
        speakCurrentReply = settings.speakAssistantReplies

        let backends = resolution.backends
        let task = Task { [weak self] in
            guard let self else { return }
            await self.streamReply(placeholderID: placeholder.id, conversation: conversation,
                                   backends: backends, generation: generation)
        }
        responseTask = task
        await task.value
    }

    // MARK: Control

    /// Stops the spoken reply (the text keeps streaming silently).
    func stopSpeaking() {
        speakCurrentReply = false
        pendingSpeech = ""
        speech.stop()
    }

    /// Cancels the request in flight; a partially received reply is kept and marked with "…".
    func cancelResponse() {
        guard responseTask != nil || streamingPlaceholderID != nil else { return }
        responseTask?.cancel()
        responseTask = nil
        responseGeneration += 1
        if let id = streamingPlaceholderID, let index = messages.firstIndex(where: { $0.id == id }) {
            let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                messages.remove(at: index)
            } else {
                messages[index].content = partial + " …"
            }
        }
        streamingPlaceholderID = nil
        streamingText = ""
        pendingSpeech = ""
        isThinking = false
    }

    /// Clears the chat, stops speech and listening.
    func clearConversation() {
        cancelResponse()
        recognizer.cancel()
        stopSpeaking()
        messages.removeAll()
        draft = ""
        chatErrorMessage = nil
        recognizer.clearError()
        refreshProviderName()
    }

    /// Hides the current error.
    func dismissError() {
        chatErrorMessage = nil
        recognizer.clearError()
    }

    /// Shows the configured provider in the header (call when the sheet appears; keeps the last reply's name otherwise).
    func refreshProviderName() {
        guard !isThinking else { return }
        let configured = ChatBackendResolver.providerTitle(for: settings.aiProviderID)
        if messages.isEmpty {
            activeProviderName = configured
        } else if settings.aiProviderID != ChatPresets.autoID,
                  !activeProviderName.hasPrefix(chatProviderShortNameForID(settings.aiProviderID)) {
            // The provider was changed in Settings since the last reply.
            activeProviderName = configured
        }
    }

    // MARK: Streaming

    private func streamReply(placeholderID: UUID, conversation: [ChatMessage],
                             backends: [any ChatBackend], generation: Int) async {
        var failures: [String] = []
        for backend in backends {
            guard isCurrent(generation) else { return }
            let history = ChatHistory.trimmed(conversation, maxCharacters: backend.historyCharacterBudget)
            let includeContext = settings.assistantIncludeDrivingContext
            let context = includeContext ? contextProvider?() : nil
            let systemPrompt = AssistantPrompt.systemPrompt(languageCode: settings.languageCode,
                                                            context: context, includeContext: includeContext)
            let request = [ChatMessage(role: .system, content: systemPrompt)] + history

            var receivedAny = false
            var lastUIUpdate: TimeInterval = 0
            do {
                for try await delta in backend.stream(messages: request) {
                    guard isCurrent(generation) else { return }
                    if !receivedAny {
                        receivedAny = true
                        activeProviderName = backend.displayName
                    }
                    streamingText += delta
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastUIUpdate >= uiUpdateInterval {
                        lastUIUpdate = now
                        setContent(streamingText, for: placeholderID)
                    }
                    enqueueSpeech(delta)
                }
                guard isCurrent(generation) else { return }
                if receivedAny {
                    setContent(streamingText.trimmingCharacters(in: .whitespacesAndNewlines), for: placeholderID)
                    flushSpeech()
                    finishResponse()
                    return
                }
                failures.append("\(backend.displayName): пустой ответ")
            } catch {
                guard isCurrent(generation) else { return }
                // A cancellation we did not ask for (e.g. the system dropped the connection) counts as a failure.
                let message = error is CancellationError
                    ? "\(backend.displayName): запрос прерван"
                    : chatErrorDescription(error)
                if receivedAny {
                    // Keep what already arrived; do not switch providers in the middle of an answer.
                    let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    setContent(partial + " …", for: placeholderID)
                    flushSpeech()
                    chatErrorMessage = "Ответ прервался: \(message)"
                    finishResponse()
                    return
                }
                failures.append(message)
            }
        }
        guard isCurrent(generation) else { return }
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages.remove(at: index)
        }
        chatErrorMessage = failures.isEmpty ? "ИИ‑сервис не ответил" : failures.joined(separator: "\n")
        finishResponse()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == responseGeneration && !Task.isCancelled
    }

    private func setContent(_ text: String, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[index].content != text {
            messages[index].content = text
        }
    }

    private func finishResponse() {
        isThinking = false
        responseTask = nil
        streamingPlaceholderID = nil
        streamingText = ""
    }

    // MARK: Spoken output

    /// Speaks complete sentences as soon as they have arrived.
    private func enqueueSpeech(_ delta: String) {
        guard speakCurrentReply else { return }
        pendingSpeech += delta
        for sentence in AssistantSentenceSplitter.extractSentences(from: &pendingSpeech) {
            speakChunk(sentence)
        }
    }

    /// Speaks the rest of the reply once the stream has finished.
    private func flushSpeech() {
        defer { pendingSpeech = "" }
        guard speakCurrentReply else { return }
        speakChunk(pendingSpeech)
    }

    private func speakChunk(_ text: String) {
        let clean = AssistantSentenceSplitter.speakable(text)
        guard !clean.isEmpty else { return }
        speech.speak(clean, priority: .normal, language: settings.speechLocaleIdentifier)
    }

    private func chatProviderShortNameForID(_ id: String) -> String {
        if id == ChatPresets.appleOnDeviceID { return "Apple" }
        guard let preset = ChatPresets.preset(id: id) else { return id }
        return chatProviderShortName(preset)
    }
}

/// Splits a streamed reply into complete sentences for text-to-speech.
enum AssistantSentenceSplitter {
    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "»", "”", "’", ")", "]"]

    /// Removes complete sentences from the start of `buffer` and returns them (trimmed, non-empty).
    /// A sentence ends at a newline, or at `. ! ? …` (plus closing quotes/brackets) followed by whitespace —
    /// so "3.5" or a terminator at the very end of the buffer waits for more text.
    static func extractSentences(from buffer: inout String) -> [String] {
        var sentences: [String] = []
        var sentenceStart = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if character.isNewline {
                append(buffer[sentenceStart..<index], to: &sentences)
                index = buffer.index(after: index)
                sentenceStart = index
                continue
            }
            if terminators.contains(character) {
                var end = buffer.index(after: index)
                while end < buffer.endIndex, terminators.contains(buffer[end]) || closers.contains(buffer[end]) {
                    end = buffer.index(after: end)
                }
                guard end < buffer.endIndex else { break }
                if buffer[end].isWhitespace {
                    append(buffer[sentenceStart..<end], to: &sentences)
                    sentenceStart = end
                }
                index = end
                continue
            }
            index = buffer.index(after: index)
        }
        buffer = String(buffer[sentenceStart...])
        return sentences
    }

    /// Removes markdown decoration and links that would be read aloud literally.
    static func speakable(_ text: String) -> String {
        var result = text
        for token in ["**", "__", "`", "#", "*"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        let words = result.split(separator: " ", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
        result = words.joined(separator: " ")
        var trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading list marker ("- ", "• ").
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
            trimmed.removeFirst(2)
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ piece: Substring, to sentences: inout [String]) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sentences.append(trimmed)
        }
    }
}
