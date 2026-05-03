#!/usr/bin/env python3
"""Project wrapper for the global Codex harness."""

from __future__ import annotations

import os
import runpy
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GLOBAL_HARNESS = Path.home() / ".codex" / "harness" / "bin" / "codex_harness.py"

os.environ["CODEX_PROJECT_DIR"] = str(PROJECT_ROOT)
runpy.run_path(str(GLOBAL_HARNESS), run_name="__main__")
