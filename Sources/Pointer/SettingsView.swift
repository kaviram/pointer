import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            ProviderSettings(settings: settings)
                .tabItem { Text("Provider") }
            PromptSettings(settings: settings)
                .tabItem { Text("Prompts") }
            BehaviorSettings(settings: settings)
                .tabItem { Text("Behavior") }
        }
        .padding(16)
        .frame(width: 560, height: 620)
    }
}

// MARK: - Provider

struct ProviderSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var keyInput: String = ""
    @State private var status: String?

    private var provider: Provider { settings.settings.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Provider", selection: Binding(
                get: { settings.settings.provider },
                set: { value in settings.update { $0.provider = value }; keyInput = ""; status = nil }
            )) {
                ForEach(Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Model", text: Binding(
                    get: {
                        provider == .anthropic
                            ? settings.settings.anthropicModel
                            : settings.settings.openaiModel
                    },
                    set: { value in
                        settings.update {
                            if provider == .anthropic { $0.anthropicModel = value }
                            else { $0.openaiModel = value }
                        }
                    }
                ))
                Text(modelHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API key")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if Keychain.hasKey(for: provider) {
                        Label("Stored in Keychain", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Not set", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                SecureField("Paste key to set or replace", text: $keyInput)

                HStack {
                    Button("Save Key") {
                        Keychain.setKey(keyInput, for: provider)
                        keyInput = ""
                        status = "Saved to Keychain."
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove Key") {
                        Keychain.deleteKey(for: provider)
                        keyInput = ""
                        status = "Removed."
                    }
                    .disabled(!Keychain.hasKey(for: provider))

                    Spacer()
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("""
                    Keys are stored per provider in the login Keychain, never in \
                    config.json — so you can keep both and switch freely.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private var modelHint: String {
        switch provider {
        case .anthropic:
            return """
                Default claude-opus-5. Cheaper vision-capable options: \
                claude-sonnet-5 ($3/$15 per Mtok) or claude-haiku-4-5 ($1/$5). \
                Haiku rejects adaptive thinking and effort — clear both fields \
                under Behavior if you switch to it.
                """
        case .openai:
            return "Any vision-capable chat model, e.g. gpt-4.1-mini or gpt-4.1."
        }
    }
}

// MARK: - Prompts

struct PromptSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var editingId: String?

    private var prompts: [PromptTemplate] { settings.settings.prompts }

    private var currentId: String {
        editingId ?? settings.settings.activePromptId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Default prompt", selection: Binding(
                get: { settings.settings.activePromptId },
                set: { value in settings.update { $0.activePromptId = value } }
            )) {
                ForEach(prompts) { prompt in
                    Text(prompt.name).tag(prompt.id)
                }
            }
            Text("Used as the pre-selected prompt in the confirm step; you can still switch per capture.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker("Editing", selection: Binding(
                get: { currentId },
                set: { editingId = $0 }
            )) {
                ForEach(prompts) { prompt in
                    Text(prompt.name).tag(prompt.id)
                }
            }

            if let index = prompts.firstIndex(where: { $0.id == currentId }) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: Binding(
                        get: { settings.settings.prompts[index].name },
                        set: { value in settings.update { $0.prompts[index].name = value } }
                    ))

                    Text("Template")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { settings.settings.prompts[index].template },
                        set: { value in settings.update { $0.prompts[index].template = value } }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )

                    Text("""
                        Pointer appends framing telling the model the image is a \
                        screenshot of code and to explain the code rather than the \
                        editor — you don't need to repeat that here.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Add Prompt") {
                    let new = PromptTemplate(
                        id: UUID().uuidString,
                        name: "New prompt",
                        template: "Explain this code."
                    )
                    settings.update { $0.prompts.append(new) }
                    editingId = new.id
                }
                Button("Delete", role: .destructive) {
                    guard prompts.count > 1 else { return }
                    let target = currentId
                    settings.update { config in
                        config.prompts.removeAll { $0.id == target }
                        if config.activePromptId == target {
                            config.activePromptId = config.prompts.first?.id ?? ""
                        }
                    }
                    editingId = settings.settings.prompts.first?.id
                }
                .disabled(prompts.count <= 1)
                Spacer()
            }

            Spacer()
        }
    }
}

// MARK: - Behavior

struct BehaviorSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var permissionGranted = ScreenCapture.hasPermission

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Activation keybind")
                        .font(.system(size: 12, weight: .medium))
                    ShortcutRecorder(
                        config: settings.settings.hotkey,
                        onCapture: { config in settings.update { $0.hotkey = config } }
                    )
                    .frame(height: 28)

                    Toggle("Exclusive hotkey (requires Accessibility)", isOn: Binding(
                        get: { settings.settings.exclusiveHotkey },
                        set: { value in settings.update { $0.exclusiveHotkey = value } }
                    ))
                    Text("""
                        Off by default, using permission-free key polling. Polling \
                        observes rather than intercepts, so the keystroke also \
                        reaches the app in front — harmless for a triple-modifier \
                        combo, worth turning on if you rebind to something common.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Selection box")
                        .font(.system(size: 12, weight: .medium))
                    HStack {
                        numberField("Width", value: Binding(
                            get: { settings.settings.boxSize.width },
                            set: { value in settings.update { $0.boxSize.width = value } }
                        ))
                        numberField("Height", value: Binding(
                            get: { settings.settings.boxSize.height },
                            set: { value in settings.update { $0.boxSize.height = value } }
                        ))
                        numberField("Scroll step", value: Binding(
                            get: { settings.settings.scrollStep },
                            set: { value in settings.update { $0.scrollStep = value } }
                        ))
                    }
                    Toggle("Invert scroll-to-resize direction", isOn: Binding(
                        get: { settings.settings.invertScrollResize },
                        set: { value in settings.update { $0.invertScrollResize = value } }
                    ))
                    Text("Scroll adjusts height, ⇧+scroll adjusts width, ⌥+scroll makes fine steps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model request")
                        .font(.system(size: 12, weight: .medium))
                    HStack {
                        intField("Max tokens", value: Binding(
                            get: { settings.settings.maxTokens },
                            set: { value in settings.update { $0.maxTokens = value } }
                        ))
                        intField("History limit", value: Binding(
                            get: { settings.settings.historyLimit },
                            set: { value in settings.update { $0.historyLimit = value } }
                        ))
                    }
                    HStack {
                        TextField("Thinking", text: Binding(
                            get: { settings.settings.anthropicThinking },
                            set: { value in settings.update { $0.anthropicThinking = value } }
                        ))
                        TextField("Effort", text: Binding(
                            get: { settings.settings.anthropicEffort },
                            set: { value in settings.update { $0.anthropicEffort = value } }
                        ))
                    }
                    Text("""
                        Anthropic only. Thinking: adaptive, disabled, or blank to \
                        omit. Effort: low/medium/high/xhigh/max, or blank. On Claude \
                        Opus 5 thinking is on by default and max tokens covers \
                        thinking plus the answer — if replies come back empty, raise \
                        max tokens or lower effort.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Screen Recording")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if permissionGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Button("Grant…") {
                                ScreenCapture.requestPermission()
                            }
                            .controlSize(.small)
                        }
                    }
                    Toggle("Save last capture to ~/Library/Caches/pointer (debug)", isOn: Binding(
                        get: { settings.settings.debugDumpCaptures },
                        set: { value in settings.update { $0.debugDumpCaptures = value } }
                    ))
                    Text("Config file: \(SettingsStore.configURL.path)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .onAppear { permissionGranted = ScreenCapture.hasPermission }
        }
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .frame(width: 80)
        }
    }

    private func intField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .frame(width: 100)
        }
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    let config: HotKeyConfig
    let onCapture: (HotKeyConfig) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.config = config
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.config = config
        view.onCapture = onCapture
        view.needsDisplay = true
    }
}

final class ShortcutRecorderView: NSView {
    var config: HotKeyConfig = .default
    var onCapture: ((HotKeyConfig) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var warning: String?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        warning = nil
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    /// Combos containing ⌘ arrive as key equivalents rather than plain key
    /// events, so they have to be intercepted here or they'd never be
    /// recordable.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {   // Escape abandons recording
            isRecording = false
            warning = nil
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [ModifierName] = []
        for name in ModifierName.allCases where flags.contains(name.flag) {
            modifiers.append(name)
        }

        // Shift alone just types a capital letter; a real global shortcut needs
        // at least one of ⌘/⌃/⌥ or it fires during ordinary typing.
        let hasHardModifier = modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.option)
        guard hasHardModifier else {
            warning = "Needs ⌘, ⌃, or ⌥"
            NSSound.beep()
            needsDisplay = true
            return
        }

        let captured = HotKeyConfig(keyCode: event.keyCode, modifiers: modifiers)
        config = captured
        warning = nil
        isRecording = false
        onCapture?(captured)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if let warning {
            text = warning
            color = .systemOrange
        } else if isRecording {
            text = "Press a shortcut…"
            color = .secondaryLabelColor
        } else {
            text = config.displayString
            color = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        string.draw(at: CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        ))
    }
}
