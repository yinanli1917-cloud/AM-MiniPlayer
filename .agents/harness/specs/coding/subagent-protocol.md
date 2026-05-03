# Sub-Agent Protocol

## Dispatch Rules

- Provide full task text + context directly in prompt (never reference files the sub-agent must find)
- Each sub-agent gets exactly what it needs — no more, no less
- If a task has `implement.jsonl`, the hook injects those specs automatically

## Agent Boundaries

| Agent Type | CAN | CANNOT |
|-----------|-----|--------|
| research | Write to `{task}/research/*.md` | Edit code, specs, scripts, git ops |
| implement | Write/edit code, run lint/typecheck | git commit/push/merge, edit specs |
| check | Write/edit code (fixes), run tests | git ops, edit specs, approve own work |

## Status Reporting

Sub-agents report one of:
- **DONE** — proceed to review
- **DONE_WITH_CONCERNS** — read concerns before proceeding
- **NEEDS_CONTEXT** — provide missing info, re-dispatch
- **BLOCKED** — assess: wrong task scope? architectural problem?

## Model Selection

- Mechanical tasks (1-2 files, clear spec) → haiku/sonnet
- Integration/judgment → sonnet
- Architecture/design/review → opus

## Self-Evaluation Ban

Never let an agent evaluate its own output. Use a SEPARATE agent for review.
The implement agent writes code; the check agent verifies it. Never combined.
