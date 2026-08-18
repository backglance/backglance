# Cost Estimation

Last Updated: 2026-08-18

Backglance is a free, GPL-3.0, local-only app built by one person, so this document is short by design: it lists every cost the project has, shows why the total stays around $120–130 per year, and explains the one budget that actually needs watching — GitHub Actions macOS minutes. It exists so that "free forever" is a checkable claim, not a slogan: anyone can read this and see there is no infrastructure whose bill could one day force a business model.

## Table of Contents

- [Principles](#principles)
- [Fixed yearly costs](#fixed-yearly-costs)
- [GitHub Actions macOS minutes](#github-actions-macos-minutes)
  - [The free-tier math](#the-free-tier-math)
  - [Estimated monthly usage](#estimated-monthly-usage)
  - [When it would exceed the free tier](#when-it-would-exceed-the-free-tier)
  - [Mitigations](#mitigations)
- [Things that cost nothing](#things-that-cost-nothing)
- [Optional tooling](#optional-tooling)
- [Hardware](#hardware)
- [Time cost (the honest one)](#time-cost-the-honest-one)
- [Yearly total](#yearly-total)
- [Related Documentation](#related-documentation)

## Principles

- **Near-zero infrastructure by design.** No server, no CDN, no analytics, no crash-reporting service, no email service, no database hosting. The app is local-only, distribution is GitHub Releases + Homebrew, and the update feed is a static XML file on GitHub Pages. Every one of those choices was made partly *because* it removes a recurring bill.
- **Nothing scales with users.** A thousand users and a million users cost the project the same: the bandwidth is GitHub's, the compute is the user's Mac. This is what makes free-forever credible (see [ROADMAP.md](./ROADMAP.md)).
- **The only metered resource is CI.** Watch it; everything else is a flat fee or free.

## Fixed yearly costs

| Item | Cost | Notes |
|---|---|---|
| Apple Developer Program | **$99 / year** | Required for Developer ID signing and notarization. The single unavoidable cost of distributing outside the Mac App Store. |
| Domain `backglance.app` | **~$15–20 / year** | `.app` registration (registrar-dependent; `.app` requires HTTPS, which GitHub Pages provides free). ⚠️ Registration is still an open pre-launch check — see [README.md](../../README.md). Until confirmed, the appcast stays on `https://backglance.github.io/backglance/appcast.xml`. |

That is the entire fixed budget.

## GitHub Actions macOS minutes

CI runs on GitHub-hosted macOS runners (`macos-14`, `macos-15`, `macos-26` — see [CI_CD.md](../deployment/CI_CD.md)). GitHub's free tier for a personal/org account is generous for Linux but tight for macOS.

> ℹ️ **Info:** Public repositories get free GitHub-hosted runner minutes without a monthly cap on standard runners. The math below is the conservative case — it treats the repo as if the private-repo free tier applied, so the project stays viable even if it ever had to run from a private mirror, and because macOS runner queue times make minute discipline worthwhile regardless.

### The free-tier math

- Free tier: **2,000 minutes/month** (Free plan, private repos).
- macOS runners bill at a **10× multiplier**: 1 wall-clock macOS minute consumes 10 billed minutes.
- Effective budget: **2,000 / 10 = 200 macOS wall-clock minutes per month**.

### Estimated monthly usage

Assumptions: a PR build (`ci.yml`: build + unit tests, single runner) takes ~12 wall-clock minutes; the fixture matrix (`fixtures.yml`: 3 runners × ~8 min) takes ~24 runner-minutes per run; a release (`release.yml`: build, sign, notarize wait, appcast, ~25 min) is rare.

| Workflow | Trigger | Wall-clock min/run | Runs/month (est.) | macOS min/month |
|---|---|---|---|---|
| `ci.yml` | Every PR push (after path filter) | 12 | 20 | 240 |
| `fixtures.yml` | Nightly, 3-OS matrix | 24 | 30 | 720 |
| `release.yml` | Per tag | 25 | 1 | 25 |
| `cask-bump.yml` | Per release (runs on Linux) | 2 (Linux, 1×) | 1 | ~0 |
| **Total** | | | | **~985 macOS min/month** |

### When it would exceed the free tier

~985 macOS minutes/month is ~5× the conservative 200-minute budget — so under private-repo rules this would cost real money (roughly $0.08/min × ~785 excess ≈ $60+/month). As a **public repo it costs $0**, which is one more structural reason the repo stays public. The number still matters: it is the threshold to keep in mind if CI grows (UI test matrices multiply fast) and the reason for the mitigations below.

### Mitigations

Applied in this order if minutes ever become a constraint (or queues become slow):

1. **Path filters** — docs-only changes (`docs/**`, `*.md`) skip `ci.yml` entirely.
2. **Concurrency cancellation** — `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }` so force-pushes don't stack builds.
3. **Nightly-only fixtures** — `fixtures.yml` runs on schedule and on capture-code paths only, never on every PR; the 3-OS matrix is the expensive part.
4. **Single-OS PR builds** — PRs build on `macos-26` only; the full matrix runs nightly and pre-release.
5. **Self-hosted Mac runner** — last resort: a Mac mini at the developer's desk registered as a self-hosted runner costs electricity, not minutes. Kept as an option, not a plan, because self-hosted runners on a public repo need careful isolation (fork PRs never run on it).

## Things that cost nothing

| Service | Cost | Used for |
|---|---|---|
| GitHub (public repo) | $0 | Code, issues, Discussions, Releases (unlimited public bandwidth), Actions on public repos |
| GitHub Pages | $0 | Sparkle appcast (`gh-pages` branch), later mirrored at `backglance.app` |
| Notarization | $0 | Included in the Apple Developer Program; no per-submission fee |
| Homebrew | $0 | `backglance/homebrew-tap` is just another public repo; homebrew-cask core is free too |
| Sparkle, GRDB.swift | $0 | Open-source dependencies via SPM |
| Servers, CDN, analytics, crash reporting, email service | $0 | **None exist.** There is nothing to pay for because there is nothing running. |

> 💡 **Tip:** Releases are served by GitHub's CDN. Even a very good launch day costs the project nothing in bandwidth.

## Optional tooling

None of these are required; listed so the "total" is honest about what the developer may personally pay for:

| Tool | Cost | Status |
|---|---|---|
| Xcode | $0 | Required, free |
| SwiftLint / swift-format | $0 | Open source, in CI |
| A DB browser (e.g. free tier of a SQLite GUI) | $0 | `sqlite3` CLI covers it anyway |
| Paid design app for icon/screenshots | $0–50 one-time | Optional; icon can ship from free tools |
| Password manager / 2FA for the Apple ID and signing keys | typically already owned | Not a project cost |

## Hardware

Test coverage needs macOS 14, 15, and 26, on Apple silicon and (best-effort) Intel.

- **Use existing Macs.** The developer's own machines plus CI runners cover the matrix; no hardware purchases are budgeted.
- Where a physical OS version is missing, a spare APFS volume or an external SSD with a second macOS install fills the gap for $0–40 (one-time, if an SSD is even needed).
- Intel coverage relies on CI runners plus community testers, consistent with "best-effort" in the [OS compatibility table](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Time cost (the honest one)

The real cost of Backglance is not money. The v1.0 plan is **6–8 weeks of one person's part-time work** ([ROADMAP.md](./ROADMAP.md)), followed by an ongoing tax that money cannot pay:

- **Adapter maintenance** ⚠️ — every macOS release, and some point releases, can change the undocumented store schema. Budget: a day or two per macOS release for fingerprinting, fixture updates, and an adapter patch.
- **Issue triage and Discussions** — a few hours a week once there are users.
- **Release overhead** — signing, notarizing, appcast, cask bump are scripted (`Scripts/`), so a release is under an hour, but it is still an hour.

This is stated plainly because it is the actual sustainability question for a free project. The mitigation is scope: the app is deliberately small, the CI catches store changes automatically, and everything releasable is scripted.

## Yearly total

| Item | Yearly cost |
|---|---|
| Apple Developer Program | $99 |
| Domain `backglance.app` | ~$15–20 |
| GitHub, Actions (public repo), Pages, Homebrew, notarization | $0 |
| Servers / CDN / analytics / crash reporting / email | $0 (none exist) |
| **Total** | **~$114–119, call it ~$120–130/year** with registrar fees and currency wobble |

Roughly the price of the Developer Program plus a domain. If both lapsed, users could still build from source ([SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md)) — which is the final backstop that keeps "free forever" true regardless of any budget.

## Related Documentation

- [ROADMAP.md](./ROADMAP.md)
- [FAQ.md](./FAQ.md)
- [CI_CD.md](../deployment/CI_CD.md)
- [DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md)
- [PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md)
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md)
- [README.md](../../README.md)
