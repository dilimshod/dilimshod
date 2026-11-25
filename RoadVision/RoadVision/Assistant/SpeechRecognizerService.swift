import AVFoundation
import Foundation
import Observation
import Speech

/// Push-to-talk speech recognition for the assistant: `SFSpeechRecognizer` fed by an `AVAudioEngine` microphone tap.
///
/// - Partial results are published in `transcript` while the user speaks.
/// - Listening finishes automatically 1.8 s after the last new partial text, and hard-stops at 55 s
///   (Apple limits a recognition task to about one minute of audio).
/// - Uzbek (uz-UZ) is not supported by iOS dictation: recognition falls back to Russian and `fallbackNotice` explains it.
/// - The audio session is switched with `SpeechService.prepareForRecording()` / `finishRecording()`; the microphone
///   (engine, tap, request) is always shut down before the final text is delivered, so replies can be spoken.
@Observable
@MainActor
final class SpeechRecognizerService {
    /// True while the microphone is open.
    private(set) var isListening = false
    /// True while permissions are being requested / the session is being set up.
    private(set) var isStarting = false
    /// Partial (then final) transcript of the current utterance.
    private(set) var transcript = ""
    /// Speech recognition or microphone access was denied in iOS Settings.
    private(set) var authorizationDenied = false
    /// Russian error for the UI; nil when everything is fine.
    private(set) var errorMessage: String?
    /// Info shown when another recognition language is used than requested (e.g. uz-UZ → ru-RU).
    private(set) var fallbackNotice: String?
    /// Locale really used by the recognizer.
    private(set) var activeLocaleIdentifier: String?
    /// Whether the current/last session runs fully on the device (no audio leaves the phone).
    private(set) var isOnDevice = false

    private enum Phase { case idle, listening, finalizing }

    private enum Failure: Error {
        case unsupportedLocale
        case recognizerUnavailable
        case microphoneUnavailable

        var message: String {
            switch self {
            case .unsupportedLocale:
                return "Распознавание речи для этого языка недоступно на устройстве."
            case .recognizerUnavailable:
                return "Распознавание речи сейчас недоступно. Проверьте подключение к интернету или попробуйте позже."
            case .microphoneUnavailable:
                return "Микрофон недоступен: возможно, идёт звонок или его использует другое приложение."
            }
        }
    }

    private enum Authorization { case authorized, speechDenied, speechRestricted, microphoneDenied }

    /// Details of a recognition error, extracted off the main actor.
    private struct RecognitionFailure: Sendable {
        let domain: String
        let code: Int
        let description: String

        init(_ error: Error) {
            let nsError = error as NSError
            domain = nsError.domain
            code = nsError.code
            description = nsError.localizedDescription
        }

        /// "No speech detected" style errors of the recognizer.
        var isNoSpeech: Bool {
            domain == "kAFAssistantErrorDomain" && (code == 1110 || code == 203 || code == 1101)
        }
    }

    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var sessionID = 0
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinal: (@MainActor (String) -> Void)?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var recordingSessionPrepared = false
    @ObservationIgnored private var startCancelled = false
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var finalWaitTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Seconds without new partial text after which listening stops (once something was recognised).
    let silenceTimeout: TimeInterval = 1.8
    /// Seconds after which listening is abandoned if nothing at all was recognised.
    let noSpeechTimeout: TimeInterval = 8
    /// Hard limit of one listening session (Apple: ≈ 1 minute of audio per task).
    let maxDuration: TimeInterval = 55
    /// How long to wait for the recognizer's final result after the microphone was closed.
    let finalResultWait: TimeInterval = 1.2

    init(speech: SpeechService) {
        self.speech = speech
    }

    // MARK: Public API

    /// Requests permissions if needed and opens the microphone. `onFinal` receives the final, non-empty transcript
    /// (after the microphone has been shut down). Does nothing while a session is already running.
    func start(localeIdentifier: String, onFinal: @escaping @MainActor (String) -> Void) async {
        if phase == .finalizing {
            completeFinalization(deliver: true)
        }
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        startCancelled = false
        errorMessage = nil
        fallbackNotice = nil
        transcript = ""

        let authorization = await Self.ensureAuthorization()
        isStarting = false
        guard !startCancelled else { return }
        switch authorization {
        case .authorized:
            authorizationDenied = false
        case .speechDenied:
            authorizationDenied = true
            errorMessage = "Нет доступа к распознаванию речи. Разрешите его: Настройки iOS → RoadVision → Распознавание речи."
            return
        case .speechRestricted:
            authorizationDenied = true
            errorMessage = "Распознавание речи ограничено на этом устройстве (Экранное время или профиль)."
            return
        case .microphoneDenied:
            authorizationDenied = true
            errorMessage = "Нет доступа к микрофону. Разрешите его: Настройки iOS → RoadVision → Микрофон."
            return
        }

        do {
            try beginSession(localeIdentifier: localeIdentifier, onFinal: onFinal)
        } catch {
            teardownAudio()
            recognitionTask?.cancel()
            recognitionTask = nil
            request = nil
            recognizer = nil
            phase = .idle
            isListening = false
            errorMessage = Self.message(for: error)
        }
    }

    /// Stops listening and delivers what was recognised (after waiting briefly for the final result).
    func stop() {
        if isStarting {
            startCancelled = true
            isStarting = false
            return
        }
        endListening(deliver: true, awaitFinal: true)
    }

    /// Stops listening and discards the transcript.
    func cancel() {
        if isStarting {
            startCancelled = true
            isStarting = false
        }
        switch phase {
        case .idle:
            break
        case .listening:
            endListening(deliver: false, awaitFinal: false)
        case .finalizing:
            completeFinalization(deliver: false)
        }
    }

    /// Clears the error (and the permission flag) shown in the UI.
    func clearError() {
        errorMessage = nil
    }

    // MARK: Session

    private func beginSession(localeIdentifier: String, onFinal: @escaping @MainActor (String) -> Void) throws {
        let (recognizer, usedLocale, notice) = try Self.makeRecognizer(for: localeIdentifier)
        guard recognizer.isAvailable else { throw Failure.recognizerUnavailable }

        // Switches the audio session to play-and-record (throws e.g. during a phone call).
        try speech.prepareForRecording()
        recordingSessionPrepared = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice {
            request.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A zero sample rate / channel count means the input is unavailable (installTap would raise an exception).
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.microphoneUnavailable }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(for: request))
        tapInstalled = true
        engine.prepare()
        try engine.start()

        sessionID += 1
        let session = sessionID
        self.recognizer = recognizer
        self.request = request
        self.onFinal = onFinal
        recognitionTask = recognizer.recognitionTask(with: request,
                                                     resultHandler: Self.makeResultHandler(owner: self, session: session))
        phase = .listening
        isListening = true
        activeLocaleIdentifier = usedLocale
        fallbackNotice = notice
        isOnDevice = onDevice
        addObservers(engine: engine, session: session)
        scheduleSilenceTimer(session: session, delay: noSpeechTimeout)
        scheduleLimitTimer(session: session)
    }

    /// Closes the microphone. With `deliver`, the transcript goes to `onFinal` — after the final result
    /// arrives or `finalResultWait` elapses when `awaitFinal` is set.
    private func endListening(deliver: Bool, awaitFinal: Bool) {
        guard phase == .listening else { return }
        silenceTask?.cancel()
        silenceTask = nil
        limitTask?.cancel()
        limitTask = nil
        teardownAudio()
        isListening = false
        phase = .finalizing

        let hasText = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard deliver, hasText else {
            completeFinalization(deliver: false)
            return
        }
        guard awaitFinal else {
            completeFinalization(deliver: true)
            return
        }
        let session = sessionID
        let wait = UInt64(finalResultWait * 1_000_000_000)
        finalWaitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: wait)
            } catch {
                return
            }
            guard let self, self.sessionID == session, self.phase == .finalizing else { return }
            self.completeFinalization(deliver: true)
        }
    }

    /// Releases the recognition task and hands the transcript to the caller.
    private func completeFinalization(deliver: Bool) {
        finalWaitTask?.cancel()
        finalWaitTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        phase = .idle
        let callback = onFinal
        onFinal = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        if deliver, !text.isEmpty {
            callback?(text)
        }
    }

    /// Stops the engine, removes the tap, ends the audio of the request and restores the playback audio session.
    private func teardownAudio() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        tapInstalled = false
        audioEngine = nil
        request?.endAudio()
        removeObservers()
        if recordingSessionPrepared {
            recordingSessionPrepared = false
            speech.finishRecording()
        }
    }

    // MARK: Recognition callbacks

    private func handleRecognition(session: Int, text: String?, isFinal: Bool, failure: RecognitionFailure?) {
        guard session == sessionID else { return }
        switch phase {
        case .idle:
            return
        case .listening:
            if let text, !text.isEmpty, text != transcript {
                transcript = text
                scheduleSilenceTimer(session: session, delay: silenceTimeout)
            }
            if isFinal {
                endListening(deliver: true, awaitFinal: false)
            } else if let failure {
                let hasText = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                endListening(deliver: hasText, awaitFinal: false)
                if !hasText {
                    errorMessage = failure.isNoSpeech
                        ? "Не расслышал. Нажмите микрофон и повторите."
                        : "Ошибка распознавания речи: \(failure.description)"
                }
            }
        case .finalizing:
            if let text, !text.isEmpty {
                transcript = text
            }
            if isFinal || failure != nil {
                completeFinalization(deliver: true)
            }
        }
    }

    private func scheduleSilenceTimer(session: Int, delay: TimeInterval) {
        silenceTask?.cancel()
        let nanoseconds = UInt64(delay * 1_000_000_000)
        silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, self.sessionID == session, self.phase == .listening else { return }
            if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.endListening(deliver: false, awaitFinal: false)
                self.errorMessage = "Не расслышал. Нажмите микрофон и повторите."
            } else {
                self.endListening(deliver: true, awaitFinal: true)
            }
        }
    }

    private func scheduleLimitTimer(session: Int) {
        limitTask?.cancel()
        let nanoseconds = UInt64(maxDuration * 1_000_000_000)
        limitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, self.sessionID == session, self.phase == .listening else { return }
            self.endListening(deliver: true, awaitFinal: true)
        }
    }

    // MARK: Audio interruptions

    private func addObservers(engine: AVAudioEngine, session: Int) {
        removeObservers()
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                              object: AVAudioSession.sharedInstance(),
                                              queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let owner = self else { return }
            Task { @MainActor in
                owner.handleInterruption(rawType: rawType, session: session)
            }
        }
        let configuration = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            guard let owner = self else { return }
            Task { @MainActor in
                owner.handleEngineConfigurationChange(session: session)
            }
        }
        observers = [interruption, configuration]
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// A phone call, Siri or an alarm took the audio session.
    private func handleInterruption(rawType: UInt?, session: Int) {
        guard session == sessionID, phase == .listening,
              let rawType, AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
        endListening(deliver: false, awaitFinal: false)
        errorMessage = "Запись прервана звонком или другим приложением. Нажмите микрофон ещё раз."
    }

    /// The audio route changed (e.g. headphones or CarPlay connected) — the engine stopped by itself.
    private func handleEngineConfigurationChange(session: Int) {
        guard session == sessionID, phase == .listening else { return }
        let hasText = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        endListening(deliver: hasText, awaitFinal: hasText)
        if !hasText {
            errorMessage = "Аудиоустройство изменилось. Нажмите микрофон ещё раз."
        }
    }

    // MARK: Helpers (nonisolated: their closures run on audio / recognition threads)

    /// Asks for speech-recognition and microphone permission when they were not decided yet.
    nonisolated private static func ensureAuthorization() async -> Authorization {
        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        switch speechStatus {
        case .authorized:
            break
        case .restricted:
            return .speechRestricted
        default:
            return .speechDenied
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .authorized
        case .denied:
            return .microphoneDenied
        default:
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted ? .authorized : .microphoneDenied
        }
    }

    /// Tap block that feeds microphone buffers into the request (called on a real-time audio thread).
    nonisolated private static func makeTapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            request.append(buffer)
        }
    }

    /// Result handler that copies the values it needs and hops to the main actor.
    nonisolated private static func makeResultHandler(owner: SpeechRecognizerService,
                                                      session: Int) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { RecognitionFailure($0) }
            guard let target = owner else { return }
            Task { @MainActor in
                target.handleRecognition(session: session, text: text, isFinal: isFinal, failure: failure)
            }
        }
    }

    /// Recognizer for the requested locale, or Russian with an explanatory notice when it is not supported (uz-UZ).
    private static func makeRecognizer(for identifier: String) throws -> (SFSpeechRecognizer, String, String?) {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: normalized)) {
            return (recognizer, normalized, nil)
        }
        let languageCode = String(normalized.prefix(while: { $0 != "-" })).lowercased()
        let notice: String
        if languageCode == "uz" {
            notice = "iOS пока не распознаёт узбекскую речь — говорите по-русски или напишите вопрос по-узбекски текстом. Ответ будет на узбекском."
        } else {
            notice = "Распознавание для языка \(normalized) недоступно — используется русский."
        }
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")) {
            return (recognizer, "ru-RU", notice)
        }
        throw Failure.unsupportedLocale
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        let nsError = error as NSError
        return "Не удалось включить микрофон: возможно, идёт звонок или микрофон занят другим приложением (код \(nsError.code))."
    }
}
