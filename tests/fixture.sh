#!/usr/bin/env bash
# Regression tests for collect_pr_context.sh: builds a throwaway repo and checks the output.
# Usage: tests/fixture.sh   (exit 0 = all passed)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../skills/pr-grill/scripts/collect_pr_context.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pr-grill-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
# yes <description> <command...>: command must succeed / no: must fail
yes() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
no()  { local d="$1"; shift; if "$@"; then fail "$d"; else ok "$d"; fi; }
# Lines of a section, from its heading to the next heading
section() { awk -v h="## $1" 'index($0, h) == 1 { p = 1; next } /^## / { p = 0 } p' "$OUT"; }
in_section() { section "$1" | grep -Eq "$2"; }
in_out() { grep -Eq "$1" "$OUT"; }

# ---- throwaway repository -------------------------------------------------------
REPO="$TMP/repo"; mkdir -p "$REPO"; cd "$REPO" || exit 1
git init -q; git config user.email t@example.com; git config user.name tester
git checkout -q -b main
mkdir -p src packages/x/dist .github tests
printf 'export function oldName(a) {\n  return a\n}\n' > src/lib.ts
printf 'import { oldName } from "./lib"\nexport const run = () => oldName(1)\n' > src/caller.ts
printf 'export const tick = () => 1\n' > src/clock.ts
printf 'export const t = 1\n' > src/tokenizer.ts
printf 'old bundle\n' > packages/x/dist/bundle.js
printf '{"name":"x","lockfileVersion":3}\n' > package-lock.json
printf '{"scripts":{"test":"vitest","lint":"eslint ."}}\n' > package.json
printf '* @owner-all\nsrc/ @team-src\n' > .github/CODEOWNERS
printf 'test("x", () => {})\n' > tests/lib.test.ts
git add -A; git commit -qm "initial"

git checkout -q -b feature/rename
# 1. rename a function without updating its caller (src/caller.ts)
sed -i.bak 's/oldName/newName/' src/lib.ts && rm src/lib.ts.bak
# 2. stray console.log and secrets, in a source file whose name contains "lock"
printf 'console.log("dbg")\nconst apiKey = "sk-abcdefghijklmnopqrstuvwxyz"\nconst token = "hardcoded-token"\nconst jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"\nexport const tick = () => 2\n' > src/clock.ts
# 3. code that merely contains the word "token" (not a secret)
printf 'export const tokenize = (s: string) => s.split(" ")\n' > src/tokenizer.ts
# 4. nested dist and a lockfile (must be excluded)
printf 'new bundle\n' > packages/x/dist/bundle.js
printf '{"name":"x","lockfileVersion":3,"changed":true}\n' > package-lock.json
git add -A; git commit -qm "rename oldName to newName"
# 5. an untracked file (and no test changes)
printf 'export const fresh = 1\n' > src/brand_new.ts

# ---- run ----------------------------------------------------------------
echo "# default output directory"
STDOUT="$TMP/stdout.txt"
bash "$SCRIPT" main > "$STDOUT" 2>"$TMP/stderr.txt"; CODE=$?
if [ "$CODE" -eq 0 ]; then ok "exit code 0"; else fail "exit code $CODE"; cat "$TMP/stderr.txt"; fi
OUTDIR="$REPO/.pr-grill/feature__rename"; OUT="$OUTDIR/summary.md"
if [ -f "$OUT" ]; then ok "summary.md is written"; else fail "summary.md missing ($OUTDIR)"; exit 1; fi
yes "stdout matches summary.md" diff -q "$OUT" "$STDOUT"

echo "# must detect"
yes "caller of renamed function flagged as outside the diff" in_out 'src/caller\.ts:.*oldName.*outside diff'
yes "console.log reported with file:line"                     in_section "Suspicious patterns" '^src/clock\.ts:1: console\.log'
yes "sk- shaped key detected and masked"                      in_section "Secret-shaped values" '^src/clock\.ts:2: .*sk-a…\[masked\]'
no  "sk- key value is not echoed"                             in_section "Secret-shaped values" 'sk-abcdefghij'
yes "token = \"literal\" detected and masked"                 in_section "Secret-shaped values" '^src/clock\.ts:3: .*"hard…\[masked\]"'
no  "token value is not echoed"                               in_section "Secret-shaped values" 'hardcoded-token'
yes "JWT detected and masked"                                 in_section "Secret-shaped values" '^src/clock\.ts:4: .*"eyJh…\[masked\]"'
no  "JWT value is not echoed"                                 in_section "Secret-shaped values" 'eyJzdWIiOiIxIn0'
yes "missing test changes called out"                        in_out 'no test changes'
yes "untracked file listed"                                   in_section "Untracked files" '^src/brand_new\.ts$'
yes "CODEOWNERS approximate match (last wins)"                in_section "CODEOWNERS" '^- src/lib\.ts → @team-src'
yes "package.json test/lint scripts listed"                   in_out '^- npm run test'
yes "per-file patch referenced"                               in_out 'src__lib\.ts\.patch'
yes "per-file patch exists"                                   test -f "$OUTDIR/diff/src__lib.ts.patch"

echo "# must not misreport"
yes "clock.ts is not treated as a lockfile"     in_section "Changed files (stat)" 'src/clock\.ts'
no  "nested dist absent from stats"             in_section "Changed files (stat)" 'packages/x/dist'
no  "package-lock.json absent from stats"       in_section "Changed files (stat)" 'package-lock\.json'
yes "dist listed under excluded files"          in_section "Excluded files" 'packages/x/dist/bundle\.js'
no  "clock.ts not listed under excluded files"  in_section "Excluded files" 'clock'
no  "tokenizer not flagged as suspicious"       in_section "Suspicious patterns" 'tokenizer'
no  "tokenizer not flagged as a secret"         in_section "Secret-shaped values" 'tokenizer'
no  "defining file excluded from callers"       in_section "Caller candidates" '^src/lib\.ts:'
no  "output dir ignored via .git/info/exclude"  sh -c "cd '$REPO' && git status --short | grep -q '\.pr-grill'"

echo "# options"
bash "$SCRIPT" --out "$TMP/custom" --no-diff main > /dev/null 2>&1
yes "--out changes the output directory" test -f "$TMP/custom/summary.md"
yes "--no-diff skips patches"            test ! -d "$TMP/custom/diff"
yes "--help"                             sh -c "bash '$SCRIPT' --help | grep -q -- --out"
no  "unknown base fails"                 sh -c "bash '$SCRIPT' no-such-branch 2>/dev/null"
no  "outside a git repo fails"           sh -c "cd '$TMP' && bash '$SCRIPT' 2>/dev/null"

echo "# --out safety: a pre-existing file in <out>/diff survives"
mkdir -p "$TMP/keep/diff" && printf 'mine\n' > "$TMP/keep/diff/notes.txt"
bash "$SCRIPT" --out "$TMP/keep" main > /dev/null 2>&1
yes "user file in --out/diff is kept"  test -f "$TMP/keep/diff/notes.txt"

echo "# base == HEAD"
git checkout -q main
bash "$SCRIPT" main > "$TMP/onbase.txt" 2>&1
yes "warns when HEAD is the base commit"  grep -q 'HEAD is at the same commit as main' "$TMP/onbase.txt"
yes "says nothing changed"                grep -q 'nothing changed since main' "$TMP/onbase.txt"
git checkout -q feature/rename

echo "# linked worktree"
git worktree add -q "$TMP/wt" -b wt-branch main 2>/dev/null
( cd "$TMP/wt" && printf 'export const w = 1\n' > w.ts && git add w.ts && git commit -qm w \
  && bash "$SCRIPT" main > "$TMP/wt.txt" 2>"$TMP/wt.err"; echo $? > "$TMP/wt.code" )
yes "runs inside a linked worktree without errors"  test "$(cat "$TMP/wt.code")" = 0
no  "no mkdir error on the .git file"               grep -q 'Not a directory' "$TMP/wt.err"
# Match on the basename: on macOS $TMP is under /var, which git resolves to /private/var
yes "header names the worktree and the others"      grep -q "^Worktree: .*/wt \[wt-branch\]" "$TMP/wt.txt"
yes "header lists the main checkout as other"       grep -q "other: .*\[feature/rename\]" "$TMP/wt.txt"
no  "output dir is git-ignored in the worktree"     sh -c "cd '$TMP/wt' && git status --short | grep -q '\.pr-grill'"
git worktree remove --force "$TMP/wt" 2>/dev/null

echo "# shallow clone without a merge-base"
git clone -q --depth 1 -b main "file://$REPO" "$TMP/shallow" 2>/dev/null
( cd "$TMP/shallow" && git fetch -q --depth 1 origin feature/rename 2>/dev/null && git checkout -q FETCH_HEAD \
  && bash "$SCRIPT" origin/main > /dev/null 2>"$TMP/shallow.err"; echo $? > "$TMP/shallow.code" )
yes "exits 1 without a merge-base"                 test "$(cat "$TMP/shallow.code")" = 1
yes "explains the shallow clone and the fix"       grep -q 'git fetch --unshallow' "$TMP/shallow.err"

echo "# unknown base lists local branches"
bash "$SCRIPT" no-such-branch > /dev/null 2>"$TMP/nobase.err"
yes "names the local branches"                     grep -q 'Local branches:.*feature/rename' "$TMP/nobase.err"

echo "# review-round mode: state, --since, --pr"
bash "$SCRIPT" main > /dev/null 2>&1
STATE="$OUTDIR/state"
yes "state records the current HEAD"      grep -q "^last_head=$(git rev-parse HEAD)$" "$STATE"
printf 'export function newName(a) {\n  return a + 1\n}\n' > src/lib.ts
git commit -qam "fix after review"
bash "$SCRIPT" main > "$TMP/after.txt" 2>&1
yes "default run mentions the previous run"  grep -q 'Previous run was at .* 1 commit(s) since' "$TMP/after.txt"
# fake gh: two thread roots, one on the fixed line, one on an untouched file
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '101\tsrc/lib.ts\t2\treviewer\tReturn a + 1 here\n102\tsrc/caller.ts\t1\treviewer\tRename the import\n'
FAKE
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH" bash "$SCRIPT" --since "$(git rev-parse HEAD~1)" --pr 9 main > "$TMP/round.txt" 2>&1
OUT="$TMP/round.txt"
yes "--since prints the review-round header"       grep -q '^## REVIEW ROUND: changes since' "$OUT"
yes "--since limits the stat to the fix"           in_section "Changed files (stat)" 'src/lib\.ts'
no  "--since leaves earlier files out"             in_section "Changed files (stat)" 'src/clock\.ts'
yes "thread on the fixed line is touched"          in_section "Review threads" '^- #101 src/lib\.ts:2 .* → touched$'
yes "thread on an untouched file says so"          in_section "Review threads" '^- #102 src/caller\.ts:1 .* → file untouched$'
PATH="$TMP/bin:$PATH" bash "$SCRIPT" --since last main > "$TMP/last.txt" 2>&1
yes "--since last uses the recorded HEAD"          grep -q 'HEAD is the reviewed commit itself' "$TMP/last.txt"
bash "$SCRIPT" --since deadbeef main > /dev/null 2>"$TMP/since.err"
yes "--since with an unknown commit fails clearly" grep -q 'is not a commit in this repository' "$TMP/since.err"
git checkout -q main && printf 'x\n' > elsewhere.txt && git add elsewhere.txt && git commit -qm "on main" && git checkout -q feature/rename
bash "$SCRIPT" --since main main > /dev/null 2>"$TMP/anc.err"
yes "--since with a non-ancestor explains rebase"  grep -q 'not an ancestor of HEAD' "$TMP/anc.err"
rm -f "$OUTDIR/state"
bash "$SCRIPT" --since last main > /dev/null 2>"$TMP/nostate.err"
yes "--since last without a state file explains"   grep -q 'needs a previous run' "$TMP/nostate.err"
OUT="$OUTDIR/summary.md"

echo "# hunk index and GitHub links"
git remote add origin git@github.com:acme/widgets.git
bash "$SCRIPT" --pr 7 main > "$TMP/hunks.txt" 2>&1
if command -v sha256sum >/dev/null 2>&1; then ANCHOR=$(printf '%s' "src/lib.ts" | sha256sum | cut -c1-64); else ANCHOR=$(printf '%s' "src/lib.ts" | shasum -a 256 | cut -c1-64); fi
yes "hunk line: single line first, then the range"  grep -q '^- src/lib\.ts:1 (1-2) (changed)' "$TMP/hunks.txt"
yes "blob permalink at HEAD"                        grep -q "blob: https://github.com/acme/widgets/blob/$(git rev-parse HEAD)/src/lib.ts#L1-L2" "$TMP/hunks.txt"
yes "change-notes budget scales with files"         grep -Eq '^Change notes budget: [0-9]+ \(1 per 3 changed files, min 3, max 10\)' "$TMP/hunks.txt"
yes "PR files-changed anchor is sha256 of the path" grep -q "pr: https://github.com/acme/widgets/pull/7/files#diff-${ANCHOR}R1" "$TMP/hunks.txt"
git remote remove origin
bash "$SCRIPT" main > "$TMP/nolinks.txt" 2>&1
yes "without a github remote: path:line only"       grep -q 'origin is not on github.com' "$TMP/nolinks.txt"

echo "# 0.2 layout migration and non-ignored custom output"
rm -rf "$REPO/.pr-grill"; mkdir -p "$REPO/.claude/pr-grill" && printf 'date=2026-01-01 branch=old nodes=1 code=1 author=0 approved=0 open=0 readiness=100 drill=- difficulty=- stumbled=- rounds=1 level=working\n' > "$REPO/.claude/pr-grill/stats.log"
bash "$SCRIPT" main > "$TMP/mig.txt" 2>&1
yes "old .claude/pr-grill is moved to .pr-grill"    test -f "$REPO/.pr-grill/stats.log"
no  "old directory is gone after the move"          test -e "$REPO/.claude/pr-grill"
yes "migration is announced"                        grep -q '^Note: moved .claude/pr-grill/' "$TMP/mig.txt"
yes "migrated record feeds the header"              grep -q '^Past PRs in this repo: 1' "$TMP/mig.txt"
bash "$SCRIPT" --out "$REPO/scratch-out" main > "$TMP/inrepo.txt" 2>&1
yes "custom --out inside the repo warns"            grep -q 'inside the repository and not git-ignored' "$TMP/inrepo.txt"
rm -rf "$REPO/scratch-out"

echo "# inferred author profile"
bash "$SCRIPT" main > "$TMP/prof.txt" 2>&1
yes "profile: wrote=self when every branch commit is the user's" grep -q '^wrote=self' "$TMP/prof.txt"
yes "profile: knows=some from the user's past commits"           grep -q '^knows=some (' "$TMP/prof.txt"
yes "header shows the reading plan"                              grep -Eq '^Reading plan: [0-9]+ files, [0-9]+ diff lines → ' "$TMP/prof.txt"
git commit -q --allow-empty -m "ai-assisted

Co-Authored-By: Claude <noreply@anthropic.com>"
bash "$SCRIPT" main > "$TMP/prof2.txt" 2>&1
yes "profile: wrote=ai from a Co-Authored-By trailer"            grep -q '^wrote=ai (1 commit' "$TMP/prof2.txt"
git -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "by someone else"
git -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "by someone else 2"
git -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "by someone else 3"
git -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "by someone else 4"
# branch now has 3 commits by the user (rename, fix, ai-assisted) and 4 by someone else
bash "$SCRIPT" main > "$TMP/prof3.txt" 2>&1
yes "profile: wrote=inherited when others wrote most commits"    grep -q '^wrote=inherited (4 of 7' "$TMP/prof3.txt"

echo "# battle record (pr_grill_stats.sh)"
STATS="$HERE/../skills/pr-grill/scripts/pr_grill_stats.sh"
export PR_GRILL_STATS_DIR="$TMP/stats"
yes "list before any record explains"       sh -c "bash '$STATS' list | grep -q 'No record yet'"
M=$(bash "$STATS" meter --nodes 10 --code 4 --author 4 --approved 1 --open 1)
yes "meter: readiness 85% with approved at half" sh -c "printf '%s' '$M' | grep -q 'Readiness ████████░░ 85%'"
bash "$STATS" record --branch feat/login --pr 12 --nodes 10 --code 4 --author 4 --approved 1 --open 1 --drill 5/2/1 --difficulty normal --stumbled ops,security > /dev/null
bash "$STATS" record --branch fix/cache --nodes 8 --code 6 --author 2 --approved 0 --open 0 --stumbled ops > /dev/null
bash "$STATS" record --branch feature/x --nodes 10 --code 5 --author 3 --approved 2 --open 0 --drill 6/1/1 --stumbled ops,tests --rounds 2 --level owner > /dev/null
yes "three records written"                 test "$(grep -c . "$TMP/stats/stats.log")" = 3
L=$(bash "$STATS" list)
yes "list shows readiness and drill"        sh -c "printf '%s' '$L' | grep -q 'feat/login.*12 .*85%.*5/8'"
yes "list shows rounds and level"           sh -c "printf '%s' '$L' | grep -q 'feature/x.*90%.*6/8.*2 .*owner'"
yes "list shows the rank"                   sh -c "printf '%s' '$L' | grep -q '^Rank: Regular'"
yes "level defaults to working"             sh -c "printf '%s' '$L' | grep -q 'fix/cache.*working'"
no  "record rejects a bad --level"          sh -c "bash '$STATS' record --branch b --nodes 1 --code 1 --author 0 --approved 0 --open 0 --level guru 2>/dev/null"
no  "record rejects counts that exceed nodes" sh -c "bash '$STATS' record --branch b --nodes 3 --code 2 --author 2 --approved 0 --open 0 2>/dev/null"
no  "record rejects a space in --stumbled"   sh -c "bash '$STATS' record --branch b --nodes 1 --code 1 --author 0 --approved 0 --open 0 --stumbled 'ops tests' 2>/dev/null"
yes "drill-only meter still shows the score" sh -c "bash '$STATS' meter --nodes 0 --code 0 --author 0 --approved 0 --drill 4/1/0 | grep -q 'no decision-tree nodes recorded.*Drill 4/5'"
yes "weak-lens trend finds ops (3 of 3)"    sh -c "printf '%s' '$L' | grep -q 'ops (3 of last 3)'"
no  "a lens hit once is not a trend"        sh -c "printf '%s' '$L' | grep -q 'security ('"
no  "record rejects a bad --drill"          sh -c "bash '$STATS' record --branch b --nodes 1 --code 1 --author 0 --approved 0 --open 0 --drill 5-2 2>/dev/null"
no  "record requires --branch"              sh -c "bash '$STATS' record --nodes 1 --code 1 --author 0 --approved 0 --open 0 2>/dev/null"
BN=$(COLUMNS=100 bash "$STATS" banner --branch feature/next --profile "wrote=ai · knows=some")
yes "banner: box with the branch and profile"   sh -c "printf '%s' '$BN' | grep -q '║  feature/next.*wrote=ai · knows=some'"
yes "banner: last readiness from the log"       sh -c "printf '%s' '$BN' | grep -q 'last PR: 90%'"
yes "banner: weak lens line"                    sh -c "printf '%s' '$BN' | grep -q 'weak lately: ops'"
yes "banner: rank from the record count"        sh -c "printf '%s' '$BN' | grep -q 'Regular ★ · 3 PR(s)'"
# display width: count each box/bar glyph as one column (bash substitution is bytewise, like the script's pad)
box_ok=1
while IFS= read -r ln; do
  t=${ln//█/x}; t=${t//░/x}; t=${t//←/x}; t=${t//·/x}; t=${t//═/x}; t=${t//★/x}
  t=${t//╔/x}; t=${t//╗/x}; t=${t//╚/x}; t=${t//╝/x}; t=${t//║/x}
  [ "${#t}" -eq 56 ] || box_ok=0
done <<EOF_BN
$BN
EOF_BN
yes "banner: every box line is 56 columns wide" test "$box_ok" = 1
yes "banner: 5 lines"                           test "$(printf '%s\n' "$BN" | wc -l | tr -d ' ')" = 5
BN1=$(COLUMNS=50 bash "$STATS" banner --branch feature/next)
yes "banner: one line when narrow"              test "$(printf '%s\n' "$BN1" | wc -l | tr -d ' ')" = 1
yes "banner: narrow line carries the same facts" sh -c "printf '%s' '$BN1' | grep -q 'feature/next.*last 90%.*weak: ops'"
no  "banner requires --branch"                  sh -c "bash '$STATS' banner 2>/dev/null"
# the collector surfaces the trend in its header when the log lives in the repo's .pr-grill
mkdir -p "$REPO/.pr-grill" && cp "$TMP/stats/stats.log" "$REPO/.pr-grill/stats.log"
unset PR_GRILL_STATS_DIR
bash "$SCRIPT" main > "$TMP/hdr.txt" 2>&1
yes "collector header shows past PRs and weak lenses" grep -q 'Past PRs in this repo: 3  weak lenses lately: ops (3 of last 3)' "$TMP/hdr.txt"
# records without stumbles must not turn "-" into a lens
export PR_GRILL_STATS_DIR="$TMP/stats"
printf 'date=2026-01-02 branch=a nodes=2 code=2 author=0 approved=0 open=0 readiness=100 drill=- difficulty=- stumbled=- rounds=1 level=working\n' >> "$TMP/stats/stats.log"
printf 'date=2026-01-03 branch=b nodes=2 code=2 author=0 approved=0 open=0 readiness=100 drill=- difficulty=- stumbled=- rounds=1 level=working\n' >> "$TMP/stats/stats.log"
no  "no-stumble records do not create a '-' trend" sh -c "bash '$STATS' list | grep -q -- '- ('"
unset PR_GRILL_STATS_DIR

echo "# with a test change"
printf 'test("y", () => {})\n' >> tests/lib.test.ts
bash "$SCRIPT" main > /dev/null 2>&1
yes "changed test file listed"            in_section "Test file changes" '^tests/lib\.test\.ts$'
no  "missing-tests note disappears"       in_out 'no test changes'

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
