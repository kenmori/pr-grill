# PR QA: <branch / PR title>

<readiness meter line from `pr_grill_stats.sh meter`; refresh at every Grill checkpoint>

## Exit bar (same for every author; done = all five `[code]` or `[author]`)
1. What it changes, in one sentence — `[ ]`
2. Revert: what breaks, what gets fixed — `[ ]`
3. Blast radius: callers, and the one most at risk — `[ ]`
4. The edge case most likely to bite — `[ ]`
5. Detection: how production would show it broke — `[ ]`

## One-sentence summary

## ⚠ Top priority (secrets · callers outside the diff · untracked files)

## Change map
### Essential changes
### Incidental changes
### ⚠ Unexplained changes (decide before opening the PR)

## Behaviour diff (Before → After)

## Blast radius

## The 3 questions you will almost certainly get

## Expected Q&A (by priority)
### Q1. <question> — <lens> / <file:line>
**A.** <draft answer> `[code|guess|ask author|author|approved]`

## Extra checks
- Accountability check:
- Revert thought experiment:
- Rejected-alternatives ledger:
- 3 a.m. incident test:
- PR description consistency / unintended promises:
- Unexecuted checks:
- Reviewer prediction (CODEOWNERS / reviewRequests are `[code]`; past authors are `[guess]`):

## Change notes (paste into the PR; the 5 most important hunks, links open the line)
- [path:lines](link) — what; why (only if `[author]`)
- and N smaller hunks: <formatting, imports, …>

## 30-second explanation

## ❓ Questions for the author (root of the decision tree first)

## Review round <n> (Revise; since <sha>)
### Threads → fixes
| Thread | Delta | Status | Author's reason (what was wrong / why this fixes it) |
|---|---|---|---|
### Unprompted changes
### Open threads (fix or reply still owed)
### Invalidated earlier answers
### Unexecuted checks for the delta
### Re-review summary (for the reviewer)
### Reply drafts (per thread)
