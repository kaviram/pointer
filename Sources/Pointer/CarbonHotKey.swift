import AppKit

/// The classic Carbon global-hotkey registration, resolved at runtime.
///
/// `RegisterEventHotKey` is the one sanctioned way for a Mac app to own a
/// global keybind with no permissions: the OS matches the chord itself and
/// delivers "your hotkey fired" — the app never observes the keyboard (which
/// is why no Input Monitoring is needed), it works regardless of which app is
/// active, and the keystroke is consumed so it never reaches the frontmost
/// app.
///
/// The macOS 26 SDK removed the Carbon event declarations from its headers,
/// which is why this file exists: the *implementations* still ship in
/// Carbon.framework for binary compatibility, so every symbol is resolved
/// with `dlsym` at runtime. If a future macOS finally drops them, `init`
/// returns nil and the caller falls back to polling — the app keeps launching
/// and working either way, which linking the symbols at build time would not
/// allow.
final class CarbonHotKey {

    // Header-less Carbon signatures, reconstructed against the (stable) C ABI.
    // Swift-defined structs are not allowed in @convention(c) signatures, so
    // the two trivial Carbon structs cross the boundary bit-packed instead:
    //  - EventTypeSpec {UInt32 class; UInt32 kind} is passed by pointer → two
    //    UInt32s in contiguous memory, handed over as a raw pointer.
    //  - EventHotKeyID {OSType signature; UInt32 id} is passed by value → on
    //    arm64/x86-64 an 8-byte trivial struct rides in one register, exactly
    //    like a UInt64 with the first field in the low half.
    private typealias EventHandlerUPP = @convention(c) (
        OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
    ) -> OSStatus
    private typealias GetEventDispatcherTargetFn = @convention(c) () -> OpaquePointer?
    private typealias InstallEventHandlerFn = @convention(c) (
        OpaquePointer?, EventHandlerUPP, UInt, UnsafeRawPointer,
        UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>?
    ) -> OSStatus
    private typealias RemoveEventHandlerFn = @convention(c) (OpaquePointer?) -> OSStatus
    private typealias RegisterEventHotKeyFn = @convention(c) (
        UInt32, UInt32, UInt64, OpaquePointer?, UInt32,
        UnsafeMutablePointer<OpaquePointer?>
    ) -> OSStatus
    private typealias UnregisterEventHotKeyFn = @convention(c) (OpaquePointer?) -> OSStatus

    private static let kEventClassKeyboard: UInt32 = 0x6B65_7962 // 'keyb'
    private static let kEventHotKeyPressed: UInt32 = 5

    private let handler: () -> Void
    private var hotKeyRef: OpaquePointer?
    private var handlerRef: OpaquePointer?
    private let unregister: UnregisterEventHotKeyFn?
    private let removeHandler: RemoveEventHandlerFn?

    /// Fails (returns nil) when any Carbon symbol is missing or registration
    /// is refused — callers treat that as "use the fallback", never an error.
    init?(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        guard
            let carbon = dlopen(
                "/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon", RTLD_LAZY
            ),
            let getTargetSym = dlsym(carbon, "GetEventDispatcherTarget"),
            let installSym = dlsym(carbon, "InstallEventHandler"),
            let removeSym = dlsym(carbon, "RemoveEventHandler"),
            let registerSym = dlsym(carbon, "RegisterEventHotKey"),
            let unregisterSym = dlsym(carbon, "UnregisterEventHotKey")
        else {
            plog("carbon hotkey unavailable: symbols missing from this macOS")
            return nil
        }

        let getTarget = unsafeBitCast(getTargetSym, to: GetEventDispatcherTargetFn.self)
        let install = unsafeBitCast(installSym, to: InstallEventHandlerFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterEventHotKeyFn.self)
        self.removeHandler = unsafeBitCast(removeSym, to: RemoveEventHandlerFn.self)
        self.unregister = unsafeBitCast(unregisterSym, to: UnregisterEventHotKeyFn.self)

        guard let target = getTarget() else {
            plog("carbon hotkey unavailable: no event dispatcher target")
            return nil
        }

        // The C callback cannot capture context, so the instance rides along
        // as userData. Fires on the main thread, during normal event dispatch.
        let callback: EventHandlerUPP = { _, _, userData in
            if let userData {
                Unmanaged<CarbonHotKey>.fromOpaque(userData).takeUnretainedValue().handler()
            }
            return OSStatus(0) // noErr — the keystroke is consumed
        }

        let spec: [UInt32] = [Self.kEventClassKeyboard, Self.kEventHotKeyPressed]
        var installedHandler: OpaquePointer?
        let installStatus = spec.withUnsafeBytes { specBytes in
            install(
                target, callback, 1, specBytes.baseAddress!,
                Unmanaged.passUnretained(self).toOpaque(), &installedHandler
            )
        }
        guard installStatus == 0, installedHandler != nil else {
            plog("carbon hotkey unavailable: InstallEventHandler → \(installStatus)")
            return nil
        }

        var registered: OpaquePointer?
        // EventHotKeyID {signature: 'PTR1', id: 1}, bit-packed (see above).
        let hotKeyID = UInt64(0x5054_5231) | (UInt64(1) << 32)
        let registerStatus = register(keyCode, carbonModifiers, hotKeyID, target, 0, &registered)
        guard registerStatus == 0, registered != nil else {
            plog("carbon hotkey unavailable: RegisterEventHotKey → \(registerStatus)")
            _ = removeHandler?(installedHandler)
            return nil
        }

        self.handlerRef = installedHandler
        self.hotKeyRef = registered
        plog("carbon hotkey registered")
    }

    func invalidate() {
        if let ref = hotKeyRef {
            _ = unregister?(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            _ = removeHandler?(ref)
            handlerRef = nil
        }
    }

    deinit {
        invalidate()
    }
}
