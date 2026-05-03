# GEB Documentation Protocol (L1-L3)

Code is the machine phase, docs are the semantic phase — they must stay isomorphic.

## Layer Definitions

| Layer | Location | Purpose | Update Trigger |
|-------|----------|---------|----------------|
| L1 | `/CLAUDE.md` | Project constitution, tech stack, conventions | Architecture change, module add/remove |
| L2 | `/{module}/CLAUDE.md` | Module member list, interfaces, responsibilities | File add/remove, interface change |
| L3 | File header comment | Dependencies, exports, positioning | Dependency/export/role change |

## L3 Format

```
/**
 * [INPUT]: Depends on {module}'s {capability}
 * [OUTPUT]: Exports {functions/types}
 * [POS]: {role} within {module}
 */
```

## When to Update (mandatory)

- Created a new file → add L3 header
- Added/removed a file from a module → update L2 member list
- Changed project architecture (new module, removed module) → update L1
- Changed a file's exports or dependencies → update its L3

## Verification

After code changes, loop-check:
1. Does the file have an L3 header? Is it accurate?
2. Does the module CLAUDE.md list this file? Are interfaces current?
3. Does the project CLAUDE.md reflect current architecture?

If any answer is "no" — update before claiming done.
