#!/usr/bin/env python3
from pathlib import Path
import runpy
runpy.run_path(str(Path.home() / ".codex" / "harness" / "bin" / "codex_workflow_state_hook.py"), run_name="__main__")
