import BackglanceCore
import Foundation

// MARK: - Archiving one record

/// One store record's journey into the archive, and the app-row bookkeeping that goes
/// with it — including the name, because Apple's store knows an app by its bundle
/// identifier and nothing else, and a timeline built from the store alone would say
/// `com.apple.MobileSMS` where a person would say "Messages".
///
/// See docs/features/CAPTURE.md#redaction-triage-enrichment.
extension CaptureEngine {
    /// Parse, exclude, redact, enrich, insert — for one record.
    ///
    /// The order is the privacy model, not a preference:
    ///
    /// 1. **Exclusion first, on the raw row.** `RawStoreRecord.appIdentifier` comes from
    ///    the store's own `app` table, so an excluded app's payload is never decoded into
    ///    objects at all. A password manager's notification does not become a `String` in
    ///    this process.
    /// 2. **Then parse**, and check exclusion *again* against the parsed bundle id: the
    ///    payload's own `app` key can differ from the joined row for helper processes and
    ///    iPhone Mirroring, and the app the user excluded is the one the payload names.
    /// 3. **Upsert the app row**, which carries the per-app `redact_otp` the next step
    ///    is gated on. A bundle id, and nothing the user typed or received.
    /// 4. **Redact before any content is written**, in memory and irreversibly.
    /// 5. **Enrich**, then insert the notification.
    ///
    /// One record's failure never stops the batch, and never reaches the user: it is
    /// counted, and logged by `rec_id` and a fixed reason.
    func archiveOne(_ raw: RawStoreRecord, source: ArchivedNotification.Source) async -> ArchiveOutcome {
        guard exclusions.allows(raw.appIdentifier) else {
            return .excluded
        }

        do {
            let parsed = try parser.parse(raw)
            guard exclusions.allows(parsed.bundleID) else {
                return .excluded
            }

            // The app row first, because it carries `redact_otp` — the per-app half of
            // whether the next line runs at all. It holds no notification content, so
            // writing it before the redaction is not a violation of "redact before
            // anything is written": what that rule is about is the *text*, and the text
            // is still only in memory here.
            let now = Date()
            let app = try archive.upsertApp(bundleID: parsed.bundleID, now: now)
            guard let appID = app.id else {
                Log.capture.error("archive rec \(raw.recID): app row has no id")
                return .failed
            }

            await recordDisplayName(for: app)

            let (redacted, redaction) = redactor.redact(parsed, appRedactsOTP: app.redactOtp)
            let enriched = await enrichment.enrich(redacted)

            let outcome = try archive.insertOrUpdate(
                ArchivedNotification(
                    parsed: enriched,
                    appID: appID,
                    storeRecID: raw.recID,
                    source: source,
                    capturedAt: now
                ),
                redaction: redaction
            )

            switch outcome {
            case .inserted:
                return .archived

            case .updated:
                return .updated

            case .duplicate:
                return .duplicate
            }
        } catch ArchiveError.duplicate {
            // The import and live capture overlapping. Expected, and not worth a line.
            return .duplicate
        } catch let error as CaptureError {
            Log.capture.error("skip rec \(raw.recID): \(error.logDescription)")
            return .failed
        } catch let error as ArchiveError {
            Log.capture.error("archive rec \(raw.recID): \(error.logDescription)")
            return .failed
        } catch {
            Log.capture
                .error("rec \(raw.recID): \(String(describing: type(of: error)))")
            return .failed
        }
    }

    /// Keeps `apps.display_name` in step with what the app calls itself.
    ///
    /// Runs per record rather than per app because the engine holds no per-app state
    /// across ticks, and it is cheap enough to: the enricher memoizes the Launch Services
    /// lookup, and ``Archive/setDisplayName(_:bundleID:)`` writes only when the name has
    /// actually changed. So the first notification from an app costs one resolution and
    /// one update, and every notification after it costs a dictionary lookup and a
    /// comparison.
    ///
    /// Because it compares rather than fills in a blank, a rename is picked up too — an
    /// app that updated, or a user who switched their system language.
    ///
    /// A failure here is not a failure to archive. The notification is already worth
    /// keeping; a missing name costs the timeline a bundle id in place of "Messages".
    func recordDisplayName(for app: AppRecord) async {
        guard
            let name = await enrichment.displayName(forBundleID: app.bundleId),
            name != app.displayName
        else {
            return
        }
        do {
            try archive.setDisplayName(name, bundleID: app.bundleId)
        } catch let error as ArchiveError {
            Log.capture.error("display name for \(app.bundleId): \(error.logDescription)")
        } catch {
            Log.capture.error("display name for \(app.bundleId): \(String(describing: type(of: error)))")
        }
    }
}
