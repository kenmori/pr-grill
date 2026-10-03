# Author levels and the exit bar

## Calibrating to the author
Authors differ: one inherited a branch written by someone else, another wrote every line and owns the module. The same questions bore the second and crush the first. **The profile changes the path, never the destination**: everyone ends at the same exit bar (below).

Do not ask. The collector infers `wrote=self|ai|inherited` (branch commit authors, AI co-author trailers) and `knows=new|some|owner` (the user's past commits on the changed files). State it in one line and move on, e.g. "Treating you as: wrote with AI, some history in these files — say so if that's wrong." If `.pr-grill/<branch>/profile` exists, it overrides the inference; write that file only when the user corrects you.

| Profile | Brief | Grill | Drill |
|---|---|---|---|
| **Newcomer** (`knows=new`, or `wrote=inherited`) | Add a **Walkthrough** before the Q&A: each essential hunk in plain language, what calls it, what it calls. Top-3 questions are "what does it do" questions. | Before each "why", state what the code does `[code]`. Suggested answers allowed on every node except the root and rejected alternatives. Fewer nodes: root, done, approach, tests. | Easy by default; hints before every grade. |
| **Working** (default) | As written in Steps 2–5. | As written in `grill-mode.md`. | Normal. |
| **Owner** (`knows=owner` and `wrote` ≠ `inherited`) | Skip the walkthrough and the behaviour diff narration; go straight to blast radius, unexplained changes and the Q&A. Keep the top 5 questions, hardest first. | **No suggested answers on any node** (an owner anchors as easily as anyone). Push harder on rejected alternatives and incident behaviour. | Brutal by default. |

`wrote=ai` on any level: run the accountability check (Step 4) on **every** non-trivial hunk, not a sample, and put those questions first in Drill.
`wrote=inherited`: `[ask author]` is the wrong label, because the user is not the author. Use `[ask original author]`, find who that is from `git log` on the changed lines, and end Brief with the list of questions to take to them. Do not Grill the user on decisions they did not make; Grill them only on what they changed since taking over.

Record the profile in the battle record (`--level newcomer|working|owner`) so the stats show the level the score was earned at.

## The exit bar (same for every level)
No session counts as done until the author can answer these five **in their own words**, each `[code]` or `[author]`:
1. **What** this PR changes, in one sentence a teammate outside the project would understand.
2. **Revert**: what breaks and what gets fixed if it is reverted tomorrow.
3. **Blast radius**: who calls the changed code, and which caller is most at risk.
4. **The edge case** most likely to bite, and what the code does there.
5. **Detection**: how anyone would notice in production that this broke.

The five are always nodes in the Grill decision tree, so the readiness meter counts them. A Newcomer reaches them through the walkthrough and easy Drill; an Owner is checked against them first and then pushed beyond (rejected alternatives, incidents, scale). In `PR_QA.md`, keep an "Exit bar" section with the five and their current labels, and refresh it at every checkpoint. When the author says "enough" with any of the five still open, say so plainly in the closing summary and in the record (`--open`).

