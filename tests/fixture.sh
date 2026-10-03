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
printf 'console.log("dbg")\nconst apiKey = "sk-abcdefghijklmnopqrstuvwxyz"\nconst token = "hardcoded-token"\nexport const tick = () => 2\n' > src/clock.ts
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
OUTDIR="$REPO/.claude/pr-grill/feature__rename"; OUT="$OUTDIR/summary.md"
if [ -f "$OUT" ]; then ok "summary.md is written"; else fail "summary.md missing ($OUTDIR)"; exit 1; fi
yes "stdout matches summary.md" diff -q "$OUT" "$STDOUT"

echo "# must detect"
yes "caller of renamed function flagged as outside the diff" in_out 'src/caller\.ts:.*oldName.*outside diff'
yes "console.log reported with file:line"                     in_section "Suspicious patterns" '^src/clock\.ts:1: console\.log'
yes "sk- shaped key detected and masked"                      in_section "Secret-shaped values" '^src/clock\.ts:2: .*sk-a…\[masked\]'
no  "sk- key value is not echoed"                             in_section "Secret-shaped values" 'sk-abcdefghij'
yes "token = \"literal\" detected and masked"                 in_section "Secret-shaped values" '^src/clock\.ts:3: .*"hard…\[masked\]"'
no  "token value is not echoed"                               in_section "Secret-shaped values" 'hardcoded-token'
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
no  "output dir ignored via .git/info/exclude"  sh -c "cd '$REPO' && git status --short | grep -q '\.claude/pr-grill'"

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
no  "output dir is git-ignored in the worktree"     sh -c "cd '$TMP/wt' && git status --short | grep -q '\.claude/pr-grill'"
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

echo "# with a test change"
printf 'test("y", () => {})\n' >> tests/lib.test.ts
bash "$SCRIPT" main > /dev/null 2>&1
yes "changed test file listed"            in_section "Test file changes" '^tests/lib\.test\.ts$'
no  "missing-tests note disappears"       in_out 'no test changes'

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
