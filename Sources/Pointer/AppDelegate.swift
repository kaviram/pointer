import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = SettingsStore()
    private let history = HistoryStore()

    private var state: AppState!
    private var statusItem: NSStatusItem!
    private var popover: PopoverController!
    private var hotkey: HotKeyMonitor!
    private var overlay: SelectionOverlayController!
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        state = AppState(settings: settings, history: history)
        buildStatusItem()

        popover = PopoverController(state: state, anchor: statusItem.button)

        state.onPresent = { [weak self] in self?.popover.show() }
        state.onDismiss = { [weak self] in self?.popover.close() }

        let config = settings.settings
        overlay = SelectionOverlayController(
            boxSize: config.boxSize,
            scrollStep: config.scrollStep,
            invertScroll: config.invertScrollResize
        )

        hotkey = HotKeyMonitor(
            config: config.hotkey,
            useTap: config.exclusiveHotkey
        ) { [weak self] in
            self?.beginSelection()
        }

        observeSettings()
        installDebugTriggers()

        plog("""
            ready: hotkey \(config.hotkey.displayString)\
            \(config.exclusiveHotkey ? " (exclusive)" : ""), \
            screen recording \(ScreenCapture.hasPermission ? "granted" : "NOT granted")
            """)

        // Deliberately no permission prompt at launch — a modal on every login
        // would be obnoxious. The menu shows the missing grant, and the prompt
        // appears when a capture is actually attempted.
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "Pointer"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isSecondary {
            showMenu()
        } else {
            popover.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let capture = NSMenuItem(
            title: "Capture Region  (\(settings.settings.hotkey.displayString))",
            action: #selector(captureFromMenu),
            keyEquivalent: ""
        )
        capture.target = self
        menu.addItem(capture)

        menu.addItem(.separator())

        let promptsItem = NSMenuItem(title: "Default Prompt", action: nil, keyEquivalent: "")
        let promptsMenu = NSMenu()
        for prompt in settings.settings.prompts {
            let item = NSMenuItem(
                title: prompt.name,
                action: #selector(selectPrompt(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = prompt.id
            item.state = prompt.id == settings.settings.activePromptId ? .on : .off
            promptsMenu.addItem(item)
        }
        promptsItem.submenu = promptsMenu
        menu.addItem(promptsItem)

        menu.addItem(.separator())

        if !ScreenCapture.hasPermission {
            let warn = NSMenuItem(
                title: "Screen Recording not granted",
                action: #selector(promptForScreenRecordingFromMenu),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit Pointer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach immediately so the next left-click opens the popover rather
        // than the menu.
        statusItem.menu = nil
    }

    @objc private func captureFromMenu() {
        beginSelection()
    }

    @objc private func selectPrompt(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.update { $0.activePromptId = id }
    }

    @objc private func promptForScreenRecordingFromMenu() {
        promptForScreenRecording()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Pointer Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The shortcut recorder swallows keystrokes through the responder chain, but
    // the hotkey monitor polls independently of it — so without suspending it,
    // pressing your *current* combo while rebinding would also open a selection
    // over the Settings window.
    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as AnyObject === settingsWindow else { return }
        hotkey?.isEnabled = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as AnyObject === settingsWindow else { return }
        hotkey?.isEnabled = true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject === settingsWindow else { return }
        hotkey?.isEnabled = true
    }

    // MARK: - Selection → capture → confirm

    private func beginSelection() {
        // The keybind always means "start a selection at the cursor", no
        // matter what the app is doing — whatever is up gets torn down first.
        // There is deliberately NO state in which the press is ignored: every
        // "guard against re-entrance" here so far has eventually wedged and
        // presented as a dead keybind. The one exception is the instant
        // between a commit and its capture completing, when tearing down
        // would corrupt the in-flight screenshot.
        if overlay.active {
            if overlay.committed {
                plog("selection ignored: a capture is completing")
                return
            }
            plog("restarting the active selection at the cursor")
            overlay.cancel(reason: "restarted by hotkey")
        }

        guard ScreenCapture.hasPermission else {
            plog("selection blocked: no Screen Recording permission")
            promptForScreenRecording()
            return
        }

        // A result popover deliberately stays open so you can keep reading it,
        // but pressing the hotkey then means "capture the next thing" — so
        // dismiss it and carry on. Bailing out instead is what made the
        // shortcut look dead until you clicked the menu-bar icon.
        if popover.isShown {
            plog("dismissing the open popover to start a new selection")
            popover.close()
        }

        let config = settings.settings

        overlay.begin(
            boxSize: config.boxSize,
            scrollStep: config.scrollStep,
            invertScroll: config.invertScrollResize,
            hotkey: config.hotkey,
            onCommit: { [weak self] rect, size in
                self?.commitSelection(rect: rect, size: size)
            }
        )
    }

    private func commitSelection(rect: CGRect, size: BoxSize) {
        // Remember the size the user dialed in.
        if size != settings.settings.boxSize {
            settings.update { $0.boxSize = size }
        }

        let dump = settings.settings.debugDumpCaptures

        // Order the overlay out before capturing. SCContentFilter already
        // excludes this app, but hiding first also removes the dim so the
        // capture matches what was underneath.
        overlay.hideForCapture()

        Task { [weak self] in
            guard let self else { return }
            // Give the window server a moment to composite the overlay away.
            try? await Task.sleep(nanoseconds: 90_000_000)

            do {
                let capture = try await ScreenCapture.capture(globalRect: rect, dumpForDebug: dump)
                self.overlay.end()
                plog("captured \(Int(capture.pointSize.width))×\(Int(capture.pointSize.height))pt")
                self.state.present(capture: capture)
            } catch {
                self.overlay.end()
                plog("capture failed: \(error.localizedDescription)")
                self.presentCaptureError(error)
            }
        }
    }

    private func presentCaptureError(_ error: Error) {
        if case CaptureError.needsPermission = error {
            promptForScreenRecording()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn't capture that selection"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Permission

    private func promptForScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Pointer reads the pixels inside the box you draw, so macOS requires \
            Screen Recording access. It is the only permission Pointer needs.

            After granting it, macOS requires the app to relaunch before the \
            change takes effect.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenCapture.requestPermission()
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Debug triggers

    /// Lets the selection flow be driven from the command line, so "the keybind
    /// did nothing" can be reproduced and watched without anyone at the
    /// keyboard. Gated on `debugDumpCaptures`; inert otherwise.
    ///
    ///     swift -e 'import Foundation
    ///       DistributedNotificationCenter.default().postNotificationName(
    ///         .init("com.kavi.pointer.debug.begin"), object: nil,
    ///         userInfo: nil, deliverImmediately: true)'
    private func installDebugTriggers() {
        let center = DistributedNotificationCenter.default()
        let actions: [(String, @MainActor () -> Void)] = [
            ("begin", { [weak self] in self?.beginSelection() }),
            ("commit", { [weak self] in self?.overlay.commit() }),
            ("cancel", { [weak self] in self?.overlay.cancel(reason: "debug trigger") }),
            ("analyze", { [weak self] in self?.state.analyze() }),
            ("dismiss", { [weak self] in self?.state.cancel() }),
        ]
        for (name, action) in actions {
            center.addObserver(
                forName: .init("com.kavi.pointer.debug.\(name)"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.settings.settings.debugDumpCaptures else {
                        plog("debug trigger '\(name)' ignored: debugDumpCaptures is off")
                        return
                    }
                    plog("debug trigger: \(name)")
                    action()
                }
            }
        }
    }

    // MARK: - Live config

    private func observeSettings() {
        settings.$settings
            .removeDuplicates()
            .sink { [weak self] config in
                self?.hotkey?.reconfigure(
                    config: config.hotkey,
                    useTap: config.exclusiveHotkey
                )
            }
            .store(in: &cancellables)
    }
}
