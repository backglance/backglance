# Contributing to Backglance

Last Updated: 2026-08-18

The full contribution guide lives in [docs/contributing/CONTRIBUTING.md](docs/contributing/CONTRIBUTING.md).

Short version:

- Backglance is GPL-3.0. Contributions are inbound = outbound under the same license; sign off your commits with `git commit -s` (DCO). There is no CLA.
- Set up a build with [docs/getting-started/QUICK_START.md](docs/getting-started/QUICK_START.md) or the fuller [SETUP_GUIDE.md](docs/getting-started/SETUP_GUIDE.md).
- **Any pull request touching the store adapter layer or the record parser must include fixture coverage.** CI enforces it. See [docs/contributing/CONTRIBUTING.md](docs/contributing/CONTRIBUTING.md) and [docs/testing/TESTING.md](docs/testing/TESTING.md).
- Never attach a copy of a real Notification Center store, or real notification content, to an issue or PR. Fixtures are synthetic.
- Security issues: use GitHub's private vulnerability reporting. See [SECURITY.md](SECURITY.md).

## Related Documentation

- [docs/contributing/CONTRIBUTING.md](docs/contributing/CONTRIBUTING.md) — the full guide
- [docs/getting-started/DEVELOPMENT_GUIDE.md](docs/getting-started/DEVELOPMENT_GUIDE.md) — style, git workflow, debugging capture safely
- [docs/testing/TESTING.md](docs/testing/TESTING.md) — fixtures and the test strategy
- [SECURITY.md](SECURITY.md) · [README.md](README.md) · [CHANGELOG.md](CHANGELOG.md)
