#!/bin/bash
# nanoPod real-app end-to-end smoke.
# Builds (unless --skip-build), launches the signed nanoPod.app, drives Apple
# Music via osascript, asserts from JSONL events. Mutes for the run and
# restores volume + playback even on failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec python3 "$ROOT/scripts/e2e_smoke.py" "$@"
