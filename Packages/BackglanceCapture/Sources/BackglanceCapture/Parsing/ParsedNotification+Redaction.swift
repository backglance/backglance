import BackglanceCore
import Foundation

public extension ParsedNotification {
    /// The three fields a one-time code can arrive in.
    var redactableContent: OTPRedactor.Content {
        OTPRedactor.Content(title: title, subtitle: subtitle, body: body)
    }

    /// Runs the redactor over this notification's text, in memory.
    ///
    /// 🔒 The result is what gets inserted; the receiver is discarded. Privacy Invariant #2
    /// is about *ordering* — this has to happen before `Archive.insert`, not after, because
    /// "after" means the digits were already written to the archive, the FTS index and the
    /// write-ahead log, and deleting a row does not unwrite them.
    ///
    /// The adapter lives here rather than in `BackglanceCore` because `ParsedNotification`
    /// is this module's type and the dependency only points one way
    /// (docs/architecture/ARCHITECTURE.md#dependency-graph). The redactor stays free of
    /// anything capture-shaped, which is also what lets it be tested against plain strings.
    func redactingOTP(with redactor: OTPRedactor = .default) -> (ParsedNotification, RedactionEvent?) {
        let result = redactor.redact(redactableContent)
        guard let event = result.event else {
            return (self, nil)
        }
        var redacted = self
        redacted.title = result.content.title
        redacted.subtitle = result.content.subtitle
        redacted.body = result.content.body
        return (redacted, event)
    }
}
