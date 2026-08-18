# Legal & Compliance

Last Updated: 2026-08-18

Backglance archives notification content — private messages, mail subjects, calendar details — on the user's own Mac. This document covers the data-protection view of that (GDPR and KVKK), what the GPL-3.0 license requires and grants for the fully-free single-repo model, dependency license compatibility, the trademark-versus-license distinction, export control, and the full text of the privacy policy that will go on the website.

> ⚠️ **Warning:** This document is written by a solo developer, not a lawyer. It reflects a good-faith reading of the legal texts as of the Last Updated date. It is **not legal advice**; legal texts and their application should be verified by qualified counsel, especially before any company deployment.

## Table of Contents

- [Data protection: GDPR and KVKK](#data-protection-gdpr-and-kvkk)
  - [Who is the controller?](#who-is-the-controller)
  - [The household exemption](#the-household-exemption)
  - [Backglance the software is not a processor](#backglance-the-software-is-not-a-processor)
  - [What changes if a company deploys it](#what-changes-if-a-company-deploys-it)
  - [Data subject rights map to features](#data-subject-rights-map-to-features)
  - [CloudKit sync (v1.x)](#cloudkit-sync-v1x)
- [License: GPL-3.0](#license-gpl-30)
  - [What GPL-3.0 requires of the project](#what-gpl-30-requires-of-the-project)
  - [What GPL-3.0 grants users](#what-gpl-30-grants-users)
  - [Contributor terms](#contributor-terms)
  - [Dependency license compatibility](#dependency-license-compatibility)
  - [Notarization and Apple Developer Program terms](#notarization-and-apple-developer-program-terms)
- [Trademark versus license](#trademark-versus-license)
  - [Trademark policy](#trademark-policy)
  - [Open pre-launch checks](#open-pre-launch-checks)
- [Export control](#export-control)
- [Privacy Policy](#privacy-policy)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Data protection: GDPR and KVKK

Backglance stores personal data — often other people's personal data, since a message notification contains the sender's name and words. The GDPR (EU) and the KVKK (Türkiye's Kişisel Verilerin Korunması Kanunu, Law No. 6698) are the two regimes considered here, KVKK because Turkish users, and a Turkish-law reading, are explicitly in scope.

### Who is the controller?

For a personal installation, **the user is the controller** of the archive, in the same sense that they are for their own mailbox, their Messages history, or a photo library. Backglance is a tool the user runs on their own device to organize data that macOS already delivered to them; the user alone decides what is kept (exclusions), for how long (retention), and when it is erased (delete, wipe).

### The household exemption

Both regimes carve personal, non-professional use out of scope:

- **GDPR Art. 2(2)(c):** the Regulation does not apply to processing "by a natural person in the course of a purely personal or household activity."
- **KVKK Art. 28(1)(a):** the law does not apply where personal data is processed by natural persons "within the scope of activities related to themselves or family members living in the same residence," provided the data is not disclosed to third parties.

A private individual archiving their own notifications on their own Mac, sharing them with no one, is squarely the case these exemptions describe. Two honest caveats:

1. The exemption is read narrowly by courts (the CJEU's *Lindqvist* and *Ryneš* line): publishing archived content, or using the archive for professional purposes, can take the activity out of the exemption.
2. These are our readings of the texts. **Verify with counsel** before relying on them in any dispute, and see the warning at the top of this document.

### Backglance the software is not a processor

A processor (GDPR Art. 4(8); KVKK "veri işleyen") processes personal data *on behalf of* a controller. Backglance the software — and the project that publishes it — does neither:

- No processing happens on our side. There is no server, no account, no telemetry, no crash-reporting service. The developer never receives, stores, or can access any user's archive or any notification content.
- Nothing is transmitted to us. The only network connection in v1.0 is the Sparkle update check against a static file host, and the user can disable it (see [`./SECURITY.md`](./SECURITY.md)).
- Consequently there is no data-processing agreement to sign with us, because there is no processing relationship. Distributing software is not processing the data that software later touches on someone else's machine.

### What changes if a company deploys it

If an employer installs Backglance on work Macs, the analysis changes completely:

- **The employer becomes the controller** for archived notification content on those machines, which includes employees' private messages if personal accounts are signed in. The household exemption does not apply to a business.
- The employer then owes the usual controller duties — lawful basis, transparency to employees, records of processing, and in many jurisdictions a works-council or employee-representative conversation before deploying anything that could function as monitoring. Employee-monitoring law is strict in the EU and in Türkiye; **counsel is not optional here.**
- Backglance's features help a careful deployment: per-app **exclusion** (never store Messages/Mail at all), **retention** limits (24 h or 7 d instead of 30 d), **OTP redaction**, and the fact that the archive stays on the employee's own machine, readable only by that user account, with nothing reported to the employer.

> ℹ️ **For IT admins:** v1 has no MDM support — no managed preferences domain, no configuration profile keys, no remote policy. Every setting is per-user in `app.backglance.Backglance` defaults. If you need centrally enforced exclusions or retention before deploying, that is a v1.x-or-later conversation; open a discussion on the repo. Until then, treat Backglance as a user-installed personal tool, not a fleet tool.

### Data subject rights map to features

For a personal installation the "data subject" and the "controller" are usually the same person, but the rights map cleanly onto features, which is also what makes a corporate deployment tractable:

| Right | GDPR | Feature |
|---|---|---|
| Access | Art. 15 | The timeline itself; search; export of any date range |
| Erasure | Art. 17 | Per-notification delete, per-app delete, panic wipe, retention auto-pruning, exclusion list (prevents storage at all) |
| Portability | Art. 20 | CSV and JSON export (`ExportService`) — structured, machine-readable |
| Rectification | Art. 16 | Not applicable in practice: the archive is a historical record of what was delivered; the remedy for a wrong record is deletion |
| Restriction / objection | Arts. 18, 21 | Pause capture; per-app exclusion; mute |

KVKK Art. 11 enumerates closely corresponding rights; the same feature map applies.

### CloudKit sync (v1.x)

> ℹ️ **Status:** Planned for v1.x — not in v1.0. Opt-in, off by default.

When the user enables sync, the archive's content fields travel through **the user's own iCloud account**. Apple acts as the user's service provider under Apple's own iCloud terms and data-processing commitments — the user's relationship with Apple, not ours; we still receive nothing. Content fields are stored in CloudKit's end-to-end encrypted `encryptedValues`, so Apple holds ciphertext for those fields; residual metadata (app bundle IDs, timestamps, counts) is visible to Apple as ordinary CloudKit fields. Details in [`./SECURITY.md`](./SECURITY.md) and [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md). A user subject to GDPR who enables sync is choosing Apple as their provider for that copy; Apple publishes its own GDPR documentation for iCloud.

## License: GPL-3.0

Backglance is licensed under the **GNU General Public License, version 3** (`LICENSE` at the repo root). One repo, one license, no dual licensing, no CLA, no "open core" — the entire app is free software. Copyright line: `Copyright (C) 2026 the Backglance authors`.

### What GPL-3.0 requires of the project

As the copyright holder and distributor of binaries, the obligations are:

| Obligation | How it is met |
|---|---|
| Source availability (§6) | The complete corresponding source is the public repo, `https://github.com/backglance/backglance`; every release binary corresponds to a tag. Distributing the DMG from GitHub Releases alongside the source repo satisfies §6 |
| License and copyright notices (§§4–5) | `LICENSE` at the root; per-file headers in source; the About window shows the license and links the repo |
| State changes (§5a) | Release tags + `CHANGELOG.md` |
| No additional restrictions (§10) | The DMG carries no EULA, no anti-reverse-engineering clause, no field-of-use limits. Nothing narrows the GPL |
| Installation information (§6, "User Products") | Building and running from source is documented (`docs/getting-started/DEVELOPMENT_GUIDE.md`); no hardware lockdown is involved, so Anti-Tivoization terms are trivially satisfied |

Because the copyright on the original code is held by the project's authors, the GPL binds *recipients*; a copyright holder cannot "violate" the licence against themselves. The obligations above are what make the distribution honest and the license enforceable downstream.

### What GPL-3.0 grants users

Everyone who receives Backglance may:

- **Use** it for anything, personal or commercial, no license key, no seat count.
- **Study** it — the source is the documentation of what the FDA permission is used for, which is a security property as much as a freedom (see [`./SECURITY.md`](./SECURITY.md)).
- **Modify** it and run modified versions privately with no obligations at all (obligations attach to *distribution*, not use).
- **Redistribute** it, modified or not, source or binaries, **including commercially** — selling GPL binaries is explicitly permitted. Whoever redistributes must pass on the complete corresponding source (or a §6 written offer) and the license text, keep notices intact, and add no further restrictions.

> ✅ **Do:** Fork it, port it, ship your own build, even charge for it — just pass on the source and the license, and pick your own name (see [Trademark versus license](#trademark-versus-license)).

### Contributor terms

- **Inbound = outbound:** contributions are accepted under GPL-3.0, the same license the project ships under. No CLA — contributors keep their copyright; the project is a commons, and no one, the maintainer included, acquires the right to relicense other people's contributions proprietarily.
- **DCO sign-off:** every commit carries a Developer Certificate of Origin sign-off, i.e. `git commit -s`, adding a `Signed-off-by:` line certifying you have the right to submit the work under the project license. CI checks for the line. Details in [`../contributing/CONTRIBUTING.md`](../contributing/CONTRIBUTING.md).

### Dependency license compatibility

Everything linked into the binary must be GPL-3.0-compatible. It is:

| Dependency | License | GPL-3.0 compatible | Notes |
|---|---|---|---|
| GRDB.swift 7.x | MIT | ✅ | Permissive; the combined work ships as GPL-3.0 |
| Sparkle 2.7.x | MIT | ✅ | Same |
| SQLCipher (v1.x, via `GRDB.swift/SQLCipher`) | BSD-3-Clause | ✅ | Permissive; BSD notice preserved in the About window credits |
| Apple frameworks (AppKit, SwiftUI, Foundation, NaturalLanguage, CloudKit, …) | Proprietary system libraries | ✅ via System Library exception | GPL-3.0 §1's "System Libraries" definition excludes them from the corresponding-source requirement; linking a GPL app against the OS's own frameworks is the normal, accepted case |
| System SQLite | Public domain | ✅ | Also a system library |

No GPL-incompatible dependency (e.g. anything with an advertising clause, CDDL, or a noncommercial restriction) may be added; the dependency-review step in [`../contributing/CONTRIBUTING.md`](../contributing/CONTRIBUTING.md) checks license before code. For comparison inside the developer's own projects: PasteShelf is AGPL-3.0 and VaulType is GPL-3.0; no code is shared by linking — the ported search engine code in `BackglanceSearch` was relicensed by its author (same person) for this repo, which a sole copyright holder may do.

### Notarization and Apple Developer Program terms

Signing and notarizing the official binary happens under the Apple Developer Program License Agreement. That agreement governs the maintainer's use of Apple's signing service; **it does not change the software's license.** The notarized DMG is still GPL-3.0, with full source available, and nothing in the notarization process adds restrictions to what recipients may do with the code. Forks that want their own notarized builds sign with their own Developer ID; unsigned/self-signed builds from source work too (Gatekeeper right-click-open, or `spctl` exceptions the user controls). This is distinct from the Mac App Store, whose terms *have* historically conflicted with GPL distribution — moot here, since Backglance cannot be on the App Store anyway (Full Disk Access is incompatible with App Sandbox).

## Trademark versus license

The GPL licenses the **code**, not the **name or logo**. These are separate legal regimes and keeping them separate is what lets a free-software project still have a trustworthy official build:

- Anyone may take the code, modify it, and ship it — the license guarantees that.
- No one may ship a fork in a way that implies it is the official Backglance — that is a trademark/passing-off question, untouched by the GPL (GPL-3.0 §7e even anticipates declining to grant trademark rights).

This matters for security: users verify the official build by name, Team ID, and download source (see [`./SECURITY.md`](./SECURITY.md)). A fork called "Backglance" with an identical icon would defeat that verification even if its code were honest.

### Trademark policy

Plain-language policy (the website will carry this text):

**Permitted without asking:**

- Redistributing **unmodified official builds** under the name Backglance (mirrors, the Homebrew cask, download sites) — please link the GitHub release.
- Describing a fork as **"based on Backglance"** or "a Backglance fork," with its own name and icon.
- Nominative use: articles, reviews, tutorials, package metadata, comparisons.

**Not permitted:**

- Naming a modified build "Backglance," "Backglance Pro," or anything confusingly similar.
- Using the Backglance icon, or an official-looking variant, for a non-official build.
- Implying endorsement by, or origin from, the Backglance project for a modified build.

> 💡 **Tip:** The test is honest confusion: could a reasonable user think your build is the official one? If yes, rename. If you're unsure, open an issue and ask — the answer will usually be yes with a small change.

### Open pre-launch checks

Still open as of the Last Updated date:

- [ ] Trademark clearance search for "Backglance": **USPTO** (TESS) and **EUIPO** (eSearch), plus **TÜRKPATENT**. A clearance search before launch is cheap; a rename after launch is not.
- [ ] Registration decision (unregistered marks still get passing-off/unfair-competition protection in most places, but registration strengthens the policy above).
- [ ] `backglance.app` **domain registration** — referred to throughout the docs but not yet confirmed live; `security@backglance.app` and the appcast move both wait on it.

## Export control

Backglance v1.0 implements no cryptography of its own; it uses only OS-provided facilities (TLS via the system, FileVault, Keychain), which places it outside meaningful export-control concern for a mass-market app. The v1.x SQLCipher option adds a bundled open-source cryptographic library; publicly available open-source encryption source code is generally not subject to the EAR (per the published-source provisions, with at most a notification email for some classifications), and mass-market distribution provisions cover the rest.

> ⚠️ **Warning:** Export-control classification is hedged deliberately: rules differ by the distributor's country and by the hosting jurisdiction (GitHub's infrastructure is US-hosted), and they change over time. Before the SQLCipher build ships in official binaries, this section gets a proper review.

## Privacy Policy

Full text, ready to paste at `https://backglance.app/privacy` once the domain is live. It is intentionally short because there is intentionally little to disclose.

---

**Backglance Privacy Policy**

*Effective: 2026-08-17*

**The short version.** Backglance runs entirely on your Mac. We — the developer — receive nothing: no notification content, no analytics, no crash reports, no account, no identifiers. This policy is short because there is almost nothing to disclose.

**What the app collects and sends to us.** Nothing. Backglance has no server, no telemetry, and no account system. We have no way to see your notifications, your app list, your settings, or whether you use the app at all.

**What the app stores on your Mac.** Backglance keeps an archive of the notifications macOS delivers to you — app, title, subtitle, body, sender, timestamps, and attachment metadata (names and sizes, never the files themselves) — in `~/Library/Application Support/Backglance/`, readable only by your macOS user account. You control it: per-app exclusions prevent storage entirely, retention limits delete old notifications automatically (default: 30 days), one-time codes from Messages and Mail are redacted by default before anything is written, and "Wipe archive" erases everything. Settings are stored in macOS user defaults, and a small technical log (never containing notification content) is kept at `~/Library/Logs/Backglance/`.

**Network access.** In normal use Backglance makes exactly one kind of network request: checking for app updates via the Sparkle framework. When update checks are enabled, your Mac periodically fetches a small file (the "appcast") from our update host. Like any web request, this reveals your IP address and a user-agent string containing the app version and Sparkle version, from which your macOS version can be inferred. The update files are currently hosted on GitHub Pages; GitHub may keep standard server logs of these requests under GitHub's own privacy policy — we do not receive or read such logs, and we host no analytics. You can turn update checks off in Settings ▸ Updates, and Backglance then makes **no network connections at all**. We treat that as a guarantee, and you can verify it yourself with `lsof`.

**iCloud sync (future, opt-in).** A planned version will optionally sync your archive between your own Macs using your own iCloud account. It will be off by default. If you enable it, data goes to Apple's CloudKit service under your agreement with Apple; notification content will be stored in CloudKit's end-to-end encrypted fields, which Apple cannot read, while basic metadata (app identifiers, timestamps) is handled as standard iCloud data. We still receive nothing.

**Third parties.** There are no third-party SDKs for analytics, ads, or crash reporting — the app's only dependencies are the open-source GRDB (database) and Sparkle (updates) libraries, and the complete source code is public at `https://github.com/backglance/backglance`, so all of the above is verifiable.

**Children.** Backglance is a general-purpose utility and collects no data from anyone, of any age.

**Contact.** Questions: open an issue at `https://github.com/backglance/backglance` or email `privacy@backglance.app` (once the domain is live; until then, GitHub). Security reports: see the project's security policy.

**Changes.** If this policy ever changes — for example when iCloud sync ships — the new version will be posted at this address with a new effective date, and the change will be noted in the app's release notes. The core commitment will not change: Backglance's developer does not collect your data.

---

## Next Steps

- Complete the trademark searches and the `backglance.app` registration listed in [Open pre-launch checks](#open-pre-launch-checks), then move the privacy policy and `security@backglance.app` live.
- Have counsel sanity-check the household-exemption reading and the trademark policy text before 1.0.0.
- Revisit [Export control](#export-control) before the SQLCipher build ships.

## Related Documentation

- [`./SECURITY.md`](./SECURITY.md)
- [`../features/PERMISSIONS_PRIVACY.md`](../features/PERMISSIONS_PRIVACY.md)
- [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md)
- [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md)
- [`../features/EXPORT_AUTOMATION.md`](../features/EXPORT_AUTOMATION.md)
- [`../contributing/CONTRIBUTING.md`](../contributing/CONTRIBUTING.md)
- [`../deployment/PACKAGING_NOTARIZATION.md`](../deployment/PACKAGING_NOTARIZATION.md)
- [`../getting-started/DEVELOPMENT_GUIDE.md`](../getting-started/DEVELOPMENT_GUIDE.md)
- [`../reference/FAQ.md`](../reference/FAQ.md)
- [`../../README.md`](../../README.md)
- [`../../LICENSE`](../../LICENSE)
