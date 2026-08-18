# Security Policy

Last Updated: 2026-08-18

The full threat model and security architecture live in [docs/security/SECURITY.md](docs/security/SECURITY.md).

## Reporting a vulnerability

Please report privately, not in a public issue:

1. Use GitHub's **private vulnerability reporting** on this repository (Security ▸ Report a vulnerability).
2. Once `backglance.app` is live, `security@backglance.app` will be an alternative channel.

You can expect acknowledgement within 72 hours and a fix target of 30 days for confirmed issues, coordinated disclosure, and credit unless you prefer otherwise. There is no bounty programme.

## Supported versions

The latest released minor version receives security fixes. See [docs/security/SECURITY.md](docs/security/SECURITY.md#supported-versions) for details.

## What is in scope

Backglance stores private notification content locally. Anything that causes notification content to leave the Mac, appear in logs or diagnostics, survive a wipe, or become readable by another user on the same Mac is in scope — as is any weakness in update verification. Details, including what is out of scope, are in [docs/security/SECURITY.md](docs/security/SECURITY.md).

## Related Documentation

- [docs/security/SECURITY.md](docs/security/SECURITY.md) — full threat model, at-rest encryption, secure coding practices
- [docs/security/LEGAL_COMPLIANCE.md](docs/security/LEGAL_COMPLIANCE.md) — GDPR/KVKK posture, GPL-3.0 obligations, privacy policy
- [docs/features/PRIVACY_CONTROLS.md](docs/features/PRIVACY_CONTROLS.md) — retention, OTP redaction, panic wipe
- [docs/operations/MONITORING_LOGGING.md](docs/operations/MONITORING_LOGGING.md) — what logs and diagnostics contain
