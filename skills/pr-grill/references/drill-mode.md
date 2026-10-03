# Drill mode (oral exam)

Test how well the author actually understands the change and find what they cannot answer. A rehearsal for the real review.

## Procedure
1. Run Steps 1–3 internally and prepare 5–10 questions (do not show them yet).
   - At least one "what breaks without this line?" question (accountability check).
   - At least one "why X and not Y?" question (rejected alternative).
   - One "explain it in one sentence to a non-engineer".
   - Tag each question with the kind of answer Claude holds: a **fact question** (settled by `[code]`) or an **intent question** (`[ask author]`; only the author knows).
2. Ask **one at a time** and wait. Never batch (showing answers ahead defeats the exam).
3. Evaluate the answer. How depends on the kind of question:

   **Fact questions** (what changes, what breaks, who calls this):
   - ◎ accurate with evidence / ○ right direction, weak evidence / △ partly wrong / × cannot answer, or wrong
   - When an answer contradicts the code, point at file:line and say so plainly. Do not grade softly.
   - **Before giving × or △, re-read the relevant lines.** The worst outcome is Claude misreading the code and marking the author wrong. If the re-read shows Claude was wrong, void the question and say so.
   - On △/×, give one hint before revealing the answer.

   **Intent questions** (why needed, why this approach, why X not Y):
   - No right/wrong. The author's answer is the truth; Claude has no answer key.
   - Evaluate **(a) consistency with the code** ("for performance", but the code does nothing for performance) and **(b) whether a reason was given at all** ("just because", "it was always like this" are not reasons).
   - On inconsistency, show the contradiction ("but file:line does Y"). On a missing reason, record the node as a Grill candidate.
4. Wrap-up:
   - Score on the fact questions and the weak-spot pattern (e.g. error paths are hazy, cannot explain the types).
   - Intent questions without a reason → the hand-off list for Grill.
   - Every × is a place to re-read before opening the PR.
   - If the author could not answer because the code itself is hard to read, list it as a comment/refactor candidate inside the PR.
   - Record the result: `scripts/pr_grill_stats.sh record --branch <branch> --drill PERFECT/PARTIAL/WRONG --difficulty <level> --stumbled <lens ids>` plus the node counts if a Grill already ran (otherwise `--nodes 0 --code 0 --author 0 --approved 0 --open 0`). Only fact questions count toward the score.

## Difficulty
"Normal" unless the user says otherwise.
- Easy: what changed.
- Normal: why, and edge cases.
- Brutal: rejected alternatives, incident behaviour, 100× scale — the questions a senior reviewer asks.
