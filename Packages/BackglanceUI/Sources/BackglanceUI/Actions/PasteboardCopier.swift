import AppKit

// MARK: - PasteboardWriting

/// The three `NSPasteboard` operations ``PasteboardCopier`` needs, behind a seam —
/// mirrors ``AppLaunching``'s role for `OpenAction` and `NSWorkspace`.
///
/// A real `NSPasteboard` is safe to use directly even in ordinary tests: a private
/// named instance (`NSPasteboard(name:)`) cannot affect anything outside itself,
/// unlike `NSWorkspace.open` actually opening a URL. This seam exists for one
/// narrower reason — `CopyActionTests` needs to exercise
/// ``ActionError/pasteboardFailure``, the case where the pasteboard refuses a
/// write, and a real `NSPasteboard` offers no supported way to force that from a
/// single-threaded unit test: it only happens when another process steals
/// ownership between `declareTypes` and `setString`, a race no synchronous test
/// can construct. A fake conformance can simply return `false`.
///
/// `NSPasteboard`'s own `clearContents()`, `declareTypes(_:owner:)` and
/// `setString(_:forType:)` already match this shape exactly, so it conforms
/// through the empty `extension` below rather than a wrapper type like
/// `NSWorkspaceAppLauncher` — there is no renaming or repackaging to do, unlike
/// `AppLaunching`, whose methods rename and reshape what `NSWorkspace` offers.
public protocol PasteboardWriting {
    @discardableResult
    func clearContents() -> Int

    @discardableResult
    func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner: Any?) -> Int

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

// MARK: - NSPasteboard + PasteboardWriting

extension NSPasteboard: PasteboardWriting {}

// MARK: - PasteboardCopier

/// The one function every copy Backglance performs goes through, so the concealed
/// marker cannot be forgotten by a call site that only remembers to write the text.
/// See docs/security/SECURITY.md#concealed-pasteboard-copies.
///
/// `CopyAction` is the only caller today, but the type lives on its own rather than
/// as a private helper inside it: docs/security/SECURITY.md is explicit that "every
/// copy Backglance performs" — the digest's copy button included, once it ships —
/// goes through this one function, and a shared, independently named type is what
/// makes that true by construction rather than by every future call site
/// remembering to import `CopyAction` and reach through it.
enum PasteboardCopier {
    /// nspasteboard.org convention: clipboard managers that honor this type do not
    /// record the item. The value written for it is irrelevant; presence of the type
    /// itself is the whole signal.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Writes `text` to `pasteboard` as plain string, concealed.
    ///
    /// - Parameter pasteboard: docs/security/SECURITY.md's sketch hardcodes
    ///   `NSPasteboard.general`. This takes the pasteboard as a parameter instead,
    ///   defaulting to `.general`, so `CopyActionTests` can pass a private named
    ///   pasteboard (`NSPasteboard(name:)`) and never touch — let alone clobber —
    ///   whatever the developer running the suite happens to have on their real
    ///   clipboard at the time. Production call sites never override the default.
    ///   Typed as ``PasteboardWriting`` rather than concrete `NSPasteboard` only so
    ///   the one test that needs to force a refusal can do so; every real caller
    ///   still hands it an actual `NSPasteboard`.
    /// - Returns: `false` if the pasteboard refused either write — rare, but
    ///   possible if another process holds the pasteboard locked at the instant of
    ///   the call. `declareTypes` must run before either `setString` call: a
    ///   pasteboard that has not declared a type refuses to accept a value for it.
    ///   And both writes must succeed for the copy to count — `&&`, not "write the
    ///   text and hope the marker followed" — because a text write that lands
    ///   without its concealed marker sitting beside it is exactly the failure this
    ///   function exists to prevent: a clipboard manager that would have skipped a
    ///   marked item now records the notification text anyway.
    @discardableResult
    static func copyConcealed(_ text: String, to pasteboard: any PasteboardWriting = NSPasteboard.general) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        let wroteText = pasteboard.setString(text, forType: .string)
        let wroteMarker = pasteboard.setString("", forType: concealedType)
        return wroteText && wroteMarker
    }
}
