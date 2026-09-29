import AppKit

// LSUIElement in Info.plist keeps Pointer out of the Dock and app switcher;
// the activation policy is set again at launch so running the bare binary
// (outside the .app bundle) behaves the same way.
//
// NSApplication.delegate is a weak reference, so the delegate is held here at
// file scope for the process lifetime.
// Diagnostic entry point — see SelfTest.swift.
if CommandLine.arguments.contains("--selftest-stream") {
    SelfTest.runStreamTest()
}

let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
