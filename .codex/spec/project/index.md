# Project Spec

Durable project knowledge for Codex sessions.

Use this folder for rules that should survive conversation compaction:

- architecture decisions
- recurring failure modes
- project-specific testing commands
- file ownership and module boundaries
- release or operational procedures

## Specs

- `lyrics-pipeline.md`: lyrics result taxonomy, fallback selection, and verifier semantics.
- `lyrics-renderer-performance.md`: protected lyrics UX, verified performance fixes, and profiling gates.
- `owner-diagnostics.md`: local owner debug diagnostics boundary, report model, privacy rules, and retention/media policy.

## Pre-Development Checklist

- Check this index for relevant project rules.
- Add task-specific context to `implement.jsonl` and `check.jsonl` instead of relying on memory.

## Quality Check

- If the task taught a durable lesson, add or update a focused spec file here.
