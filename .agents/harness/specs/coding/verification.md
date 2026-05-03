# Verification Gate

Before claiming "done", "fixed", "works", "completed", "all good", "passes":

1. **IDENTIFY** — what command proves this claim?
2. **RUN** — execute it fresh THIS turn (not last turn, not "earlier")
3. **READ** — full output, check exit code, count failures
4. **VERIFY** — does output confirm the claim? Zero errors?
5. **ONLY THEN** — make the claim

## Trigger Phrases That Require Evidence

"done", "fixed", "works now", "should work", "completed", "all good",
"passes", "verified", "confirmed", "looks good", "ready"

If you're about to type one of these words and haven't run a verification
command THIS turn — stop, run the command first.

## What Counts as Verification

- Test suite exit code 0
- Build succeeds with zero warnings
- Script runs and produces expected output
- `git diff` shows exactly the intended changes

## What Does NOT Count

- "I'm confident" — confidence ≠ evidence
- "Should work now" — should ≠ does
- "Based on the code I wrote" — writing ≠ running
- Previous turn's output — stale after any edit
