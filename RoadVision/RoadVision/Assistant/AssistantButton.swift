import SwiftUI

/// Floating round button that opens the AI assistant sheet (`app.showAssistant = true`).
/// Shows a microphone and a pulsing ring while the assistant listens, and pulses while it is thinking.
struct AssistantButton: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat

    /// - Parameter size: diameter in points (≥ 52 for use while driving).
    init(size: CGFloat = 60) {
        self.size = max(52, size)
    }

    var body: some View {
        let assistant = app.assistant
        let listening = assistant.isListening
        let busy = listening || assistant.isThinking
        Button {
            app.showAssistant = true
        } label: {
            ZStack {
                if busy && !reduceMotion {
                    AssistantPulseRing(color: listening ? .red : .cyan)
                }
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                Image(systemName: listening ? "mic.fill" : "sparkles")
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(listening ? Color.red : Color.white)
                    .symbolEffect(.pulse, isActive: busy && !reduceMotion)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ИИ‑помощник")
        .accessibilityValue(accessibilityState(listening: listening, thinking: assistant.isThinking))
        .accessibilityHint("Открывает голосового помощника")
    }

    private func accessibilityState(listening: Bool, thinking: Bool) -> String {
        if listening { return "слушает" }
        if thinking { return "отвечает" }
        return ""
    }
}

/// Expanding, fading ring used to show that the microphone is open or a reply is being generated.
struct AssistantPulseRing: View {
    var color: Color
    var lineWidth: CGFloat

    @State private var expanded = false

    init(color: Color, lineWidth: CGFloat = 3) {
        self.color = color
        self.lineWidth = lineWidth
    }

    var body: some View {
        Circle()
            .stroke(color.opacity(0.75), lineWidth: lineWidth)
            .scaleEffect(expanded ? 1.5 : 1.0)
            .opacity(expanded ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
