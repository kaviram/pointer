import Foundation
import os

/// Terse tracing for the hotkey → selection → capture path.
///
/// This flow spans a global keybind, per-display overlay windows, an async
/// capture and a popover, and when it goes wrong there is no UI to inspect —
/// "I pressed the shortcut and nothing happened" is otherwise impossible to
/// localise. A handful of lines per capture is cheap. Read them with:
///
///     log show --predicate 'subsystem == "com.kavi.pointer"' --last 10m --style compact
///
/// or follow them live with `log stream` and the same predicate.
private let logger = Logger(subsystem: "com.kavi.pointer", category: "flow")

/// Logged `.public` on purpose: os_log redacts interpolated values by default,
/// which would turn every one of these lines into `<private>`. Nothing here
/// carries captured pixels, prompts or responses — only geometry and state.
func plog(_ message: String) {
    logger.log("\(message, privacy: .public)")
}
