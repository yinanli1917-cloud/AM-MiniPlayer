# Skill Invocation Rule

NEVER read a SKILL.md file with the Read tool.
NEVER hand-write a SKILL.md file with Write or Edit.

Use the Skill tool to invoke skills.
Use /skill-creator to create or edit skills.

## Zero Exceptions

- "Just checking what it does" → invoke it, the skill explains itself
- "Too simple for skill-creator" → simple skills still need eval
- "I'll run skill-creator later" → later never comes; invoke now
- "I already know the contents" → skills evolve; your memory may be stale

## What Triggers This Rule

- About to call Read on any path ending in SKILL.md → STOP
- About to call Write/Edit on any path ending in SKILL.md → STOP
- About to write skill content inline without Skill tool → STOP

## The Correct Action

1. Task matches an available skill? → invoke via Skill tool
2. Need to create a new skill? → invoke /skill-creator
3. Need to edit an existing skill? → invoke /skill-creator
