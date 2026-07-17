# The Ten-Minute Probe We Skipped for Months

Date: 2026-07-14
Project: nanoPod (macOS menu bar music player)
Context: lyrics matching pipeline, metadata resolver
Written as source material for a personal essay about engineering judgment.

## What happened

nanoPod shows synced lyrics for whatever plays in Apple Music. To find
lyrics, it must first know which song is playing. That sounds trivial, and
for songs in one language it is. It breaks when the system language and the
song language differ. My Mac runs in English, so Apple Music reported a
Kay Huang song to us as "Dinner". Every lyrics database in the world knows
that song only by its Chinese name, 三個人的晚餐. Matching "Dinner" against
Chinese databases produced either nothing or, worse, a confident wrong
answer: a sibling track from the same artist with a similar duration, shown
to the user as if it were correct.

We fought this class of bug for months. The git history shows the layers:
a romanization checker, then a "does this artist look English" heuristic,
then a whitelist mapping a few English words to Chinese words, then a rule
that trusted a search response when it contained exactly one result, then
patches for each new wrong-lyrics report those layers caused. Four
postmortems (005 through 008) document the casualties. Each patch was
locally reasonable. Each one made the pile taller.

## The ten-minute probe

The answer was in the upstream API the whole time. One evening I finally
asked a different question: instead of "how do I patch this failure", I
asked "what does the data source actually know". Four curl commands
answered it:

| Storefront | Track 1770707474 displays as | Album displays as |
|------------|------------------------------|-------------------|
| Taiwan     | 三個人的晚餐                  | 平凡              |
| China      | 三个人的晚餐                  | 平凡              |
| US / UK    | Dinner                       | Ping Fan          |

Same track ID. The record label supplied localized names for every
storefront when they distributed the song, and Apple's search index matches
a query against all of them. Searching "Dinner Kay Huang" returns exactly
this one track on five different storefronts. The "translation pair" we
spent months trying to infer with heuristics was sitting in the catalog as
plain data, entered by a human at the label, retrievable in one HTTP call.

The probe took about ten minutes. The heuristics it replaced took months to
write, and they caused the worst bugs the product had: lyrics that were
confidently wrong.

## Why capable people miss this

Nobody decided to skip the study. Every individual session was rational:

- A bug report arrives with a specific song. The fastest visible fix is a
  targeted patch, and the patch works for that song.
- Each patch adds a little more local logic, which makes the system feel
  more owned and more understood than it actually is.
- Debugging always started from our code, because that is where the stack
  traces are. The upstream API had no stack trace, so it stayed a black box.
- The sunk heuristics created a frame: "matching is hard, we need smarter
  matching". Inside that frame, "the catalog already knows" is not a
  thought anyone has.

The failure is procedural. There was never a moment where the team
stopped patching and characterized the upstream system on purpose.

## The rule we now enforce

When one boundary accumulates three or more matching heuristics, stop.
Do not write the fourth. Spend the next hour poking the upstream system by
hand: real queries, edge inputs, cross-checks between endpoints. Write down
what it knows and what it does not. Then design against the data.

In this project the rule is recorded in the knowledge ledger as a banned
pattern, so the tooling resurfaces it whenever someone reaches for
heuristic number four.

## What the detour still bought

Honesty requires this section. The probe alone would not have shipped a
correct pipeline. Trusting "the search returned one result" naively had
already served wrong lyrics once, because a one-result response can also be
a coincidence from an artist catalog dump. The months of failures produced
the distinction that makes the simple rule safe: it matters which query
produced the candidate. A title-plus-artist query collapsing to one
identity is the catalog asserting an alias. An artist-only dump containing
one nearby duration is a trap. Without the failure catalog, we could not
have told those two apart, and the ten-minute discovery would have shipped
a new class of confident mistakes.

The lesson is therefore narrow and usable: the waste was never the
verification machinery. The waste was every hour spent inferring facts that
an upstream system would have stated directly, if anyone had asked it.

## The checklist I keep now

1. Before building any matcher, translator, or inferencer, spend one hour
   characterizing the upstream data source by hand.
2. Count the heuristics at each boundary. At three, freeze and study.
3. When a heuristic guesses a fact, ask "who authored this fact, and can I
   read it from them directly".
4. Keep the evidence machinery. Delete the guessing machinery the moment a
   direct source replaces it, and write down why it existed.
