import BackglanceCore
import SwiftUI

// MARK: - ExportSheet

/// The confirmation sheet behind context-menu item 10, **Export Selection…**
/// (docs/features/ACTIONS.md#select-and-export).
///
/// This is the v1.0 subset only. docs/features/EXPORT_AUTOMATION.md#ui-components describes a
/// fuller `ExportSheet` — date-range presets (Today / Last 7 days / Last 30 days / All / Custom),
/// an app filter, an estimated row count, and a progress overlay for exports that run past
/// 400 ms — but that document's own Feature Overview table marks every one of those v1.x, next to
/// "Export selected notifications (CSV/JSON) from the timeline", which is checked for v1.0. This
/// view is deliberately just the two things v1.0 actually ships: a format choice and the one
/// warning that has to be said before anything is written. The rest is left for the v1.x task
/// that owns EXPORT_AUTOMATION.md's date-range sheet, rather than guessed at here.
///
/// Deliberately does not touch `NSSavePanel` or `ExportService` itself — it only reports the
/// chosen format through ``onExport``. The host
/// (``NotificationActionHandler/exportSelection(_:format:)``) runs the save panel and the export
/// after that callback fires, which is what keeps "nothing is written until the user confirms"
/// true in exactly one place, rather than this view and its host each having to agree to honor
/// it independently.
public struct ExportSheet: View {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - selectionCount: how many notifications were selected when Export Selection… was
    ///     chosen — drives ``title(count:)``'s singular/plural phrasing. Not re-derived from
    ///     anything else this view owns, since it owns no selection state itself.
    ///   - onExport: fired by the Export… button with whichever format the picker is set to. The
    ///     sheet's job ends here — running the save panel and the export itself belongs to
    ///     whatever handed this view its ``onExport`` closure.
    ///   - onCancel: fired by the Cancel button.
    public init(
        selectionCount: Int,
        onExport: @escaping (ExportFormat) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectionCount = selectionCount
        self.onExport = onExport
        self.onCancel = onCancel
    }

    // MARK: Public

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            formatPicker
            warning
            redactionNote
            buttons
        }
        .padding(20)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("export.sheet")
    }

    // MARK: Internal

    /// "Export 1 Notification" / "Export 3 Notifications" — this sheet's title.
    ///
    /// Two `String(localized:)` calls, one per branch, rather than an interpolated count left to
    /// a string catalog's plural variants: the same trade ``UndoToastView/message(count:)`` makes
    /// and for the same reason — `Backglance/Resources/Localizable.xcstrings` has no entries yet,
    /// and this package's tests have no host application for a catalog entry to resolve against
    /// even if it did.
    ///
    /// A `static func`, not a computed property on the view, so ``ExportSheetTests`` can assert
    /// the exact copy for `1` and for `n` without standing up a SwiftUI hierarchy — the same shape
    /// `UndoToastView.message(count:)` uses.
    static func title(count: Int) -> String {
        if count == 1 {
            String(localized: "Export 1 Notification")
        } else {
            String(localized: "Export \(count) Notifications")
        }
    }

    /// `Backglance-export-<yyyy-MM-dd>.<ext>`, per docs/features/ACTIONS.md#select-and-export's
    /// sketch. `day` is the day the export is happening, not any date carried by the selection
    /// itself — a selection can span any range of `delivered_at` values, or a single one, so there
    /// is no one date in the rows themselves this name could mean instead.
    ///
    /// - Parameter day: defaults to `.now` for production call sites; tests pass a fixed date so
    ///   the expected string does not depend on when the suite happens to run.
    static func defaultFilename(for format: ExportFormat, day: Date = .now) -> String {
        "Backglance-export-\(dayStamp.string(from: day)).\(format.fileExtension)"
    }

    // MARK: Private

    /// `yyyy-MM-dd`, locale-fixed the same way ``CopyAction``'s own timestamp formatter is: a
    /// filename is exactly the kind of fixed-format string that must not turn into non-ASCII
    /// digits or a non-Gregorian calendar under a locale that defaults to either.
    private static let dayStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @State private var format: ExportFormat = .csv

    private let selectionCount: Int
    private let onExport: (ExportFormat) -> Void
    private let onCancel: () -> Void

    private var header: some View {
        Text(Self.title(count: selectionCount))
            .font(.title3.weight(.semibold))
            .accessibilityIdentifier("export.title")
    }

    private var formatPicker: some View {
        Picker(String(localized: "Format"), selection: $format) {
            Text(String(localized: "CSV")).tag(ExportFormat.csv)
            Text(String(localized: "JSON")).tag(ExportFormat.json)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("export.formatPicker")
        .accessibilityLabel(String(localized: "Export format"))
    }

    /// 🔒 docs/features/EXPORT_AUTOMATION.md's Security callout, said verbatim and before the
    /// save panel ever opens: an export file is plaintext and lives outside Backglance's `0700`
    /// directory the moment it is written.
    private var warning: some View {
        Label(
            String(localized: "This file will contain notification text in plain text."),
            systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("export.warning")
    }

    /// docs/features/ACTIONS.md#select-and-export: "Redacted bodies export the placeholder." Said
    /// here too, since it is the other thing worth knowing before the panel opens — an OTP
    /// redacted at capture time was never written to the archive (Privacy Invariant #2), so the
    /// exported file cannot contain it either, only the placeholder that stands in for it.
    private var redactionNote: some View {
        Text(String(localized: """
        Redaction placeholders (like “[code redacted]”) export as-is — the original text \
        was never stored.
        """))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("export.redactionNote")
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("export.cancel")
            Button(String(localized: "Export…")) {
                onExport(format)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("export.export")
            .accessibilityLabel(Self.title(count: selectionCount))
        }
    }
}

// MARK: - ExportFormat + fileExtension

extension ExportFormat {
    /// The extension `NSSavePanel`'s suggested filename ends in — `csv` / `json`. Matches
    /// ``ExportFormat/rawValue`` exactly today, but kept as its own property rather than reusing
    /// `rawValue` directly at each call site: a filename extension and a wire-format identifier
    /// are two different questions that only happen to share an answer right now, and
    /// ``SavePanelPresenting``'s `contentType` reads better next to a same-shaped sibling than
    /// next to `rawValue`.
    var fileExtension: String {
        rawValue
    }
}

// MARK: - Previews

#Preview("Single selection") {
    ExportSheet(selectionCount: 1, onExport: { _ in }, onCancel: {})
}

#Preview("Multiple selection") {
    ExportSheet(selectionCount: 3, onExport: { _ in }, onCancel: {})
}
