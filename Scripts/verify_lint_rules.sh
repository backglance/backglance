#!/usr/bin/env bash
#
# Proves the privacy lint rules actually bite.
#
# 🔒 A custom SwiftLint rule is a regex, and a regex that matches nothing passes silently
# and forever. This repository has already had that happen: an earlier version of
# `no_notification_content_in_logs` keyed on the literal `logger.`, which no call site in
# Backglance uses, so the invariant went unenforced while every run reported zero
# violations. `swiftlint --strict` being green is evidence that the code is clean *or* that
# the rules are dead, and nothing distinguishes the two.
#
# So: write code that must be rejected, and check that it is. Each case below is a real
# accident — a body interpolated into a log line, a notification stringified, a whole value
# dropped into a message, a Turkish-breaking fold, a disable comment on a privacy rule — and
# the run fails if SwiftLint lets any of them through.
#
# Run from the repository root. CI runs it beside `swiftlint --strict`
# (docs/deployment/CI_CD.md); the pre-commit hook does not, because it takes a second.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "swiftlint not found — install it with 'brew install swiftlint'" >&2
    exit 1
fi

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

failures=0

# expect_violation <rule-id> <swift source>
#
# Writes the source somewhere the rules apply — not under a path matching `.*Tests.*`,
# which every privacy rule excludes — and asserts the named rule fires on it.
expect_violation() {
    local rule="$1"
    local source="$2"
    local file="$workspace/Sources/Case_${rule}.swift"

    mkdir -p "$workspace/Sources"
    printf '%s\n' "$source" >"$file"

    local output
    output="$(swiftlint lint --config "$PWD/.swiftlint.yml" --quiet --no-cache "$file" 2>/dev/null || true)"

    if printf '%s' "$output" | grep -q "$rule"; then
        echo "  ok       $rule"
    else
        echo "  FAILED   $rule did not fire on:"
        printf '%s\n' "$source" | sed 's/^/             /'
        failures=$((failures + 1))
    fi

    rm -f "$file"
}

echo "Verifying the privacy lint rules reject what they are supposed to reject:"

expect_violation no_notification_content_in_logs \
    'func leak(_ notification: ArchivedNotification) { Log.capture.error("failed: \(notification.body)") }'

expect_violation no_string_describing_notification \
    'func leak(_ notification: ArchivedNotification) { let text = String(describing: notification); _ = text }'

expect_violation no_notification_interpolation_in_logs \
    'func leak(_ notification: ArchivedNotification) { Log.capture.debug("saw \(notification)") }'

expect_violation no_locale_sensitive_case_folding \
    'func fold(_ text: String) -> String { text.lowercased(with: Locale(identifier: "tr_TR")) }'

expect_violation no_silencing_privacy_rules \
    '// swiftlint:disable:next no_notification_content_in_logs
func leak(_ notification: ArchivedNotification) { Log.capture.error("\(notification.body)") }'

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures rule(s) are not enforcing anything. A green 'swiftlint --strict' means nothing until this passes." >&2
    exit 1
fi

echo "All privacy lint rules are live."
