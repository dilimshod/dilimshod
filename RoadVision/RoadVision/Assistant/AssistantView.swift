import SwiftUI
import UIKit

/// Chat sheet of the AI assistant: header with the active provider, message bubbles with auto-scroll,
/// live transcript while listening, suggestion chips, and a bottom bar with a large microphone button.
struct AssistantView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var inputFocused: Bool

    /// Questions offered in the empty state.
    static let suggestions = [
        "Сколько ещё ехать?",
        "Какая сейчас погода?",
        "Сколько полос на этой дороге?",
        "Расскажи что-нибудь интересное",
        "Сколько машин ты насчитал?",
    ]

    private let bottomAnchorID = "assistant.bottom"

    var body: some View {
        @Bindable var assistant = app.assistant
        VStack(spacing: 0) {
            header(assistant)
            Divider().overlay(Color.white.opacity(0.08))
            messageList(assistant)
            if let error = assistant.errorMessage {
                errorBanner(error, assistant: assistant)
            }
            if let notice = assistant.recognitionNotice, assistant.isListening || assistant.messages.isEmpty {
                noticeBanner(notice)
            }
            inputBar(assistant, draft: $assistant.draft)
            Text("Не отвлекайтесь от дороги — пользуйтесь голосом")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            assistant.refreshProviderName()
        }
    }

    // MARK: Header

    private func header(_ assistant: AssistantViewModel) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.18))
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("ИИ‑помощник")
                    .font(.system(.headline, design: .rounded))
                Text(assistant.activeProviderName)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Настройки помощника")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Закрыть")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Messages

    private func messageList(_ assistant: AssistantViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if assistant.messages.isEmpty && !assistant.isListening {
                        emptyState(assistant)
                    }
                    ForEach(assistant.messages) { message in
                        AssistantMessageBubble(message: message,
                                               isPending: assistant.isThinking && message.content.isEmpty)
                            .id(message.id)
                    }
                    if assistant.isListening || assistant.isStartingListening {
                        AssistantTranscriptBubble(text: assistant.partialTranscript,
                                                  isStarting: assistant.isStartingListening)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: assistant.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: assistant.messages.last?.content) { _, _ in
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: assistant.partialTranscript) { _, _ in
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: assistant.isListening) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private func emptyState(_ assistant: AssistantViewModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Спросите что угодно")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("Нажмите микрофон и говорите — ответ прозвучит голосом. Помощник знает скорость, дорогу, маршрут и погоду.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            AssistantChipFlowLayout(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await assistant.send(suggestion) }
                    } label: {
                        Text(suggestion)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Banners

    private func errorBanner(_ error: String, assistant: AssistantViewModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 8) {
                Text(error)
                    .font(.system(.footnote, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                if assistant.speechPermissionDenied {
                    Button("Открыть настройки iOS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                }
            }
            Spacer(minLength: 4)
            Button {
                assistant.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скрыть ошибку")
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func noticeBanner(_ notice: String) -> some View {
        Label {
            Text(notice)
                .font(.system(.caption, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Input bar

    private func inputBar(_ assistant: AssistantViewModel, draft: Binding<String>) -> some View {
        let canSend = !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 10) {
            VStack(spacing: 8) {
                if assistant.isSpeaking {
                    roundButton(systemName: "speaker.slash.fill", label: "Замолчать", tint: .orange) {
                        assistant.stopSpeaking()
                    }
                }
                roundButton(systemName: "trash", label: "Очистить чат", tint: .white) {
                    assistant.clearConversation()
                }
                .disabled(assistant.messages.isEmpty && assistant.errorMessage == nil)
                .opacity(assistant.messages.isEmpty && assistant.errorMessage == nil ? 0.4 : 1)
            }

            HStack(spacing: 6) {
                TextField("Напишите сообщение…", text: draft)
                    .font(.system(.body, design: .rounded))
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        assistant.sendDraft()
                    }
                    .padding(.leading, 16)
                Button {
                    assistant.sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend ? Color.cyan : Color.gray.opacity(0.5))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Отправить")
            }
            .frame(minHeight: 52)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

            micButton(assistant)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func micButton(_ assistant: AssistantViewModel) -> some View {
        let listening = assistant.isListening
        let starting = assistant.isStartingListening
        return Button {
            inputFocused = false
            assistant.toggleListening()
        } label: {
            ZStack {
                if listening {
                    AssistantPulseRing(color: .red, lineWidth: 4)
                }
                Circle()
                    .fill(listening ? Color.red : Color.cyan)
                if starting {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(listening ? Color.white : Color.black)
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Остановить запись" : "Говорить")
        .accessibilityHint("Голосовой вопрос помощнику")
    }

    private func roundButton(systemName: String, label: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    /// Closes the assistant and opens Settings (two sheets cannot be shown at once).
    private func openSettings() {
        let state = app
        state.showAssistant = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            state.showSettings = true
        }
    }
}

// MARK: - Bubbles

/// One chat message.
private struct AssistantMessageBubble: View {
    let message: ChatMessage
    /// The reply is requested but no text arrived yet.
    let isPending: Bool

    private var spokenLabel: String {
        let speaker = message.role == .user ? "Вы" : "Помощник"
        return isPending ? "\(speaker): думает" : "\(speaker): \(message.content)"
    }

    var body: some View {
        let isUser = message.role == .user
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            Group {
                if isPending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Думаю…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(.body, design: .rounded))
            .foregroundStyle(isUser ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Color.cyan : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }
}

/// The live (partial) transcript while the microphone is open.
private struct AssistantTranscriptBubble: View {
    let text: String
    let isStarting: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .symbolEffect(.pulse)
                    .foregroundStyle(.red)
                Text(text.isEmpty ? (isStarting ? "Включаю микрофон…" : "Слушаю…") : text)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.isEmpty ? String("Слушаю") : String("Распознано: \(text)"))
    }
}

// MARK: - Chip layout

/// Wrapping horizontal layout for suggestion chips.
struct AssistantChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = proposal.width.map { $0.isFinite ? $0 : contentWidth } ?? contentWidth
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
            let itemWidth = maxWidth.isFinite ? min(size.width, maxWidth) : size.width
            let neededWidth = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if !current.indices.isEmpty && neededWidth > maxWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = itemWidth
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = neededWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
