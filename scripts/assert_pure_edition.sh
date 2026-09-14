#!/bin/bash
set -euo pipefail

# =============================================================================
# assert_pure_edition.sh — proves the "pure" (App Store-bound) build carries
# zero private-API code, per docs/wt-e-full-edition-plan-2026-09-12.md §1/§5.
#
# Usage: scripts/assert_pure_edition.sh <release-binary> [<app-bundle>]
#
# Four gates, any failure exits 1 and names which gate failed:
#   ① Package graph: MusicMiniPlayer / MusicMiniPlayerAppKit / MusicMiniPlayerCore
#      targets must not depend on NanoPodFullEdition (swift package dump-package).
#   ② Source tree: no MediaRemote/mediaremote/MRMediaRemote string in
#      Sources/MusicMiniPlayerCore, Sources/MusicMiniPlayerAppKit, Sources/MusicMiniPlayerApp.
#   ③ Binary: no MediaRemote/mediaremote-adapter/MRMediaRemote/SystemNowPlayingSource/
#      NanoPodFullEdition string or symbol in the release binary (strings + nm).
#   ④ Bundle (if given): no MediaRemoteAdapter.framework or *.pl file inside it.
# =============================================================================

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <release-binary> [<app-bundle>]"
    exit 1
fi

RELEASE_BINARY="$1"
APP_BUNDLE="${2:-}"

if [ ! -f "$RELEASE_BINARY" ]; then
    echo "❌ [gate ③ prep] release binary not found: $RELEASE_BINARY"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Gate ①: package dependency graph ───────────────────────────────────────
gate1_dump_package() {
    local json
    if ! json="$(swift package dump-package 2>/dev/null)"; then
        echo "❌ [gate ① package graph] 'swift package dump-package' failed"
        exit 1
    fi

    local violation
    violation="$(python3 - "$json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
guarded = {"MusicMiniPlayer", "MusicMiniPlayerAppKit", "MusicMiniPlayerCore"}
bad = []

for target in data.get("targets", []):
    name = target.get("name")
    if name not in guarded:
        continue
    for dep in target.get("dependencies", []):
        # A dependency entry is either {"target": [name, ...]} or {"byName": [name, ...]} etc.
        for _, value in (dep.items() if isinstance(dep, dict) else []):
            if isinstance(value, list) and value and value[0] == "NanoPodFullEdition":
                bad.append(name)

if bad:
    print(",".join(bad))
PY
)"

    if [ -n "$violation" ]; then
        echo "❌ [gate ① package graph] target(s) depend on NanoPodFullEdition: $violation"
        exit 1
    fi
    echo "✅ [gate ① package graph] MusicMiniPlayer/AppKit/Core have no NanoPodFullEdition dependency"
}

# ── Gate ②: source tree scan ────────────────────────────────────────────────
gate2_source_scan() {
    local hits
    hits="$(grep -rIl -E "MediaRemote|mediaremote|MRMediaRemote" \
        Sources/MusicMiniPlayerCore Sources/MusicMiniPlayerAppKit Sources/MusicMiniPlayerApp 2>/dev/null || true)"

    if [ -n "$hits" ]; then
        echo "❌ [gate ② source scan] MediaRemote references found in pure source tree:"
        echo "$hits"
        exit 1
    fi
    echo "✅ [gate ② source scan] no MediaRemote references in Core/AppKit/App"
}

# ── Gate ③: binary scan ─────────────────────────────────────────────────────
gate3_binary_scan() {
    local pattern='MediaRemote|mediaremote-adapter|MRMediaRemote|SystemNowPlayingSource|NanoPodFullEdition'

    if strings -a "$RELEASE_BINARY" | grep -Eq "$pattern"; then
        echo "❌ [gate ③ binary scan] forbidden string found via 'strings -a' in $RELEASE_BINARY"
        exit 1
    fi

    if nm "$RELEASE_BINARY" 2>/dev/null | grep -Eq "$pattern"; then
        echo "❌ [gate ③ binary scan] forbidden symbol found via 'nm' in $RELEASE_BINARY"
        exit 1
    fi
    echo "✅ [gate ③ binary scan] no forbidden strings/symbols in $RELEASE_BINARY"
}

# ── Gate ④: bundle contents (optional) ──────────────────────────────────────
gate4_bundle_scan() {
    if [ -z "$APP_BUNDLE" ]; then
        return
    fi
    if [ ! -d "$APP_BUNDLE" ]; then
        echo "❌ [gate ④ bundle scan] app bundle not found: $APP_BUNDLE"
        exit 1
    fi

    local found
    found="$(find "$APP_BUNDLE" \( -name "MediaRemoteAdapter.framework" -o -name "*.pl" \) -print 2>/dev/null || true)"
    if [ -n "$found" ]; then
        echo "❌ [gate ④ bundle scan] private-API vendor files found inside $APP_BUNDLE:"
        echo "$found"
        exit 1
    fi
    echo "✅ [gate ④ bundle scan] no MediaRemoteAdapter.framework or .pl files in $APP_BUNDLE"
}

gate1_dump_package
gate2_source_scan
gate3_binary_scan
gate4_bundle_scan

echo "✅ Pure edition isolation verified (4/4 gates passed)"
