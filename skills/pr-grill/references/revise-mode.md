# Revise mode (after pushing fixes for a review)

The author has pushed changes in response to review comments. Fixes written under review pressure, often by an AI, are the part of a PR the author understands least, and the re-review will test exactly that: *what was wrong before, and why does this fix it?* Revise makes the author able to answer both for every fix, then produces what the reviewer needs for the second round.

Triggers: "I pushed the fixes", "I addressed the review", "what changed since the review", "ready for re-review?".

## 1. Collect the delta, not the whole PR
1. Load the existing `PR_QA.md` from `.pr-grill/<branch>/`. If there is none, run Brief first; Revise needs the earlier answers to know what the fixes invalidated.
2. Run the collector in review-round mode:
   - `scripts/collect_pr_context.sh --since last` (the HEAD recorded by the previous run), or `--since <sha>` with the commit the reviewer looked at (the PR timeline shows it), when the previous run is older than the review.
   - Add `--pr <number>` when `gh` is available. The summary then lists every review thread with `touched` / `file touched, not at this line` / `file untouched`.
   - If the collector says `--since … is not an ancestor of HEAD`, the branch was rebased or amended after the review. Ask the author for the reviewed commit; do not guess and do not run git commands to "repair" it.
3. Every section of the summary now covers only the delta. Read it as a small PR of its own: unexplained changes, suspicious patterns, secret-shaped values, callers outside the diff, tests.

## 2. Map fixes to threads
Build a three-column list and show it to the author:

| Review thread | Delta hunk(s) | Status |
|---|---|---|
| `#id path:line` first words of the comment | files/lines in the delta | addressed / partly / not addressed / disputed (reply says why not) |

Then the leftovers:
- **Unprompted changes**: delta hunks that map to no thread. Each needs a reason, or it is scope creep the reviewer will ask about.
- **Untouched threads**: comments with no corresponding change and no reply. Each needs either a fix or a reply (Reply mode).

The `--pr` section gives a mechanical first pass; correct it by reading the hunks. A thread can be addressed in a different file than the one it was left on.

## 3. One fix at a time: two questions
For each addressed thread, in the order of the threads, ask **one question per turn**:

1. **"What was wrong before?"** — the author's words, no suggested answer first. Claude states what the old code did `[code]`; the author states why that was a problem. If the answer is "the reviewer said so", stay on it: a fix the author cannot justify is a fix they cannot defend.
2. **"Why does this change fix it, and what else does it change?"** — Claude may add a suggested answer here, derived from the diff and the callers section. Watch for: the fix narrowed or widened behaviour beyond the comment, a `[code]` answer in `PR_QA.md` that cited the old lines, a test that was changed to pass rather than to check.

Label the answers exactly as in Grill (`[author]` / `[approved]`), and apply the same rule: nodes that stay `[approved]` get the "in your own words?" pass at the end.

Skip the two questions for a thread only when the fix is mechanical and the comment was mechanical (a typo, a rename the reviewer spelled out). Say which threads were skipped and why.

## 4. Update `PR_QA.md`
Append a `## Review round <n>` section (the template has the shape):
- Resolved threads, with the author's answers.
- Open threads, with what is still owed (fix or reply).
- Unprompted changes and their reasons.
- **Invalidated answers**: every earlier `[code]` entry whose cited lines the delta changed. Re-derive them from the new code or mark them `[ask author]` again.
- Unexecuted checks for the delta: did tests/lint run after the fixes? "The fix is covered" is `[code]` only if a test exercising it exists and ran.

Checkpoint after every answered question, as in Grill.

## 5. Hand-offs for the second round
Produce, for the author to post (never post yourself):
1. **Re-review summary**: 5–10 lines, "since your review: thread A → fixed by `<sha>` (what changed), thread B → replied, not changed because …, plus one unprompted change: …". This is the first thing a re-reviewer wants.
2. **Per-thread reply drafts**: "Fixed in `<sha>`: <one sentence on what changed and why>", written in the author's words from step 3. Threads marked *disputed* get the Reply-mode treatment instead.
3. The list of fixes where the author stumbled in step 3: these are what the re-review will probe.

Every run records its HEAD in `state`, so the next round's `--since last` starts from this one.
Then update the battle record with `scripts/pr_grill_stats.sh record … --rounds <n>` using the current node counts, so the stats show how many rounds this PR took.
