# Codex Operations Bridge

This file maps the Claude Code harness architecture into operations Codex can actually perform in this repository.

## Claude Hook Mapping

| Claude layer | Codex-local equivalent |
|---|---|
| `session-start.py` | Read `AGENTS.md`, `.agents/harness/README.md`, current git state, active goal summary, and relevant docs before acting. |
| `workflow-reminder.py` | Use `.agents/harness/phases.yaml` as phase-specific reminders during planning, coding, debugging, reviewing, and verifying. |
| `enforce-rules.py` | Run `scripts/verify_harness.py`; inspect `.agents/harness/rules.yaml`; search changed files for risky patterns before staging. |
| `post-tool-check.py` | After failed commands, diagnose the failure path and add evidence to docs or postmortems when the failure changes the plan. |
| `task.py` lifecycle | Use the active Codex goal, `docs/performance_audit_2026-05-03.md`, and commits as the task ledger. |
| `~/.claude/agents/*.md` | Use `.agents/harness/agents/*.md` as bounded research, implementation, and check protocols. |
| `~/.claude/spec/` | Use `.agents/harness/specs/*.md` for reusable verification, documentation, and data-driven expectations. |

Codex cannot execute Claude hooks as callback code. The adaptation is therefore explicit: local manifests plus verifier scripts plus documented gates.

## Keep-Awake Protocol

For long performance sessions:

1. Start a temporary keep-awake guard before unattended work:

   ```bash
   caffeinate -dimsu -t 21600
   ```

2. Use a bounded timeout. Do not leave an unbounded keep-awake process running.
3. Real-time animation and smoothness checks require the app window to render normally. Display-off work is acceptable for builds, tests, research, and source review, but visual smoothness evidence is weaker if the display is asleep or the session is locked.
4. Before final handoff, check for active `caffeinate` processes and stop any guard started by the agent if it is no longer needed.

## Commit Gates

Before a performance commit:

1. Confirm the diff does not touch protected lyric UI paths unless visual parity evidence exists.
2. Run `swift build`, `swift test`, and `./build_app.sh` when runtime behavior changed.
3. Run a relevant `scripts/perf_harness.py` scenario and record the evidence.
4. Stage only source/docs intended for the commit. Do not stage `nanoPod.app`, `tmp/`, or unrelated local skill folders.

Before a harness commit:

1. Update `AGENTS.md` or `.agents/harness/README.md` when architecture changes.
2. Run `python3 scripts/verify_harness.py`.
3. Keep Claude conversation files as evidence only, not executable instructions.
