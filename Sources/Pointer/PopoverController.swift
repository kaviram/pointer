import AppKit
import SwiftUI

/// Hosts the SwiftUI flow in an `NSPopover` anchored under the menu-bar icon.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let state: AppState
    private weak var anchor: NSStatusBarButton?

    init(state: AppState, anchor: NSStatusBarButton?) {
        self.state = state
        self.anchor = anchor
        super.init()

        let hosting = NSHostingController(rootView: RootView(state: state))
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        // On modern macOS, NSApp.activate is a cooperative *request* — it can
        // be granted a beat after show() returns, in which case the makeKey
        // below silently failed and Return/Escape go to some other app. Re-key
        // whenever activation actually lands while the popover is up.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.popover.contentViewController?.view.window?.makeKey()
                plog("popover re-keyed after app activation")
            }
        }
    }

    var isShown: Bool { popover.isShown }

    func show() {
        guard let anchor else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // The popover has to be key for Return (Analyze) and Escape (Cancel) to
        // reach the SwiftUI buttons.
        popover.contentViewController?.view.window?.makeKey()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                let key = self.popover.contentViewController?.view.window?.isKeyWindow ?? false
                plog("popover @200ms: appActive=\(NSApp.isActive) key=\(key)")
            }
        }
    }

    func close() {
        popover.performClose(nil)
    }

    func toggle() {
        if popover.isShown {
            close()
        } else {
            show()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        plog("popover closed (phase=\(state.phase))")
        // Dismissing at the confirm step means "don't send this" — discard the
        // capture. An in-flight or finished analysis is left alone so reopening
        // the popover still shows it.
        if state.phase == .confirming {
            state.cancel()
        }
    }
}
