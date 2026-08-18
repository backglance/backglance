# Contributing to Backglance

Last Updated: 2026-08-18

Thank you for considering a contribution. Backglance is a small, free, GPL-3.0 macOS app maintained by one person, and it reads an undocumented system database — which means contributions are very welcome and a few rules are non-negotiable, mostly around test fixtures and personal data. This document covers the legal terms, how to find something to work on, the pull request process, the fixture requirements for adapter and parser changes, and what to honestly expect from review. The repository root `CONTRIBUTING.md` is a symlink to this file.

## Table of Contents

- [License and contribution terms](#license-and-contribution-terms)
- [Code of conduct](#code-of-conduct)
- [Development setup](#development-setup)
- [Finding something to work on](#finding-something-to-work-on)
- [Branches and commits](#branches-and-commits)
- [Pull request process](#pull-request-process)
- [Testing requirements](#testing-requirements)
- [Adapter and parser changes require fixtures](#adapter-and-parser-changes-require-fixtures)
- [Contributing a fixture for a new macOS](#contributing-a-fixture-for-a-new-macos)
- [Reporting an OS break](#reporting-an-os-break)
- [Security issues](#security-issues)
- [Documentation contributions](#documentation-contributions)
- [Review expectations](#review-expectations)
- [Releases](#releases)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## License and contribution terms

Backglance is licensed under the **GNU General Public License v3.0** ([LICENSE](../../LICENSE)). Contribution terms are the simplest ones that exist:

- **Inbound = outbound.** By submitting a contribution you license it under GPL-3.0, the same license you received the code under. Nothing more.
- **No CLA.** There is no contributor license agreement and there never will be one. You keep your copyright; the project gets a GPL-3.0 license to your work, exactly like everyone else.
- **DCO sign-off.** Every commit must carry a `Signed-off-by:` line certifying the [Developer Certificate of Origin 1.1](https://developercertificate.org) — that you wrote the change or otherwise have the right to submit it under GPL-3.0. `git commit -s` adds the line:

  ```
  Signed-off-by: Alex Example <alex@example.com>
  ```

  Use a real name and a reachable address. CI checks for the trailer; a PR with unsigned commits gets a bot comment with the `git rebase --signoff` one-liner to fix it.

- **Documentation is GPL-3.0 too.** Everything under `docs/` is licensed with the code, under the same license, with the same inbound = outbound terms. No separate docs license.

Do not contribute code you copied from a source whose license is incompatible with GPL-3.0, and do not contribute decompiled or disassembled Apple code. Descriptions of *observed* store behaviour (schemas seen via `sqlite3 .schema`, keys seen in your own notifications' plists) are fine; that observation process is the documented one in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Code of conduct

This project follows the [Contributor Covenant, version 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). The short version: be kind, be patient, assume good faith, criticize code and not people, and remember that "the maintainer" is one person answering issues after work. Reports of unacceptable behaviour go to conduct@backglance.app (or, until the domain is confirmed, via GitHub's report feature on the repo); they will be handled privately. Enforcement is at the maintainer's discretion, up to and including a ban from the project's spaces.

## Development setup

Full instructions live in getting-started; the short path:

1. [QUICK_START.md](../getting-started/QUICK_START.md) — clone, `Scripts/bootstrap.sh`, build, run against a fixture in about ten minutes, no Full Disk Access needed.
2. [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md) — signing, FDA for real capture, environment variables, fixture setup, troubleshooting.
3. [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md) — package layout, style, naming, git workflow, review checklist, everyday commands.

Requirements: macOS 14+, Xcode 16.2+ (Xcode 26.x recommended). You do **not** need FDA, an Apple Developer account, or a paid anything to build, test, and contribute — the entire test suite runs on synthetic fixtures.

> 💡 **Tip:** `Scripts/bootstrap.sh` installs the git hooks, including the pre-commit hook that refuses to commit anything that looks like a real system store. Run it before your first commit.

## Finding something to work on

Issues at https://github.com/backglance/backglance/issues are labelled to help you pick:

| Label | Meaning |
|---|---|
| `good first issue` | scoped, no capture-layer knowledge needed, maintainer will hand-hold a bit |
| `help wanted` | maintainer would genuinely appreciate someone else taking it |
| `adapter` | touches a `StoreAdapter` — read [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) first; fixture rules below apply |
| `needs-fixture` | blocked on someone with the right macOS version generating a fixture — a valuable contribution that needs no Swift at all |
| `os-break` | capture broken on a macOS release; highest priority |
| `flaky-test`, `perf-regression` | opened by CI; see [TESTING.md](../testing/TESTING.md) |

Before starting anything larger than a small fix, comment on the issue (or open one) and wait for a "go ahead". This is a solo-maintained project with a deliberately small v1.0 scope ([ROADMAP.md](../reference/ROADMAP.md)); features outside the roadmap will likely be declined however well they are built, and it is miserable to decline finished work. Rules in Backglance are visual triage only — PRs that try to make rules change actual system notification delivery will be declined on principle, not on quality.

## Branches and commits

The full workflow is in [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md#git-workflow). Summary:

- Branch from `main`: `feat/…`, `fix/…`, `docs/…`, `chore/…`; rebase on `main`, keep branches short-lived.
- Conventional Commits: `type(scope): imperative summary` with scopes like `capture`, `core`, `search`, `ui`, `digest`, `fixtures`, `docs`.
- PRs are squash-merged; the PR title becomes the commit subject, so write it as a conventional commit.
- Every commit signed off (`git commit -s`, see above).

```bash
git checkout -b fix/digest-short-session main
# ... work ...
git commit -s -m "fix(digest): do not create a digest for away sessions shorter than 5 min"
git push -u origin fix/digest-short-session
gh pr create --fill
```

## Pull request process

Open the PR against `main`. The template asks you to confirm this checklist — it is the same list the maintainer walks through, so an honest self-review here is the fastest path to a merge:

```markdown
## Checklist
- [ ] Tests: new behaviour has tests; the Fast test plan passes locally
      (`xcodebuild test -scheme Backglance -testPlan Backglance -testPlanConfiguration Fast`)
- [ ] Fixtures: if this touches an adapter, RecordParser, StoreFingerprint, or StoreSnapshot,
      fixture coverage is included (new/updated fixture + expected.json) and
      `Scripts/verify_fixture.sh` passes for each affected OS
- [ ] Docs: files under docs/ updated where behaviour, schema, scripts, or env vars changed
- [ ] CHANGELOG.md: entry added under [Unreleased] (Keep-a-Changelog category) if user-visible
- [ ] Privacy: no notification content (title/body/subtitle/sender/userInfo/plistData) in any
      new log line, error message, or test output; no real personal data in tests or fixtures
- [ ] Accessibility: new interactive UI has accessibility labels; VoiceOver order checked
- [ ] All commits are signed off (git commit -s)
```

What happens next:

1. CI runs the matrix (`macos-14`, `macos-15`, `macos-26`), the UI tests, and the `adapter-guard` job. All must be green; a red leg blocks merge.
2. The maintainer reviews against the checklist in [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md#code-review-checklist). Expect concrete requests, not style bikeshedding — formatting is the linters' job.
3. Once approved, the maintainer squash-merges. You do not need to squash yourself; do keep the PR description accurate, because it becomes the commit body.

Small PRs merge fast. A PR that mixes a refactor with a behaviour change will be asked to split.

## Testing requirements

Every PR runs the full functional suite on all three CI runners. Beyond "the tests pass":

- New logic comes with unit tests; changed logic comes with a test that would have failed before the change. [TESTING.md](../testing/TESTING.md) documents where each kind of test lives and how to run it.
- Anything touching the capture path is tested through **fixtures**, never against a real store. A test that constructs a path under `~/Library/Group Containers/` will be rejected in review even if CI would skip it.
- No test may contain a realistic one-time code, a real email address, or a real phone number — synthetic data rules are in the [test data hygiene checklist](../testing/TESTING.md#test-data-hygiene-checklist).
- UI changes need accessibility identifiers so the XCUITests can address them ([ACCESSIBILITY.md](../reference/ACCESSIBILITY.md)).

## Adapter and parser changes require fixtures

> ⚠️ **Warning:** This is the one hard rule in the project. The adapters and `RecordParser` read Apple's undocumented store; the synthetic fixtures are the *only* proof they work. A change to that code without a fixture change is either untested or silently redefining what "correct" means.

**The rule:** any PR touching `Packages/BackglanceCapture/Sources/**/Adapters/**` or `RecordParser` **must** include fixture coverage — a new or updated fixture (`store.db` + `manifest.json` + `expected.json`) under `Tests/Fixtures/SystemStore/` — and must pass `fixtures.yml` on all matrix versions (`macos-14`, `macos-15`, `macos-26`). An updated `expected.json` diff must be explained in the PR description.

CI enforces this mechanically with an `adapter-guard` job in `ci.yml` using `dorny/paths-filter@v3`: if adapter or parser files changed but nothing under `Tests/Fixtures/SystemStore/` did, the job fails.

```yaml
# .github/workflows/ci.yml (excerpt)
  adapter-guard:
    name: Adapter changes carry fixtures
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: dorny/paths-filter@v3
        id: changes
        with:
          filters: |
            adapter:
              - 'Packages/BackglanceCapture/Sources/**/Adapters/**'
              - 'Packages/BackglanceCapture/Sources/**/RecordParser*'
              - 'Packages/BackglanceCapture/Sources/**/StoreFingerprint*'
            fixtures:
              - 'Tests/Fixtures/SystemStore/**'

      - name: Fail if adapter changed without fixture coverage
        if: steps.changes.outputs.adapter == 'true' && steps.changes.outputs.fixtures == 'false'
        run: |
          echo "::error::Adapter/parser files changed but Tests/Fixtures/SystemStore/ did not." \
               "Add or regenerate the affected fixture (Scripts/make_fixture.sh) and its expected.json." \
               "See docs/contributing/CONTRIBUTING.md#adapter-and-parser-changes-require-fixtures"
          exit 1
```

In the rare case an adapter-file change genuinely cannot affect parsing (a comment fix, a rename), say so in the PR; the maintainer can override the guard with an explicit approval, but the default answer is "regenerate the fixture anyway — it is one command and it proves the claim".

## Contributing a fixture for a new macOS

This is one of the most useful contributions a non-Swift contributor can make, because the maintainer only owns so many Macs. When a new macOS (say, the 27 beta) ships, someone running it can produce the fixture that unblocks the adapter work.

> ⚠️ **Warning — never upload a real store.** Do not attach, commit, paste, or privately send your `~/Library/Group Containers/group.com.apple.usernoted/db2/db` file, in whole or in part. It contains your actual message and email previews. Fixtures are generated; the only thing taken from your machine is the schema (DDL — table and column definitions, no rows) and version numbers. `Scripts/verify_fixture.sh` scans the result for anything that looks like a real email, phone number, or one-time code and fails if it finds one, but the scan is a backstop — the process below never touches your data in the first place.

Steps, on a machine running the target macOS:

1. Clone and bootstrap:

   ```bash
   git clone https://github.com/backglance/backglance.git && cd backglance
   Scripts/bootstrap.sh
   ```

2. Grant your terminal FDA temporarily (Settings ▸ Privacy & Security ▸ Full Disk Access). This is needed only to read the store's *schema*; revoke it afterwards.

3. Generate the fixture. `--capture-schema` dumps DDL only (`sqlite3 -readonly … .schema`) and refuses to run if the host macOS does not match `--os`; everything else is generated from the seed:

   ```bash
   Scripts/make_fixture.sh --os 27 --capture-schema --from 26 --seed 20260817 --records 250
   ```

4. Verify — this runs the hygiene scan and the full fingerprint/adapter/parse check:

   ```bash
   Scripts/verify_fixture.sh --os 27
   ```

   On a brand-new schema the adapter step will fail (`no adapter resolved`) — that is expected and exactly the information the maintainer needs. The hygiene section must pass.

5. Check for personal data yourself, beyond the script:
   - Open `Scripts/fixtures/schema_v27.sql` and read it end to end. It must contain only `CREATE TABLE` / `CREATE INDEX` statements and comments — no `INSERT`, no values, nothing from your account.
   - Skim `Tests/Fixtures/SystemStore/macOS27/expected.json`: every sender should be `<Word> Example`, every address `@example.com`, every phone `+1 555 01xx`, every code-looking string inside a template marked `[synthetic-otp]`.
   - Run `strings -n 6 Tests/Fixtures/SystemStore/macOS27/store.db | less` and scan for anything you recognise. There should be nothing.
   - Confirm `manifest.json` `notes` starts with `Synthetic.` and `build` matches `sw_vers -buildVersion`.

6. Revoke the terminal's FDA, then open a PR titled `test(fixtures): add macOS 27 fixture (build <NN>)` containing the three fixture files, the schema SQL, and — in the description — your `sw_vers -productVersion` / `-buildVersion` and whether the schema differs from v26 (the fixture test output shows the fingerprint hash either way).

The maintainer takes it from there: comparing schemas, writing or adjusting `StoreAdapterV27`, and adding the CI leg when a runner image exists. Full playbook: [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Reporting an OS break

If a macOS update breaks capture (menu bar icon shows degraded, timeline stops filling), use the **"OS break"** issue template. It asks for exactly the fields below — and pointedly not for any notification content:

| Field | Where to get it |
|---|---|
| macOS version and build | `sw_vers -productVersion` and `sw_vers -buildVersion` |
| Status fingerprint hash | Backglance ▸ Settings ▸ Status shows the current `StoreFingerprint` schema hash and dbinfo version; copy the hash |
| Adapter id / degraded reason | same Status pane: e.g. `StoreAdapterV26` or `degraded(unknownSchema)` |
| Diagnostics export | Settings ▸ Status ▸ "Export diagnostics…" writes a JSON of version numbers, fingerprint, probe result, capture state, and recent *content-free* log lines — no titles, bodies, senders, or userInfo, by construction ([MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)) |

> ❌ **Don't:** attach your store file, screenshots of your actual notifications, or raw `log show` output (system log lines from *other* processes can contain content). The diagnostics export exists so you never have to.

An `os-break` issue on a supported macOS version is the project's highest priority; see the response targets in [MAINTENANCE.md](../operations/MAINTENANCE.md).

## Security issues

Do **not** open a public issue for anything security-sensitive — a way to read the archive across users, a redaction bypass that leaks codes, a path traversal in export, a Sparkle feed problem. Follow the private reporting process in [SECURITY.md](../security/SECURITY.md) (the root `SECURITY.md` symlinks there). GitHub's private vulnerability reporting is enabled on the repository.

## Documentation contributions

Docs PRs are welcome and are often the best first contribution. Ground rules:

- Docs live under `docs/` and follow the conventions you can infer from any existing file: `Last Updated:` line, table of contents, relative links, a Related Documentation section at the end.
- Terminology is strict: Backglance's database is the **archive**, Apple's is the **store**, the missed-summary is the **digest**, per-version store readers are **adapters**. A docs PR that swaps these will be asked to fix them.
- Anything describing the system store must keep the ⚠️ caveats — never present observed schema details as an API.
- Examples never contain realistic personal data: `example.com`, `+1 555 0100`, `[code redacted]`.
- Docs are GPL-3.0 like everything else; the DCO sign-off applies to docs commits too.

Typos and broken links do not need an issue first — just open the PR.

## Review expectations

Honesty section. Backglance has **one maintainer** with a day job. What that means in practice:

- **Expect days, not hours.** A first response to a PR typically lands within a few days; a full review of a larger PR can take a week or two. A silent week is a queue, not a rejection — feel free to ping after seven days.
- `os-break` issues and security reports jump the queue; everything else is roughly first-in, first-out with small PRs served faster.
- Review effort goes where the risk is: capture, redaction, migrations, and anything touching the store get read line by line; a settings-pane label fix does not.
- There are no other committers to escalate to and no SLA beyond this paragraph. If that cadence does not fit your needs, forking is a legitimate, GPL-protected option — genuinely, no hard feelings.

## Releases

Releases are the maintainer's alone. Only the maintainer tags versions, and only the maintainer's Developer ID certificate signs and notarizes official binaries — this is a security property, not a status one: nobody else's code ships under `app.backglance.Backglance` without passing through the maintainer's review, key, and the release checklist in [DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md). Contributors cannot trigger `release.yml` and are never asked for signing secrets. Your merged work ships in the next tagged release and is credited in [CHANGELOG.md](../../CHANGELOG.md) and the release notes.

## Next Steps

- Set up a build with [QUICK_START.md](../getting-started/QUICK_START.md), then skim [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md).
- Pick a `good first issue`, comment on it, and say hello.
- If you run a macOS beta, check for `needs-fixture` issues — that contribution takes an hour and no Swift.

## Related Documentation

- [README](../../README.md) — what Backglance is
- [License](../../LICENSE) — GPL-3.0
- [Changelog](../../CHANGELOG.md) — Unreleased section your PR adds to
- [Quick Start](../getting-started/QUICK_START.md) — fastest path to a running build
- [Setup Guide](../getting-started/SETUP_GUIDE.md) — full environment setup, FDA, fixtures
- [Development Guide](../getting-started/DEVELOPMENT_GUIDE.md) — conventions, git workflow, review checklist
- [Testing](../testing/TESTING.md) — test strategy, fixtures, hygiene checklist, CI matrix
- [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — adapters, fingerprints, new macOS process
- [Architecture](../architecture/ARCHITECTURE.md) — packages and boundaries
- [Database Schema](../architecture/DATABASE_SCHEMA.md) — archive DDL and migrations
- [CI/CD](../deployment/CI_CD.md) — workflows, matrix, secrets
- [Deployment Guide](../deployment/DEPLOYMENT_GUIDE.md) — releases, signing, notarization
- [Monitoring & Logging](../operations/MONITORING_LOGGING.md) — content-free logging, diagnostics export
- [Maintenance](../operations/MAINTENANCE.md) — issue triage and response targets
- [Security](../security/SECURITY.md) — private vulnerability reporting
- [Roadmap](../reference/ROADMAP.md) — v1.0 scope and what comes later
- [Accessibility](../reference/ACCESSIBILITY.md) — requirements for UI PRs
- [FAQ](../reference/FAQ.md) — common questions
