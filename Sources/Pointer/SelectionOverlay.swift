import AppKit

/// Borderless windows refuse key status by default, which would break Escape.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class OverlayView: NSView {
    weak var controller: SelectionOverlayController?

    /// Box in this view's coordinate space, or nil when the cursor is on
    /// another display.
    var localBox: CGRect?
    var sizeLabel: String = ""
    /// Diagnostic: proves the box was actually painted, not just computed.
    var hasLoggedFirstDraw = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        if !hasLoggedFirstDraw {
            hasLoggedFirstDraw = true
            let box = localBox.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))×\(Int($0.height))" } ?? "nil"
            plog("overlay first draw: box=\(box)")
        }
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()

        // Dim everything except the selection. even-odd winding punches the box
        // out of the full-screen rect, which avoids relying on blend modes.
        let dim = NSBezierPath(rect: bounds)
        if let box = localBox {
            dim.appendRect(box)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.18).setFill()
        dim.fill()

        if let box = localBox {
            let stroke = NSBezierPath(rect: box.insetBy(dx: -1, dy: -1))
            stroke.lineWidth = 2
            NSColor.systemRed.setStroke()
            stroke.stroke()

            drawLabel(near: box)
        }

        ctx.restoreGraphicsState()
    }

    private func drawLabel(near box: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: sizeLabel, attributes: attrs)
        let textSize = text.size()
        let padding: CGFloat = 6
        let chipSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)

        // Prefer above the box; flip below when it would run off-screen.
        var origin = CGPoint(x: box.minX, y: box.maxY + 8)
        if origin.y + chipSize.height > bounds.maxY {
            origin.y = box.minY - chipSize.height - 8
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - chipSize.width - 4)
        origin.y = min(max(origin.y, bounds.minY + 4), bounds.maxY - chipSize.height - 4)

        let chip = CGRect(origin: origin, size: chipSize)
        let bg = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.75).setFill()
        bg.fill()

        text.draw(at: CGPoint(x: chip.minX + padding, y: chip.minY + padding / 2))
    }

    // MARK: - Input

    override func scrollWheel(with event: NSEvent) {
        controller?.handleScroll(event)
    }

    override func mouseDown(with event: NSEvent) {
        plog("overlay mouseDown")
        controller?.commit()
    }

    override func rightMouseDown(with event: NSEvent) {
        // macOS routes Control+click here, not to mouseDown — and the default
        // hotkey chord contains Control. Pressing ⌃⌥⌘C and clicking to capture
        // while still holding the chord is the natural gesture, so a "right
        // click" whose modifiers are exactly the still-held chord is that
        // commit click, not a cancel. Only a true bare right-click cancels.
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let controller, !mods.isEmpty, mods.isSubset(of: controller.chordFlags) {
            plog("overlay ctrl-click with hotkey chord held → commit")
            controller.commit()
        } else {
            plog("overlay rightMouseDown mods=\(mods.rawValue) → cancel")
            controller?.cancel(reason: "right-click")
        }
    }

    override func keyDown(with event: NSEvent) {
        // Key-repeat of the still-held hotkey chord; not an error, no beep.
        if event.keyCode == controller?.chordKeyCode { return }

        switch event.keyCode {
        case 53:            // Escape
            plog("overlay keyDown escape")
            controller?.cancel(reason: "escape key")
        case 36, 76:        // Return, keypad Enter
            plog("overlay keyDown return")
            controller?.commit()
        default:
            NSSound.beep()
        }
    }
}

/// Full-screen selection mode: a red box centered on the cursor, resized by
/// scrolling, committed by clicking.
///
/// One window per display with `[.canJoinAllSpaces, .stationary,
/// .fullScreenAuxiliary]` at `.screenSaver` level, so the box also works above
/// full-screen apps and follows the cursor across monitors.
@MainActor
final class SelectionOverlayController {
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []

    private var boxSize: BoxSize
    private var scrollStep: Double
    private var invertScroll: Bool

    /// The activation chord, so clicks made while it is still held can be
    /// recognized as the commit gesture rather than a Control-click cancel.
    private(set) var chordFlags: NSEvent.ModifierFlags = []
    private(set) var chordKeyCode: UInt16 = 0

    /// Box center in global AppKit coordinates (bottom-left origin, the space
    /// `NSEvent.mouseLocation` reports in).
    private var center: CGPoint = .zero

    private var cursorTimer: Timer?
    private var isActive = false
    /// The overlay stays on screen between commit and capture, so without this
    /// a fast double-click would fire two captures from one selection.
    private var hasCommitted = false

    private var onCommit: ((CGRect, BoxSize) -> Void)?
    private var onCancel: (() -> Void)?

    init(boxSize: BoxSize, scrollStep: Double, invertScroll: Bool) {
        self.boxSize = boxSize
        self.scrollStep = scrollStep
        self.invertScroll = invertScroll
    }

    var active: Bool { isActive }
    /// True only in the brief window between a commit and its capture
    /// finishing — the one moment a restart must not tear the session down.
    var committed: Bool { hasCommitted }

    func begin(
        boxSize: BoxSize,
        scrollStep: Double,
        invertScroll: Bool,
        hotkey: HotKeyConfig,
        onCommit: @escaping (CGRect, BoxSize) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        guard !isActive else {
            plog("overlay.begin ignored: already active")
            return
        }
        self.chordFlags = hotkey.flags.intersection([.command, .control, .option, .shift])
        self.chordKeyCode = hotkey.keyCode
        self.boxSize = boxSize
        self.scrollStep = scrollStep
        self.invertScroll = invertScroll
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.center = NSEvent.mouseLocation
        isActive = true

        buildWindows()
        NSApp.activate(ignoringOtherApps: true)
        keyWindowForCursor()?.makeKeyAndOrderFront(nil)
        startCursorTracking()
        refresh()

        let onScreen = Self.screenIndex(for: center).map(String.init) ?? "none"
        plog("""
            overlay up: \(windows.count) window(s), cursor \
            (\(Int(center.x)), \(Int(center.y))) on display \(onScreen), \
            box \(Int(boxSize.width))×\(Int(boxSize.height))
            """)

        // Diagnostic snapshot shortly after the windows go up: whether they are
        // actually visible/key and whether the app got activation — the states
        // that decide if the user can see the box and whether Escape reaches us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let states = self.windows
                    .map { "visible=\($0.isVisible) key=\($0.isKeyWindow) occluded=\(!$0.occlusionState.contains(.visible))" }
                    .joined(separator: "; ")
                plog("overlay @150ms: appActive=\(NSApp.isActive) \(states)")
            }
        }
    }

    /// Removes the overlay from the screen without ending the session. Called
    /// immediately before a capture: `SCContentFilter` already excludes this
    /// app, but ordering the windows out also removes the dim, so what we
    /// capture is exactly what the user saw underneath.
    func hideForCapture() {
        for window in windows { window.orderOut(nil) }
    }

    func end() {
        plog("overlay down")
        cursorTimer?.invalidate()
        cursorTimer = nil
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        isActive = false
        hasCommitted = false
        onCommit = nil
        onCancel = nil
    }

    // MARK: - Window plumbing

    private func buildWindows() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true

            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            window.contentView = view

            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
    }

    private func keyWindowForCursor() -> OverlayWindow? {
        guard let index = Self.screenIndex(for: NSEvent.mouseLocation) else { return windows.first }
        return index < windows.count ? windows[index] : windows.first
    }

    /// Which display a point belongs to.
    ///
    /// `NSRect.contains` is half-open — it excludes `maxX`/`maxY` — so a cursor
    /// pinned against the top or right edge of a display belongs to *no* screen
    /// by that test. `NSEvent.mouseLocation` reports exactly `frame.maxY` when
    /// the pointer is resting on the top edge, which is precisely where it sits
    /// after using the menu-bar popover. Treating that as "no display" left the
    /// overlay up with no box drawn on it, which looked like the hotkey doing
    /// nothing. Nearest display, never nil while a screen exists.
    private static func screenIndex(for point: CGPoint) -> Int? {
        let screens = NSScreen.screens
        if let hit = screens.firstIndex(where: { $0.frame.contains(point) }) {
            return hit
        }
        return screens.indices.min {
            squaredDistance(from: point, to: screens[$0].frame)
                < squaredDistance(from: point, to: screens[$1].frame)
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Polling the cursor rather than using tracking areas keeps this working
    /// uniformly as the pointer crosses between displays.
    private func startCursorTracking() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let location = NSEvent.mouseLocation
                if location != self.center {
                    self.center = location
                    self.refresh()
                    // Keep Escape working after the cursor changes display.
                    if let window = self.keyWindowForCursor(), !window.isKeyWindow {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    // MARK: - Geometry

    /// Selection rect in global AppKit coordinates.
    private var globalBox: CGRect {
        CGRect(
            x: center.x - boxSize.width / 2,
            y: center.y - boxSize.height / 2,
            width: boxSize.width,
            height: boxSize.height
        )
    }

    private func refresh() {
        let box = globalBox
        let label = "\(Int(boxSize.width.rounded())) × \(Int(boxSize.height.rounded()))"
        let screens = NSScreen.screens
        let cursorScreenIndex = Self.screenIndex(for: center)

        for (index, view) in views.enumerated() {
            guard index < screens.count else { continue }
            let origin = screens[index].frame.origin
            if index == cursorScreenIndex {
                view.localBox = box.offsetBy(dx: -origin.x, dy: -origin.y)
                view.sizeLabel = label
            } else {
                view.localBox = nil
                view.sizeLabel = ""
            }
            view.needsDisplay = true
        }
    }

    // MARK: - Input handling

    func handleScroll(_ event: NSEvent) {
        guard isActive else { return }

        var dy = Double(event.scrollingDeltaY)
        var dx = Double(event.scrollingDeltaX)

        // Undo the system's "natural scrolling" flip so the gesture direction
        // is consistent regardless of that setting.
        if event.isDirectionInvertedFromDevice {
            dy = -dy
            dx = -dx
        }
        if invertScroll {
            dy = -dy
            dx = -dx
        }

        let fine = event.modifierFlags.contains(.option)
        // Trackpads report point-precise deltas; wheels report discrete clicks.
        let scale: Double
        if event.hasPreciseScrollingDeltas {
            scale = fine ? 0.25 : 1.0
        } else {
            scale = fine ? 1.0 : scrollStep
        }

        var width = boxSize.width
        var height = boxSize.height

        if event.modifierFlags.contains(.shift) {
            // Most mice have no horizontal wheel, so Shift+scroll drives width.
            width += dy * scale
        } else {
            height += dy * scale
            width += dx * scale
        }

        let maxSize = maximumBoxSize()
        boxSize.width = min(max(width, BoxSize.minimum.width), maxSize.width)
        boxSize.height = min(max(height, BoxSize.minimum.height), maxSize.height)
        refresh()
    }

    private func maximumBoxSize() -> BoxSize {
        let screen = Self.screenIndex(for: center).map { NSScreen.screens[$0] } ?? NSScreen.main
        guard let frame = screen?.frame else { return BoxSize(width: 4000, height: 4000) }
        return BoxSize(width: frame.width, height: frame.height)
    }

    func commit() {
        guard isActive, !hasCommitted else {
            plog("overlay commit ignored (active=\(isActive) committed=\(hasCommitted))")
            return
        }
        plog("overlay commit")
        hasCommitted = true
        onCommit?(globalBox, boxSize)
    }

    func cancel(reason: String) {
        guard isActive, !hasCommitted else { return }
        plog("overlay cancelled: \(reason)")
        let cancelHandler = onCancel
        end()
        cancelHandler?()
    }
}
