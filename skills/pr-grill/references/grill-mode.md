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

Format (the hunk first, then the question; `path:line` with a single line first so the terminal links it, the range in parentheses):
```
**Q<n>/<approx. remaining>**  src/lib.ts:1 (1-3)
-export function oldName(a) {
+export function newName(a) {
What problem does this change solve? What goes wrong if it is not made?
```
Never ask "why is this change needed?" without the hunk: the author cannot tell whether you mean the whole PR or one line. Never ask "who asked for it?": if a ticket or request exists, the author will mention it when explaining the problem.

### All other nodes
Individual decisions, edge cases, tests and release may come with a suggested answer derived from the code and its surroundings.

Format:
```
**Q<n>/<approx. remaining>**  src/lib.ts:12 (12-18)
<hunk, ≤ 12 lines, when the node is about a change>
<question>
Suggested: <the most plausible answer, with the evidence in a few words>
```

### Ask about the thing, not the motive
A question that only asks "why did you do this?" gets a one-line motive and teaches nothing. Each question must go into the **substance of what changed**: what the code does, what a reader of it believes, which caller depends on which promise, what invariant holds. Derive the question from the hunk, e.g.

| Change | Weak question | Question that reaches the substance |
|---|---|---|
| rename `oldName` → `newName` | why rename? | What does this function actually do, and what did `oldName` make a reader expect that is false? Which caller relies on what `newName` now promises? |
| new `if` branch | why add this check? | Which input reaches this branch, where does it come from, and what did the code do with it before? |
| new dependency | why add it? | Which function of it do you call, what did you replace, and what happens on its failure path? |
| changed default value | why 30? | Who reads this value, what did they get before, and which of them notices the difference? |
| deleted code | why remove? | What called this, and what do those callers get now? |

### After every answer: grade, explain, model answer
Do all three, briefly, in that order, before the next question:
1. **Grade the answer on three points** (one line each):
   - *Specific?* It names a file, function, caller, input, case or number. Vague words ("for consistency", "cleaner", "just in case", "best practice") get the answer sent back once: "which caller / which input / which case?"
   - *Consistent with the code?* Quote `path:line` where it is not.
   - *Complete for a reviewer?* Name the element a reviewer would still ask for (the caller, the failure path, the test).
2. **Explain** what the code itself shows about this node, as `[code]` with `path:line`, including anything the author did not mention.
3. **Model answer**: rewrite the author's answer into the form a reviewer wants, **built only from the author's words plus `[code]` facts**. Mark intent parts as the author's, evidence parts with `path:line`. Never invent a reason the author did not give; where a reason is still missing, leave a visible gap ("reason: — (yours)"). This text goes into `PR_QA.md` as the node's answer and later into the PR description.

Example turn after the author answers "names were inconsistent; on-call misread a log last week (INC-212)":
```
Specific: yes (INC-212, the log line). Consistent: yes. Missing: which caller depends on the new promise.
[code] src/lib.ts:1 returns its argument unchanged; src/caller.ts:1 is the only import and still uses oldName.
Model answer: `oldName` only echoes its input (src/lib.ts:1), but the old name read as a transformation, which
is how on-call misread the log in INC-212 (author). Renamed to `newName`; the single caller src/caller.ts:1
must follow — it does not yet.
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
