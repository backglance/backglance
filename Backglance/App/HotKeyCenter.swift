import AppKit
import Carbon.HIToolbox
import os

// MARK: - HotKeyCenter

/// The global ⌃⌥N shortcut that opens the popover from anywhere.
///
/// Carbon's `RegisterEventHotKey` rather than a modern API because there is no
/// modern equivalent: `NSEvent.addGlobalMonitorForEvents` needs Accessibility
/// permission and cannot swallow the key stroke, and `KeyboardShortcuts` in
/// SwiftUI only fires while the app is frontmost — which an agent app with no
/// windows never is. Carbon's API is old, still supported, and the only one
/// that does the job without asking the user for another permission
/// (docs/architecture/ARCHITECTURE.md#app-shell-backglance-target).
///
/// Registration can fail, and the usual reason is mundane: another app already
/// owns ⌃⌥N. That is not an error worth an alert — the status item still works
/// — so the failure becomes a flag Settings can read and explain, and the app
/// carries on.
@MainActor
final class HotKeyCenter {
    // MARK: Lifecycle

    /// - Parameter handler: run on the main actor when the shortcut fires.
    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    deinit {
        // The handler and the event target outlive `self` unless they are torn
        // down explicitly: Carbon holds raw pointers, not references.
        MainActor.assumeIsolated {
            unregister()
        }
    }

    // MARK: Internal

    /// Whether ⌃⌥N is currently ours.
    ///
    /// Settings shows a note when this is `false`, because a shortcut that
    /// silently does nothing reads as a broken app rather than as a conflict
    /// with something else the user installed.
    private(set) var isRegistered = false

    /// Registers ⌃⌥N. Idempotent; safe to call again after a failure.
    func register() {
        guard !isRegistered else {
            return
        }
        guard installDispatcher() else {
            return
        }
        claimShortcut()
    }

    /// Releases the shortcut and the event handler. Safe to call when nothing
    /// was registered.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        Self.handlers.removeValue(forKey: Self.hotKeyID)
        isRegistered = false
    }

    // MARK: Private

    /// `'BGLA'` — the four-character signature Carbon identifies our hot keys
    /// by, so a callback meant for another app's shortcut is ignored.
    private static let signature = OSType(0x4247_4C41)
    private static let hotKeyID: UInt32 = 1

    /// Carbon's callback is a C function pointer and cannot capture context, so
    /// the handler is looked up by hot-key id instead.
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]

    private let handler: @MainActor () -> Void
    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "ui")

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static func fire(_ id: UInt32) {
        handlers[id]?()
    }

    /// Installs the Carbon event handler every hot key is delivered through.
    ///
    /// - Returns: whether the handler is in place.
    private func installDispatcher() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The dispatcher is installed once and keyed by hot-key id, so a second
        // shortcut later (there is none yet) needs no second handler.
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, identifier.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon calls back on the main thread, but it does not know
                // that, so the hop is explicit rather than assumed.
                Task { @MainActor in HotKeyCenter.fire(identifier.id) }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else {
            logger.error("hotkey event handler not installed: \(installStatus, privacy: .public)")
            return false
        }
        return true
    }

    /// Asks the system for ⌃⌥N itself.
    private func claimShortcut() {
        let identifier = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(controlKey | optionKey),
            identifier,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            // Almost always "someone else has this shortcut". Log the code, not
            // an alert: the status item is still there, and Settings explains it.
            logger.notice("hotkey registration refused: \(registerStatus, privacy: .public)")
            unregister()
            return
        }

        Self.handlers[Self.hotKeyID] = handler
        isRegistered = true
        logger.notice("hotkey registered")
    }
}
