# Codex Workflow

This is the Codex-native source of truth for this project. Codex hooks and harness context load it automatically when available; `scripts/codex_harness.py context` is the pull-based fallback.

## Phase Index

```
Phase 1: Plan    -> clarify intent, create PRD, curate context
Phase 2: Execute -> implement and check with the right context
Phase 3: Finish  -> verify, record lessons, complete/archive
```

[workflow-state:no_task]
No active task. Direct Q&A can be answered inline. For implementation, refactor, debugging, research-heavy work, or multi-step project work, create a Codex task first with `python3 scripts/codex_harness.py task create "<title>"`; then write/adjust `prd.md` and curate `implement.jsonl` / `check.jsonl`. User override is per-turn only when the current message explicitly asks to skip task flow.
[/workflow-state:no_task]

[workflow-state:planning]
Planning task is active. Work on `prd.md` until goal and acceptance criteria are clear. Before starting implementation, curate `implement.jsonl` and `check.jsonl` with spec, research, workflow, or design files the implement/check pass needs. The seed `_example` row does not count as curated context. Then run `python3 scripts/codex_harness.py task start <task>`.
[/workflow-state:planning]

[workflow-state:in_progress]
Implementation task is active. Use the active task's `prd.md`, `implement.jsonl`, and `check.jsonl` as the context contract. Prefer bounded subagents for implementation/check when they can work on a clear scope; otherwise work inline with the same context. Before completion, run health plus task-specific checks, update docs/specs if the work changes durable project behavior, then mark complete and archive when done.
[/workflow-state:in_progress]

[workflow-state:completed]
Task is completed. Archive it if no further work remains. If code or docs are still dirty because of this task, finish verification and cleanup before archiving.
[/workflow-state:completed]

## Core Loop

1. **Context** — run `python3 scripts/codex_harness.py context`.
2. **Plan** — for multi-step work, create or resume a task under `.codex/tasks/`.
3. **Execute** — keep edits scoped to the task; use skills when the request matches them.
4. **Verify** — run `python3 scripts/codex_harness.py health` plus task-specific checks.
5. **Archive** — finish and archive task state with timestamps once the work is complete.

## Task Commands

```bash
python3 scripts/codex_harness.py task create "<title>"
python3 scripts/codex_harness.py task create "<title>" --priority P1 --assignee <name> --package <pkg>
python3 scripts/codex_harness.py task start <slug-or-dir>
python3 scripts/codex_harness.py task current
python3 scripts/codex_harness.py task finish [slug-or-dir]
python3 scripts/codex_harness.py task archive <slug-or-dir>
python3 scripts/codex_harness.py task list
python3 scripts/codex_harness.py task set-branch <slug-or-dir> <branch>
python3 scripts/codex_harness.py task set-base-branch <slug-or-dir> <branch>
python3 scripts/codex_harness.py task add-subtask <parent> <child>
python3 scripts/codex_harness.py task add-context <slug-or-dir> implement <path> "<reason>"
python3 scripts/codex_harness.py task add-context <slug-or-dir> check <path> "<reason>"
python3 scripts/codex_harness.py task list-context <slug-or-dir>
python3 scripts/codex_harness.py task validate <slug-or-dir>
python3 scripts/codex_harness.py task agent-context <slug-or-dir> implement
python3 scripts/codex_harness.py task agent-context <slug-or-dir> check
python3 scripts/codex_harness.py spec list
python3 scripts/codex_harness.py spec packages
python3 scripts/codex_harness.py record-session --title "<title>" --summary "<summary>"
python3 scripts/codex_harness.py record-session --title "<title>" --summary "<summary>" --auto-commit
python3 scripts/codex_harness.py finish-work --title "<title>" --summary "<summary>"
python3 scripts/codex_harness.py finish-work --complete --archive --summary "<summary>"
python3 scripts/codex_harness.py finish-work --complete --archive --allow-dirty --summary "<summary>"  # deliberate exception only
python3 scripts/codex_harness.py templates hash-check
```

## Context Contract

`context` prints:

- git state
- active Codex task
- project-specific health summary when available
- durable next actions
- project runtime notes

Subagents should receive the relevant `context` output and, when a task is active, the task's `prd.md`, `implement.jsonl`, and `check.jsonl` contents directly in their prompt.

## Completion Contract

Do not claim task completion until:

- required files are changed
- `python3 scripts/codex_harness.py health` has been run
- task-specific checks have been run
- task status is marked `completed`
- task is archived if no further work remains
- session knowledge is recorded with `finish-work` for substantial work
- template drift is checked when harness/spec files changed
