#!/bin/bash
# Compiles and runs the glass-morph-spike in both animated and control (--no-animation)
# modes, writing JSONL logs + a summary to results/.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
echo "SDK version: $(xcrun --show-sdk-version --sdk macosx)"

mkdir -p results

echo "Compiling..."
swiftc -O -sdk "$SDK" -target arm64-apple-macos26.0 main.swift -o glass-morph-spike 2> results/compile.log
COMPILE_STATUS=$?
if [ $COMPILE_STATUS -ne 0 ]; then
    echo "COMPILE FAILED — see results/compile.log"
    cat results/compile.log
    exit 1
fi
echo "Compiled OK."

run_mode() {
    local mode_name="$1"
    shift
    echo "Running mode=$mode_name ..."
    ./glass-morph-spike "$@" > "results/${mode_name}.jsonl" 2>&1
    echo "  -> results/${mode_name}.jsonl ($(wc -l < "results/${mode_name}.jsonl") lines)"
}

run_mode animated --scenario=1
sleep 1
run_mode no-animation --no-animation --scenario=1
sleep 1
run_mode animated-s2 --scenario=2
sleep 1
run_mode no-animation-s2 --no-animation --scenario=2

{
    echo "# glass-morph-spike results summary"
    echo
    echo "Generated: $(date)"
    echo
    for f in animated no-animation animated-s2 no-animation-s2; do
        echo "## $f"
        echo '```'
        grep '^VERDICT=' "results/${f}.jsonl" || echo "(no VERDICT line found — check results/${f}.jsonl for a crash/hang)"
        echo '```'
        echo
    done
} > results/summary.md

echo "Done. See results/summary.md"
