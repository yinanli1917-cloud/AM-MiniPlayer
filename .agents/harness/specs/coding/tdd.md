# TDD Sequence

For ANY production code change:

1. Write a failing test FIRST
2. Run it — confirm RED (test fails as expected)
3. Write the minimal code to make it pass
4. Run it — confirm GREEN (test passes)
5. Refactor if needed — run again, still GREEN

## Violations

- Wrote production code before the test → delete the code, start over
- Test passes immediately on first run → test is not testing anything, rewrite it
- "Too simple to test" → simple code breaks. Test takes 30 seconds. No exceptions.
- "I'll test after" → tests passing immediately prove nothing — you never saw it fail

## What Counts as a Test

- Unit test file (pytest, XCTest, Jest, etc.)
- SwiftUI Preview that renders without crash (for UI components)
- CLI command that produces verifiable output

## What Does NOT Count

- "I ran it mentally" — not evidence
- "The linter passes" — linter ≠ tests
- "It compiled" — compilation ≠ correctness
