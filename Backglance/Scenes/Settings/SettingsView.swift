import BackglanceUI
import SwiftUI

// MARK: - SettingsView

/// Settings, as far as this milestone has settings.
///
/// Three sections today. Search, because semantic indexing is the first thing
/// the app does that needs the user's permission in the plain sense: it reads
/// every notification they have ever received and writes a vector for each one.
/// Digest, which owns the app's only permission prompt — switching banners on is
/// what asks for Notifications authorization, and nothing else in Backglance
/// asks for anything. And one-time code redaction, which is on before the user
/// gets here and so has to be findable. The rest of the privacy controls join it
/// in a Privacy pane in the same milestone, at which point this becomes a
/// `TabView` (docs/getting-started/DEVELOPMENT_GUIDE.md#backglanceui).
struct SettingsView: View {
    // MARK: Internal

    @Bindable var search: SearchService

    let digest: DigestSettingsModel

    let redaction: CodeRedactionSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Semantic search"), isOn: $search.semanticEnabled)
                    .disabled(!search.isSemanticAvailable)

                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = search.indexProgress {
                    SemanticIndexProgress(done: progress.done, total: progress.total)
                }

                Button(String(localized: "Delete embeddings")) {
                    search.deleteEmbeddings()
                }
                .disabled(search.indexProgress == nil && !search.semanticEnabled)
            } header: {
                Text(String(localized: "Search"))
            }

            DigestSettingsView(model: digest)

            CodeRedactionSettingsView(model: redaction)
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 260)
    }

    // MARK: Private

    /// The honest version, not the marketing one: what it does, what it costs,
    /// and what it cannot do (docs/features/SEARCH.md#what-semantic-search-cannot-do).
    private var explanation: String {
        guard search.isSemanticAvailable else {
            return String(localized: """
            The on-device English sentence model isn't available on this Mac. \
            Semantic search is off; full-text search still works.
            """)
        }
        return String(localized: """
        Finds notifications by meaning as well as by wording — "the message about the invoice" \
        rather than the exact words. Everything is computed on this Mac and stored in your archive, \
        about 2 KB per notification. The model is English, so other languages fall back to \
        full-text search.
        """)
    }
}

// MARK: - Preview

#Preview {
    Text(verbatim: "Settings")
        .frame(width: 460, height: 200)
}
