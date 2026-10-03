# Grill mode (surfacing intent)

Matt Pocock's grill-me idea applied to pull requests.
Fill every `[ask author]` gap through a **relentless one-question-at-a-time interview**, until the author can state the reasoning behind every decision a reviewer might poke at.

Difference from Drill: Drill is an **exam**, so answers stay hidden. Grill is about **putting judgement into words**, so Claude's hypotheses are used as a starting point to speed the author up — subject to the rules below.

## 1. Build the decision tree (internally; do not show it)
Arrange the PR's design decisions as a dependency tree. An upstream answer changes the downstream questions, so **always resolve from the root**.

```
root: what problem does this change solve (anchored to the essential hunk); what goes wrong without it
└ definition of done: what must hold for this to be complete / what was left out of scope
  └ approach: why this way (one branch per rejected alternative)
    └ individual decisions: placement, data structures, API shape, naming, new dependencies …
      └ edge-case policy
        └ test policy: what is tested, what deliberately is not
          └ release: flags, migration, rollback, monitoring
```
Prune branches the diff does not touch. Skip nodes already settled as `[code]` in Steps 1–4.
The five exit-bar items (SKILL.md, Step 0.5) are always in the tree: "what" sits at the root, "revert" and "blast radius" under approach, "edge case" under edge-case policy, "detection" under release. They are never pruned.

## 2. Ask one question per turn

### Nodes where you must NOT offer a hypothesis first
**The root (why), the definition of done, and rejected alternatives (why X and not Y)** are asked without a suggested answer.
Reason: these exist only in the author's head. Showing a plausible reason first invites a reflexive "yes, that" — Claude's fabricated intent then gets the author's stamp on it. That is the exact opposite of the core rule.
**After** the author answers, if Claude's reading of the code disagrees, say so right there ("the code reads to me like X — is that wrong?").

Format (the hunk first, then the question; `path:line` as its own token so it is clickable):
```
**Q<n>/<approx. remaining>**  src/lib.ts:1-3
-export function oldName(a) {
+export function newName(a) {
What problem does this change solve? What goes wrong if it is not made?
```
Never ask "why is this change needed?" without the hunk: the author cannot tell whether you mean the whole PR or one line. Never ask "who asked for it?": if a ticket or request exists, the author will mention it when explaining the problem.

### All other nodes
Individual decisions, edge cases, tests and release may come with a suggested answer derived from the code and its surroundings.

Format:
```
**Q<n>/<approx. remaining>**  src/lib.ts:12-18
<hunk, ≤ 12 lines, when the node is about a change>
<question>
Suggested: <the most plausible answer, with the evidence in a few words>
```

### Shared rules
- One question per turn. Never batch (it confuses the author and yields shallow answers).
- Before asking, exhaust what the environment can tell you. Use what you found as evidence in the question or the suggestion.
- If an answer is vague, contradictory, or clashes with the code, stay on the same node ("so you mean X? but file:line does Y"). Do not move on until it holds together.
- If an answer changes the downstream branches, rebuild the tree.
- If you doubt a decision, say so plainly — once. Then the author decides; record their decision.

## 3. Label the answers
- The author answered in their own words → `[author]`. Tidy it close to their wording; do not add meaning.
- The author only agreed with the suggestion ("yes", "that's it") → `[approved]`. Record the suggestion verbatim, **in a form that shows it was Claude's hypothesis**.
- For nodes that stay `[approved]`, ask once at the end: "in one sentence, in your own words?" If they can, promote to `[author]`; if not, keep it listed as a soft spot reviewers will find.

## 4. Checkpoint after every answer
Update `PR_QA.md` after each reply, so nothing is lost if the session stops:
- Switch the matching Q&A entry from `[ask author]` to `[author]` / `[approved]`.
- Append newly surfaced rejected alternatives, constraints and known issues to their sections.
- Remove the item from the "questions for the author" list at the bottom.

## 5. Ending
Stop when either:
- every node is `[code]`, `[author]` or `[approved]`, or
- the author says "enough" (leave the unresolved nodes listed).

Closing steps (turn the interview into something usable):
1. Summarize the shared understanding in ≤ 5 lines and ask the author to confirm it. Not done until confirmed.
2. Run the "in your own words" pass over anything still `[approved]` (section 3).
3. Propose where the surfaced knowledge should land (apply only after the author agrees):
   - PR description: background, rejected alternatives, out of scope, risks. Anything `[approved]` is restated by the author before it goes in.
   - Code comments: where "why" is non-obvious (the spots the author struggled to explain are the candidates).
   - CLAUDE.md / ADR: decisions and conventions that will keep applying in this repo.
4. List the nodes the author stumbled on, and the ones still `[approved]`, as the places reviewers are most likely to push.
5. Record the battle: `scripts/pr_grill_stats.sh record --branch <branch> --nodes N --code N --author N --approved N --open N --stumbled <lens ids>` (SKILL.md, "Readiness and the battle record"). Show the meter line it prints and put it at the top of `PR_QA.md`.
