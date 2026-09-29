import AppKit
import ApplicationServices
import CoreGraphics

/// Global activation keybind.
///
/// Exactly one detection path runs at a time:
///
///  - **Carbon `RegisterEventHotKey`** (primary): the sanctioned global-hotkey
///    API — the OS matches the chord and notifies us. No permission, fires in
///    every app state, and consumes the keystroke. Resolved at runtime because
///    the macOS 26 SDK removed its headers (see CarbonHotKey.swift).
///
///  - **Event tap** (opt-in via `exclusiveHotkey`): `CGEvent.tapCreate`, at
///    the cost of an Accessibility grant.
///
///  - **Polling** (last resort, only if Carbon registration fails):
///    `CGEventSource.keyState` sampled on a background timer. No permission,
///    but macOS blanks key state for non-active apps, so it only sees the
///    chord while Pointer itself is frontmost.
@MainActor
final class HotKeyMonitor {
    private var config: HotKeyConfig
    private var useTap: Bool
    private let onTrigger: () -> Void

    /// Suspended while the Settings window is key, so rebinding the shortcut
    /// doesn't also trigger the old one. Re-entrance during a selection is
    /// guarded by the overlay's own `active` flag, not here — gating on UI state
    /// here is what previously left the shortcut dead after an analysis.
    var isEnabled = true

    private var carbon: CarbonHotKey?
    private var poller: KeyPoller?
    /// Held while polling. Without it App Nap coalesces this idle accessory
    /// app's timers to multi-second granularity and quick presses are missed.
    private var napActivity: NSObjectProtocol?

    private var tapPort: CFMachPort?
    private var tapSource: CFRunLoopSource?

    init(config: HotKeyConfig, useTap: Bool, onTrigger: @escaping () -> Void) {
        self.config = config
        self.useTap = useTap
        self.onTrigger = onTrigger
        start()
    }

    deinit {
        // Torn down explicitly via stop(); deinit is a backstop for the tap's
        // CF objects, which are not managed by ARC.
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
    }

    func reconfigure(config: HotKeyConfig, useTap: Bool) {
        guard config != self.config || useTap != self.useTap else { return }
        self.config = config
        self.useTap = useTap
        stop()
        start()
    }

    // MARK: - Lifecycle

    private func start() {
        if useTap, startTap() {
            return
        }
        if useTap {
            NSLog("Pointer: exclusive hotkey requested but the event tap could not be installed; falling back to polling")
        }

        carbon = CarbonHotKey(
            keyCode: UInt32(config.keyCode),
            carbonModifiers: config.carbonModifiers
        ) { [weak self] in
            MainActor.assumeIsolated { self?.fire(source: "carbon") }
        }
        if carbon == nil {
            plog("carbon hotkey unavailable — falling back to polling")
            startPolling()
        }
    }

    private func stop() {
        carbon?.invalidate()
        carbon = nil
        poller?.cancel()
        poller = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }

        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            tapSource = nil
        }
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            tapPort = nil
        }
    }

    // MARK: - Polling (no permission required)

    private func startPolling() {
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Pointer global hotkey monitoring"
        )
        poller = KeyPoller(
            keyCode: CGKeyCode(config.keyCode),
            required: config.cgFlags
        ) { [weak self] in
            // Fired on the poll queue; the response belongs to the main actor.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fire(source: "poll") }
            }
        }
    }

    /// Single funnel for every detection path.
    private func fire(source: String) {
        guard isEnabled else {
            plog("hotkey suppressed (\(source))")
            return
        }
        plog("hotkey fired (\(source))")
        onTrigger()
    }

    /// Only the four modifiers a shortcut can actually be built from.
    ///
    /// Comparing the full `deviceIndependentFlagsMask` instead means anything
    /// else riding along in the flags makes the combo never match — with Caps
    /// Lock on, the shortcut is simply dead, with nothing on screen to explain
    /// why. `.function` and `.numericPad` behave the same way.
    static let significantFlags: NSEvent.ModifierFlags =
        [.command, .control, .option, .shift]

    // MARK: - Event tap (consumes the keystroke; needs Accessibility)


    private func startTap() -> Bool {
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            // A tap that gets disabled (timeout / user input) stops delivering
            // events silently unless it is re-enabled.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { monitor.reenableTap() }
                return Unmanaged.passUnretained(event)
            }

            var consumed = false
            MainActor.assumeIsolated {
                consumed = monitor.handleTapped(event: event)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tapPort = port
        tapSource = source
        return true
    }

    private func reenableTap() {
        guard let port = tapPort else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// - Returns: true when the event should be swallowed.
    private func handleTapped(event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == config.keyCode else { return false }

        let required = config.flags.intersection(Self.significantFlags)
        let current = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(Self.significantFlags)
        guard current == required else { return false }
        guard isEnabled else {
            plog("hotkey suppressed (tap)")
            return false
        }

        plog("hotkey fired (tap)")
        onTrigger()
        return true
    }

    private func requestAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed"
        alert.informativeText = """
            The exclusive hotkey uses a system event tap so the keystroke is \
            consumed and never reaches the app you're pointing at. That needs \
            Accessibility access.

            Until it's granted, Pointer falls back to permission-free polling — \
            the shortcut still works, but the keystroke also reaches the \
            frontmost app.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Keep Using Polling")

        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - The poller (fallback only)

/// Samples the chord state on a strict background dispatch timer — used only
/// when Carbon registration fails. Off the main thread and exempt from timer
/// coalescing, so a quick press can't fall between polls; but macOS blanks
/// `CGEventSource` key state for non-active apps (that's what Input Monitoring
/// gates), so this path only sees the chord while Pointer itself is frontmost.
final class KeyPoller {
    private let queue = DispatchQueue(label: "com.kavi.pointer.hotkey", qos: .userInteractive)
    private var source: DispatchSourceTimer?

    private let keyCode: CGKeyCode
    private let required: CGEventFlags
    private let onFire: () -> Void

    /// Poll-queue-confined; makes the fire edge-triggered (once per press).
    private var wasDown = false

    private static let significantFlags: CGEventFlags =
        [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    init(keyCode: CGKeyCode, required: CGEventFlags, onFire: @escaping () -> Void) {
        self.keyCode = keyCode
        self.required = required.intersection(Self.significantFlags)
        self.onFire = onFire

        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    private func poll() {
        guard !required.isEmpty else { return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
            .intersection(Self.significantFlags)
        let down = flags == required
            && CGEventSource.keyState(.combinedSessionState, key: keyCode)
        let fire = down && !wasDown
        wasDown = down
        if fire { onFire() }
    }
}
