#!/usr/bin/env bash
#
# Populates Backglance/Resources/Localizable.xcstrings with every user-facing string in
# the app *and* in the four local packages.
#
# Why this script has to exist. `docs/reference/INTERNATIONALIZATION.md` states the design:
# one catalog, at `Backglance/Resources/Localizable.xcstrings`, holding every user-facing
# string. That works at runtime — `String(localized:)` and SwiftUI's `Text("literal")`
# resolve against `Bundle.main` unless a call site says otherwise, and no call site in this
# repository does — but it does not happen on its own at build time:
#
#   * Xcode extracts strings into a catalog only for the target that owns it. Building the
#     app writes the app target's own ~27 keys and nothing else.
#   * A local SwiftPM package is a separate target. `BackglanceUI` declares
#     `defaultLocalization: "en"`, so Xcode extracts its ~349 strings — into a generated
#     `en.lproj/Localizable.strings` inside the *package's* bundle, which nothing ever
#     reads, because the call sites resolve against `Bundle.main`.
#   * `BackglanceCore`, `BackglanceCapture` and `BackglanceSearch` declare no
#     `defaultLocalization` at all, so their strings are not extracted anywhere.
#
# The visible symptom is that the catalog stayed empty while 400+ call sites were written
# against it, and every string rendered correct English purely because a missing key falls
# back to the key itself. That fallback is also why `^[…](inflect: true)` silently produced
# the singular noun for every count: automatic grammar agreement needs the key to be *in*
# the catalog, and the fallback path strips the markup and keeps the literal.
#
# `xcodebuild -exportLocalizations` is the one tool that walks every target, packages
# included, so this script uses it as the extractor and merges what it finds into the one
# catalog the design calls for. Translations already in the catalog are never touched.
#
# Usage:
#   Scripts/sync_string_catalog.sh            # update the catalog in place
#   Scripts/sync_string_catalog.sh --check    # fail if it is out of date (CI)
#
# Run from anywhere; it cd's to the repository root.

set -euo pipefail

cd "$(dirname "$0")/.."

catalog="Backglance/Resources/Localizable.xcstrings"
mode="sync"

if [[ ${1:-} == "--check" ]]; then
    mode="check"
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found — install the Xcode command line tools" >&2
    exit 1
fi

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

echo "Extracting strings from every target (this builds for localization)…"
# -exportLanguage en: we want the source language. The export writes one xliff whose
# <file> groups name the app catalog, the Info.plist catalog and the generated per-package
# strings files — the union of those groups is what belongs in the one catalog.
xcodebuild -exportLocalizations \
    -project Backglance.xcodeproj \
    -localizationPath "$workspace" \
    -exportLanguage en >"$workspace/export.log" 2>&1 || {
    echo "xcodebuild -exportLocalizations failed:" >&2
    tail -30 "$workspace/export.log" >&2
    exit 1
}

xliff="$workspace/en.xcloc/Localized Contents/en.xliff"
if [[ ! -f $xliff ]]; then
    echo "no xliff at $xliff — the export produced nothing to merge" >&2
    exit 1
fi

CATALOG="$catalog" XLIFF="$xliff" MODE="$mode" python3 <<'PY'
import json
import os
import sys
import xml.etree.ElementTree as ET

catalog_path = os.environ["CATALOG"]
xliff_path = os.environ["XLIFF"]
mode = os.environ["MODE"]

NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
# Xcode's own placeholder for "the engineer wrote no comment:" — carrying it into the
# catalog would be noise in every entry, so it is dropped and the key simply has none.
NO_COMMENT = "No comment provided by engineer."

# The Info.plist catalog is a separate file with its own keys (CFBundleName and friends).
# Merging it into Localizable.xcstrings would create keys nothing ever looks up there.
SKIP_FILES = ("InfoPlist.xcstrings",)

tree = ET.parse(xliff_path)
extracted: dict[str, str | None] = {}
for file_node in tree.getroot().findall(".//x:file", NS):
    original = file_node.get("original", "")
    if any(original.endswith(skip) for skip in SKIP_FILES):
        continue
    for unit in file_node.findall(".//x:trans-unit", NS):
        key = unit.get("id")
        if not key:
            continue
        note = unit.findtext("x:note", default="", namespaces=NS).strip()
        comment = None if note in ("", NO_COMMENT) else note
        # First writer wins only for the comment: the same key can legitimately appear in
        # two targets, and one of them may have a translator comment where the other has
        # none. Keep whichever comment exists.
        if key in extracted and extracted[key] is not None:
            continue
        extracted[key] = comment

with open(catalog_path, encoding="utf-8") as handle:
    catalog = json.load(handle)

existing = catalog.get("strings", {})
merged: dict[str, dict] = {}

for key, comment in extracted.items():
    entry = dict(existing.get(key, {}))
    if comment is not None:
        entry["comment"] = comment
    # "manual" rather than one of the "extracted_*" states, and truthfully so: Xcode did
    # not extract these into *this* catalog, this script did. It also keeps Xcode from
    # marking every package string stale the next time someone builds in the IDE.
    entry["extractionState"] = "manual"
    entry.setdefault("localizations", {})
    merged[key] = entry

# A key that has left the source but carries translated values is a translator's work, and
# deleting it would throw that away over a refactor. Keep it and mark it, which is exactly
# what the catalog's "stale" state is for. A key with no translations is just noise.
for key, entry in existing.items():
    if key in merged:
        continue
    if entry.get("localizations"):
        stale = dict(entry)
        stale["extractionState"] = "stale"
        merged[key] = stale

catalog["strings"] = {key: merged[key] for key in sorted(merged)}
catalog.setdefault("sourceLanguage", "en")
catalog.setdefault("version", "1.0")

rendered = json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n"

with open(catalog_path, encoding="utf-8") as handle:
    current = handle.read()

if mode == "check":
    if rendered != current:
        print(
            f"{catalog_path} is out of date — run Scripts/sync_string_catalog.sh",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"{catalog_path} is up to date ({len(merged)} keys).")
    sys.exit(0)

if rendered == current:
    print(f"{catalog_path} already up to date ({len(merged)} keys).")
else:
    with open(catalog_path, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    print(f"{catalog_path} updated: {len(merged)} keys.")
PY
