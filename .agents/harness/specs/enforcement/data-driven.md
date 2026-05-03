# Data-Driven Frameworks

When a new rule, pattern, or behavior needs to be added to the harness:

1. Add a config entry (YAML rule, spec file, or phase config)
2. NEVER edit Python hook code to add a one-off check
3. If the framework doesn't support this rule type yet → extend the framework first

## Adding a New Deny Rule

Add to `~/.claude/hooks/rules/global.yaml` or a scoped YAML file:
```yaml
- id: descriptive-name
  pattern: 'regex pattern'
  message: "Human-readable block message"
  strip_data: true
```

## Adding a New Phase Reminder

Add to `~/.claude/hooks/rules/phases.yaml` under the correct domain + phase.

## Adding a New Spec

Create a file in `~/.claude/spec/{domain}/{concern}.md`.
Reference it in the relevant `implement.jsonl` or `check.jsonl`.

## Anti-Pattern

Editing enforce-rules.py to add:
```python
if "some_specific_thing" in command:
    deny("hardcoded message")
```
This is WRONG. It should be a YAML entry instead.
