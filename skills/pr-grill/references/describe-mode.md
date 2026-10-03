# Describe mode (the PR description, from what the author has already said)

Triggers: "write my PR description", "draft the PR body", "PR の説明文を書いて". Runs after Brief; best after Grill.

The description is assembled, not written: every sentence comes from `PR_QA.md` or the collector. Nothing the author has not said gets invented. Gaps stay visible.

## 1. Inputs
- `PR_QA.md` for this branch (run Brief first if it is missing).
- The repository's PR template, if the collector listed one: use its headings in its order and fill each from the mapping below; leave a template heading you cannot fill with `_(nothing to add)_` rather than deleting it.
- Without a template, use `assets/PR_BODY_template.md`.

## 2. Mapping (source → section)
| Section | Source | Rule |
|---|---|---|
| Summary | One-sentence summary | verbatim |
| Why | root node of the decision tree | only if `[author]`; otherwise write `— (why: fill in)` |
| What changed | Change notes | the budgeted lines, with links; then the "and N smaller hunks" line |
| Behaviour | Behaviour diff (Before → After) | `[code]` lines only |
| Out of scope | "definition of done" node | `[author]` only |
| Risks and rollback | 3 a.m. incident test, revert thought experiment | `[code]` facts; author's words for mitigations |
| Rejected alternatives | ledger entries that are `[author]` | one line each: "X — not chosen because …"; `[ask author]` entries are omitted, not guessed |
| Testing | "Unexecuted checks" | list what ran with its result; what did not run is listed as not run. Never write "tests pass" without output seen |
| Notes for reviewers | the 3 questions you will almost certainly get, with their answers | `[code]` answers in full; `[author]` answers in the author's words |

Drop the labels in the output; they are for the author, not the reviewer. `[approved]` content is restated by the author before it goes in (ask, one line).

## 3. Output
Write `.pr-grill/<branch>/PR_BODY.md`. Then print exactly three lines:
```
PR body: /abs/path/.pr-grill/<branch>/PR_BODY.md   (<n> gaps marked "fill in")
copy:    pbcopy < .pr-grill/<branch>/PR_BODY.md      # Linux: xclip -selection clipboard < …  /  wl-copy < …
create:  gh pr create --title "<one-sentence summary>" --body-file .pr-grill/<branch>/PR_BODY.md
```
Do not run `gh pr create` yourself. If gaps remain, say which nodes would fill them and offer Grill on just those.
