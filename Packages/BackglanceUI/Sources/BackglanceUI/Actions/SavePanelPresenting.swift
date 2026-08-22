import AppKit
import BackglanceCore
import Foundation
import UniformTypeIdentifiers

// MARK: - SavePanelPresenting

/// The one `NSSavePanel` operation ``NotificationActionHandler/exportSelection(_:format:)`` needs,
/// behind a seam — mirrors ``AppLaunching``'s role for `OpenAction` and `NSWorkspace`.
///
/// A real `NSSavePanel` in a test would block the suite on a modal window: `runModal()` opens an
/// actual dialog and does not return until a human dismisses it, which is a hang, not a failure.
/// Every other AppKit-touching action in this coordinator already has exactly this shape — see
/// ``AppLaunching``'s doc comment for the fuller argument — and `NSSavePanel` gets the same
/// treatment for the same reason: a fake conformance in `Tests/BackglanceUITests` records what it
/// was asked and returns a scripted `URL?`, so ``NotificationActionHandler/exportSelection(_:format:)``
/// can be tested for "cancel writes no file and throws nothing" and "confirm writes exactly this
/// file" without a save panel ever appearing on screen.
///
/// `@MainActor` because `NSSavePanel.runModal()` is a main-thread API, matching
/// ``NotificationActionHandler`` itself and every other seam in this directory.
@MainActor
public protocol SavePanelPresenting {
    /// Runs the panel and returns the chosen destination, or `nil` when the user cancelled.
    ///
    /// `nil` is not an error — see docs/features/ACTIONS.md#edge-cases-and-error-handling,
    /// "Export cancelled in the save panel". The caller's job is to treat it exactly like any
    /// other cancelled confirmation: return quietly, write nothing.
    ///
    /// - Parameters:
    ///   - suggestedName: the panel's starting filename —
    ///     ``ExportSheet/defaultFilename(for:day:)``'s result in production.
    ///   - format: which file type the real conformance restricts the panel to. Passed alongside
    ///     `suggestedName` instead of being folded into it, so a fake can assert the two
    ///     independently rather than parsing an extension back out of a string.
    func runModal(suggestedName: String, format: ExportFormat) -> URL?
}

// MARK: - NSSavePanelPresenter

/// The real conformance: builds and runs an actual `NSSavePanel`. This is what
/// `NotificationActionHandler`'s default initializer wires in; only tests ever construct a
/// different ``SavePanelPresenting``.
public struct NSSavePanelPresenter: SavePanelPresenting {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func runModal(suggestedName: String, format: ExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [format.contentType]
        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }
}

// MARK: - ExportFormat + contentType

extension ExportFormat {
    /// `UTType.commaSeparatedText` / `.json` — what `NSSavePanel.allowedContentTypes` restricts
    /// the picker to, and what stamps the extension back on if the user edits the suggested name
    /// field down to nothing but a base name.
    var contentType: UTType {
        switch self {
        case .csv:
            .commaSeparatedText

        case .json:
            .json
        }
    }
}
