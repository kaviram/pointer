import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureError: LocalizedError {
    case needsPermission
    case noDisplayForRegion
    case emptyRegion
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsPermission:
            return "Pointer needs Screen Recording permission to capture the selection."
        case .noDisplayForRegion:
            return "Couldn't work out which display that selection is on."
        case .emptyRegion:
            return "That selection is empty."
        case .failed(let message):
            return message
        }
    }
}

struct Capture {
    let image: CGImage
    let pngData: Data
    /// Size in points, for cost estimation and display.
    let pointSize: CGSize
}

enum ScreenCapture {

    /// Captures `globalRect` (global AppKit coordinates, bottom-left origin).
    ///
    /// Deliberately *not* `SCScreenshotManager.captureImage(in:)`. That one-liner
    /// captures everything on screen, which here means Pointer's own overlay and
    /// result popover — the model would end up reading our red box and its own
    /// previous answer back out of the screenshot. Filtering by display while
    /// excluding this application makes our windows structurally invisible to
    /// the capture; `sourceRect` then crops to the selection.
    static func capture(globalRect: CGRect, dumpForDebug: Bool) async throws -> Capture {
        guard globalRect.width >= 1, globalRect.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        guard let screen = screen(containing: globalRect) else {
            throw CaptureError.noDisplayForRegion
        }
        guard let displayID = screen.displayID else {
            throw CaptureError.noDisplayForRegion
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // A missing grant and a genuine failure both surface here as an
            // opaque error, so distinguish them rather than blaming permission
            // for every problem.
            if !hasPermission { throw CaptureError.needsPermission }
            throw CaptureError.failed(
                "Could not enumerate displays: \(error.localizedDescription)"
            )
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplayForRegion
        }

        // Exclude our own app so neither the overlay nor the popover can land
        // inside the screenshot.
        let ownApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )

        let sourceRect = displayLocalRect(globalRect: globalRect, screen: screen, display: display)
        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int((sourceRect.width * scale).rounded())
        config.height = Int((sourceRect.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.failed("Capture failed: \(error.localizedDescription)")
        }

        guard let png = pngData(from: image) else {
            throw CaptureError.failed("Could not encode the capture as PNG.")
        }

        if dumpForDebug {
            dump(png)
        }

        return Capture(image: image, pngData: png, pointSize: sourceRect.size)
    }

    /// Converts a rect from global AppKit coordinates (bottom-left origin,
    /// main display's lower-left as origin) into display-local, top-left-origin
    /// points, which is what `SCStreamConfiguration.sourceRect` expects.
    private static func displayLocalRect(
        globalRect: CGRect,
        screen: NSScreen,
        display: SCDisplay
    ) -> CGRect {
        let frame = screen.frame
        let localX = globalRect.minX - frame.minX
        // Flip the vertical axis: AppKit measures up from the bottom, the
        // capture API measures down from the top.
        let localY = frame.maxY - globalRect.maxY

        var rect = CGRect(
            x: localX,
            y: localY,
            width: globalRect.width,
            height: globalRect.height
        )

        // Clamp to the display so a selection hanging off an edge still works.
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        rect = rect.intersection(bounds)
        return rect.integral
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        // Fall back to whichever display overlaps the selection the most.
        return NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        } ?? NSScreen.main
    }

    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    private static func dump(_ png: Data) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/pointer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("last-capture.png")
            try png.write(to: url, options: .atomic)
            NSLog("Pointer: wrote debug capture to %@", url.path)
        } catch {
            NSLog("Pointer: could not write debug capture: %@", "\(error)")
        }
    }

    /// Whether Screen Recording has been granted. `CGPreflight...` answers
    /// without triggering the prompt, so the UI can show a clear state instead
    /// of a mysterious capture failure.
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
