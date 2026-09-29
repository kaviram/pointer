import AppKit
import SwiftUI

enum Phase: Equatable {
    case idle
    case confirming
    case analyzing
    case result
    case failed
}

enum PopoverTab: String, CaseIterable, Identifiable {
    case result = "Result"
    case history = "History"

    var id: String { rawValue }
}

/// Owns the `idle → confirming → analyzing → result` state machine and the
/// text streaming into the popover. Nothing is sent to a provider until
/// `analyze()` is called from the confirm step.
@MainActor
final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var tab: PopoverTab = .result

    @Published var capture: Capture?
    @Published var selectedPromptId: String
    @Published var responseText: String = ""
    @Published var isThinking: Bool = false
    @Published var errorMessage: String?
    @Published var elapsed: TimeInterval = 0

    let settings: SettingsStore
    let history: HistoryStore

    private var streamTask: Task<Void, Never>?
    private var startedAt: Date?
    private var timer: Timer?

    /// Set by the app delegate so state transitions can show and hide the
    /// popover and re-arm the hotkey.
    var onPresent: (() -> Void)?
    var onDismiss: (() -> Void)?

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
        selectedPromptId = settings.settings.activePromptId
    }

    var activePromptName: String {
        settings.settings.prompt(id: selectedPromptId)?.name ?? "Prompt"
    }

    // MARK: - Transitions

    func present(capture: Capture) {
        // A new capture supersedes whatever is on screen, including an analysis
        // still streaming — otherwise its remaining deltas would append into
        // the new snippet's response text.
        streamTask?.cancel()
        streamTask = nil
        stopTimer()

        self.capture = capture
        responseText = ""
        errorMessage = nil
        isThinking = false
        elapsed = 0
        selectedPromptId = settings.settings.activePromptId
        tab = .result
        phase = .confirming
        onPresent?()
    }

    func analyze() {
        guard let capture else { return }
        let config = settings.settings
        guard let prompt = config.prompt(id: selectedPromptId) ?? config.prompts.first else { return }

        // Re-run and Retry both land here, so an in-flight stream has to be
        // cancelled first — otherwise two streams append into responseText and
        // the answers interleave.
        streamTask?.cancel()
        streamTask = nil

        responseText = ""
        errorMessage = nil
        isThinking = false
        phase = .analyzing
        startTimer()

        let provider = Providers.provider(for: config)
        streamTask = Task { [weak self] in
            do {
                for try await event in provider.stream(
                    prompt: prompt.template,
                    imagePNG: capture.pngData,
                    settings: config
                ) {
                    guard let self else { return }
                    switch event {
                    case .thinkingStarted:
                        self.isThinking = true
                    case .textDelta(let text):
                        self.isThinking = false
                        self.responseText += text
                    }
                }
                guard let self else { return }
                self.finishSuccessfully(prompt: prompt, config: config, capture: capture)
            } catch {
                guard let self else { return }
                if error is CancellationError { return }
                self.fail(with: error)
            }
        }
    }

    private func finishSuccessfully(prompt: PromptTemplate, config: Settings, capture: Capture) {
        stopTimer()
        isThinking = false

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // A stream that closes without text is a failure, not a result —
            // most often max_tokens consumed entirely by thinking.
            errorMessage = """
                The model returned no text. If thinking is enabled, max_tokens \
                covers thinking plus the response — try raising max_tokens or \
                lowering effort in Settings.
                """
            phase = .failed
            return
        }

        responseText = trimmed
        phase = .result
        history.add(
            pngData: capture.pngData,
            promptName: prompt.name,
            promptTemplate: prompt.template,
            provider: config.provider,
            model: config.activeModel,
            response: trimmed,
            limit: config.historyLimit
        )
    }

    private func fail(with error: Error) {
        stopTimer()
        isThinking = false
        errorMessage = error.localizedDescription
        phase = .failed
    }

    func retry() {
        analyze()
    }

    func rerun(promptId: String) {
        selectedPromptId = promptId
        analyze()
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        stopTimer()
        capture = nil
        responseText = ""
        errorMessage = nil
        isThinking = false
        phase = .idle
        onDismiss?()
    }

    func copyResponse() {
        guard !responseText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(responseText, forType: .string)
    }

    // MARK: - Elapsed timer

    private func startTimer() {
        startedAt = Date()
        elapsed = 0
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Renders bold and inline code without pulling in a Markdown dependency.
/// `inlineOnlyPreservingWhitespace` keeps the model's line breaks intact —
/// the default parsing collapses them.
func renderMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
    )) ?? AttributedString(text)
}
