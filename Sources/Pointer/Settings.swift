import AppKit
import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        }
    }
}

struct BoxSize: Codable, Equatable {
    var width: Double
    var height: Double

    static let minimum = BoxSize(width: 120, height: 48)
}

/// Modifier names as they appear in config.json. Kept as strings so the file
/// stays hand-editable.
enum ModifierName: String, Codable, CaseIterable {
    case command, option, control, shift

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    /// Display order matching macOS menu convention.
    static let displayOrder: [ModifierName] = [.control, .option, .shift, .command]
}

struct HotKeyConfig: Codable, Equatable {
    /// Carbon/CG virtual keycode. 8 == "c".
    var keyCode: UInt16
    var modifiers: [ModifierName]

    var flags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.flag) }
    }

    /// The same chord as `CGEventFlags`, for the poller's thread-safe
    /// CoreGraphics session-state reads (NSEvent is main-thread only).
    var cgFlags: CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) {
            switch $1 {
            case .command: $0.insert(.maskCommand)
            case .option: $0.insert(.maskAlternate)
            case .control: $0.insert(.maskControl)
            case .shift: $0.insert(.maskShift)
            }
        }
    }

    /// The same chord as Carbon modifier bits (cmdKey etc.), for
    /// `RegisterEventHotKey` — whose constants also vanished with the headers.
    var carbonModifiers: UInt32 {
        modifiers.reduce(into: UInt32(0)) {
            switch $1 {
            case .command: $0 |= 0x0100 // cmdKey
            case .shift: $0 |= 0x0200   // shiftKey
            case .option: $0 |= 0x0800  // optionKey
            case .control: $0 |= 0x1000 // controlKey
            }
        }
    }

    var displayString: String {
        let mods = ModifierName.displayOrder
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        return mods + KeyCodeNames.name(for: keyCode)
    }

    static let `default` = HotKeyConfig(keyCode: 8, modifiers: [.control, .option, .command])
}

struct PromptTemplate: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var template: String
}

struct Settings: Codable, Equatable {
    var provider: Provider = .anthropic
    var anthropicModel: String = "claude-opus-5"
    var openaiModel: String = "gpt-4.1-mini"
    /// "adaptive", "disabled", or "" to omit the parameter entirely.
    /// Model-gated: older models such as Haiku 4.5 reject adaptive thinking,
    /// so switching model may mean clearing this.
    var anthropicThinking: String = "adaptive"
    /// "low"/"medium"/"high"/"xhigh"/"max", or "" to omit. Also model-gated.
    var anthropicEffort: String = "low"
    var hotkey: HotKeyConfig = .default
    var exclusiveHotkey: Bool = false
    var boxSize: BoxSize = BoxSize(width: 900, height: 320)
    var scrollStep: Double = 10
    /// Flips scroll-to-resize direction. Direction already accounts for the
    /// system "natural scrolling" setting; this is the escape hatch if the
    /// gesture still feels backwards on a particular device.
    var invertScrollResize: Bool = false
    /// On Claude Opus 5 thinking is on by default and `max_tokens` caps
    /// thinking *plus* response text — a tight budget truncates the answer
    /// mid-sentence, so this leaves headroom.
    var maxTokens: Int = 2048
    var historyLimit: Int = 200
    var activePromptId: String = "simple"
    var prompts: [PromptTemplate] = Settings.defaultPrompts
    var debugDumpCaptures: Bool = false

    static let defaultPrompts: [PromptTemplate] = [
        PromptTemplate(
            id: "simple",
            name: "Explain simply",
            template: "Explain what this code does in 2-3 plain sentences. No preamble."
        ),
        PromptTemplate(
            id: "risk",
            name: "What breaks?",
            template: "What breaks if this code is removed or changed? Be specific."
        ),
        PromptTemplate(
            id: "perf",
            name: "Performance",
            template: "Any performance or complexity concerns here? Be specific and brief."
        ),
    ]

    var activeModel: String {
        switch provider {
        case .anthropic: return anthropicModel
        case .openai: return openaiModel
        }
    }

    var activePrompt: PromptTemplate {
        prompts.first { $0.id == activePromptId } ?? prompts.first ?? Settings.defaultPrompts[0]
    }

    func prompt(id: String) -> PromptTemplate? {
        prompts.first { $0.id == id }
    }

    /// Decoding tolerates a partially-specified file: every key falls back to
    /// its default, so a hand-written config with only `provider` set is valid.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? d.provider
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? d.anthropicModel
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? d.openaiModel
        anthropicThinking = try c.decodeIfPresent(String.self, forKey: .anthropicThinking) ?? d.anthropicThinking
        anthropicEffort = try c.decodeIfPresent(String.self, forKey: .anthropicEffort) ?? d.anthropicEffort
        hotkey = try c.decodeIfPresent(HotKeyConfig.self, forKey: .hotkey) ?? d.hotkey
        exclusiveHotkey = try c.decodeIfPresent(Bool.self, forKey: .exclusiveHotkey) ?? d.exclusiveHotkey
        boxSize = try c.decodeIfPresent(BoxSize.self, forKey: .boxSize) ?? d.boxSize
        scrollStep = try c.decodeIfPresent(Double.self, forKey: .scrollStep) ?? d.scrollStep
        invertScrollResize = try c.decodeIfPresent(Bool.self, forKey: .invertScrollResize) ?? d.invertScrollResize
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        activePromptId = try c.decodeIfPresent(String.self, forKey: .activePromptId) ?? d.activePromptId
        let loadedPrompts = try c.decodeIfPresent([PromptTemplate].self, forKey: .prompts) ?? d.prompts
        prompts = loadedPrompts.isEmpty ? d.prompts : loadedPrompts
        debugDumpCaptures = try c.decodeIfPresent(Bool.self, forKey: .debugDumpCaptures) ?? d.debugDumpCaptures
    }
}

// MARK: - Store

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: Settings

    /// Set while we are writing the file ourselves, so the watcher doesn't
    /// bounce our own save back through the decoder.
    private var suppressReload = false
    private var watcher: FileWatcher?
    private var saveWorkItem: DispatchWorkItem?

    static let configURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("pointer", isDirectory: true)
        return base.appendingPathComponent("config.json")
    }()

    init() {
        settings = SettingsStore.read() ?? Settings()
        // Materialize the file on first run so it's discoverable and editable.
        if !FileManager.default.fileExists(atPath: SettingsStore.configURL.path) {
            save()
        }
        startWatching()
    }

    private static func read() -> Settings? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            NSLog("Pointer: config.json is not valid JSON (%@) — using defaults", "\(error)")
            return nil
        }
    }

    func save() {
        suppressReload = true
        defer {
            // Give the vnode event time to land before re-enabling reloads.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.suppressReload = false
            }
        }

        let url = SettingsStore.configURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            let tmp = dir.appendingPathComponent("config.json.\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            // replaceItemAt is atomic and preserves the destination if we fail.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            NSLog("Pointer: could not save config: %@", "\(error)")
        }
    }

    /// Mutates in memory immediately and writes to disk after a short delay.
    ///
    /// SwiftUI text-field bindings call this on every keystroke. Saving
    /// synchronously would write the file per character and, worse, the file
    /// watcher could fire mid-word and replace `settings` underneath the field —
    /// which shows up as the caret jumping while you type.
    func update(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        scheduleSave()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func startWatching() {
        watcher = FileWatcher(url: SettingsStore.configURL) { [weak self] in
            guard let self, !self.suppressReload else { return }
            guard let fresh = SettingsStore.read(), fresh != self.settings else { return }
            self.settings = fresh
        }
    }
}

/// Watches a single path for content changes. Editors commonly replace files
/// rather than writing in place, so the source is rebuilt on delete/rename —
/// without that, hand-editing the config would stop working after one save.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.kavi.pointer.filewatcher")

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet — retry shortly.
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.arm() }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            DispatchQueue.main.async { self.onChange() }
            if flags.contains(.delete) || flags.contains(.rename) {
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.arm() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}
