#!/usr/bin/env python3
"""
[INPUT]: .agents/harness manifests and AGENTS.md
[OUTPUT]: Harness installation verification report
[POS]: Project harness verifier for Codex sessions
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

REQUIRED = [
    ".agents/harness/README.md",
    ".agents/harness/rules.yaml",
    ".agents/harness/phases.yaml",
    ".agents/harness/agents/research.md",
    ".agents/harness/agents/implement.md",
    ".agents/harness/agents/check.md",
    ".agents/harness/specs/documentation.md",
    ".agents/harness/specs/verification.md",
    ".agents/harness/specs/data-driven.md",
]

REQUIRED_AGENTS_PATTERNS = [
    r"\.agents/harness/README\.md",
    r"scripts/verify_harness\.py",
    r"protected lyric animation",
]


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def main() -> int:
    missing = [path for path in REQUIRED if not (ROOT / path).is_file()]
    if missing:
        fail("missing harness files: " + ", ".join(missing))

    agents = ROOT / "AGENTS.md"
    if not agents.is_file():
        fail("AGENTS.md is missing")

    text = agents.read_text(encoding="utf-8")
    missing_patterns = [
        pattern for pattern in REQUIRED_AGENTS_PATTERNS
        if re.search(pattern, text, re.IGNORECASE) is None
    ]
    if missing_patterns:
        fail("AGENTS.md missing harness references: " + ", ".join(missing_patterns))

    rules = (ROOT / ".agents/harness/rules.yaml").read_text(encoding="utf-8")
    for required_rule in [
        "no-private-apis",
        "no-known-liquid-glass-recursion",
        "no-unverified-lyric-renderer-change",
        "no-raw-git-push",
    ]:
        if required_rule not in rules:
            fail(f"rules.yaml missing {required_rule}")

    print("OK: Codex harness installed and referenced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
