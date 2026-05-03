# Data-Driven Spec

When adding project rules:

- Prefer `rules.yaml` or `phases.yaml`.
- Extend `scripts/verify_harness.py` only for general checks.
- Avoid hardcoded one-off policy in source code unless it is product behavior.

This keeps the harness portable across Codex, Claude Code, and future local agents.
