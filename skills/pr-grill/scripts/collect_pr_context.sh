#!/usr/bin/env bash
# Collect PR context using git only (no extra installs; works on bash 3.2 / BSD grep).
#
# Usage: collect_pr_context.sh [options] [base-branch]
#   --out DIR    output directory (default: <repo>/.pr-grill/<branch>)
#   --no-diff    do not write per-file patches (diff/*.patch)
#   --stdout     always print the full diff to stdout (default: only when <= 300 lines)
#   --since REF  review-round mode: diff from REF (a commit, or "last" = the HEAD recorded by the
#                previous run) instead of from the merge-base. Use after pushing fixes for a review.
#   --pr N       with gh installed: list PR #N's review threads and whether the diff touches each one
#   -h, --help   this help
#
# Base branch defaults to origin/HEAD -> origin/main -> main -> origin/master -> master -> develop.
# Output: the summary on stdout, plus <out>/summary.md, <out>/full.diff, <out>/diff/<path>.patch
set -uo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

OUT=""; WRITE_DIFF=1; FORCE_STDOUT=0; BASE=""; SINCE=""; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --no-diff) WRITE_DIFF=0; shift ;;
    --stdout) FORCE_STDOUT=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --pr=*) PR="${1#--pr=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) BASE="$1"; shift ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: run this inside a git repository" >&2; exit 1
fi
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 1

# ---- base branch ----------------------------------------------------------
if [ -z "$BASE" ]; then
  BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  for c in origin/main main origin/master master develop; do
    [ -n "$BASE" ] && break
    git rev-parse --verify --quiet "$c^{commit}" >/dev/null && BASE="$c"
  done
fi
if [ -z "$BASE" ]; then
  echo "ERROR: could not guess the base branch (tried origin/HEAD, origin/main, main, origin/master, master, develop)." >&2
  echo "       Pass it explicitly, e.g.: collect_pr_context.sh origin/develop" >&2
  exit 1
fi
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "ERROR: branch not found: $BASE" >&2
  echo "       Local branches: $(git branch --format='%(refname:short)' | tr '\n' ' ')" >&2
  echo "       If it only exists on the remote, run: git fetch origin $BASE" >&2
  exit 1
fi

SHALLOW=$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)
if ! MB=$(git merge-base "$BASE" HEAD 2>/dev/null); then
  echo "ERROR: no merge-base between $BASE and HEAD." >&2
  if [ "$SHALLOW" = true ]; then
    echo "       This is a shallow clone, so the history that joins the two branches is missing. Run: git fetch --unshallow" >&2
  else
    echo "       The branches share no history. Check that $BASE is the branch this work was started from." >&2
  fi
  exit 1
fi
HEAD_NAME=$(git rev-parse --abbrev-ref HEAD)

# ---- output directory -----------------------------------------------------
SLUG=$(printf '%s' "$HEAD_NAME" | sed 's#/#__#g')
[ -z "$OUT" ] && OUT="${PR_GRILL_DIR:-$ROOT/.pr-grill}/$SLUG"   # PR_GRILL_DIR moves all output (and the stats log) elsewhere

# ---- review-round mode (--since) ------------------------------------------------
# The diff base becomes the reviewed commit, so every section below describes only what changed
# in response to the review. The merge-base stays in FULL_MB for the header.
FULL_MB="$MB"; SINCE_SHA=""
if [ -n "$SINCE" ]; then
  if [ "$SINCE" = last ]; then
    STATE_FILE="$OUT/state"
    if [ ! -f "$STATE_FILE" ]; then
      echo "ERROR: --since last needs a previous run, but $STATE_FILE does not exist." >&2
      echo "       Run once without --since first, or pass the reviewed commit: --since <sha>" >&2
      exit 1
    fi
    SINCE=$(sed -n 's/^last_head=//p' "$STATE_FILE")
  fi
  if ! SINCE_SHA=$(git rev-parse --verify --quiet "$SINCE^{commit}"); then
    echo "ERROR: --since $SINCE is not a commit in this repository." >&2; exit 1
  fi
  if ! git merge-base --is-ancestor "$SINCE_SHA" HEAD; then
    echo "ERROR: --since ${SINCE_SHA:0:8} is not an ancestor of HEAD, so 'what changed since then' has no meaning." >&2
    echo "       If the branch was rebased or amended after the review, pass the pre-rebase commit from the PR's timeline." >&2
    exit 1
  fi
  MB="$SINCE_SHA"
fi
mkdir -p "$OUT" || { echo "ERROR: cannot create the output directory $OUT (use --out DIR to pick another)" >&2; exit 1; }
# Only remove what a previous run wrote (never rm -rf a user-supplied --out path)
rm -f "$OUT"/diff/*.patch 2>/dev/null; rmdir "$OUT/diff" 2>/dev/null
[ "$WRITE_DIFF" = 1 ] && mkdir -p "$OUT/diff"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"

# Keep the default output directory out of commits via the shared info/exclude (never touches tracked files).
# --git-path resolves correctly inside a linked worktree, where $ROOT/.git is a file, not a directory.
EXCL_WARN=""
case "$OUT" in
  "$ROOT/.pr-grill"*)   # only the in-repo default needs git-ignoring
    EXCL=$(git rev-parse --git-path info/exclude)
    if ! grep -qs '^\.pr-grill/$' "$EXCL" 2>/dev/null; then
      if ! { mkdir -p "$(dirname "$EXCL")" && echo '.pr-grill/' >> "$EXCL"; } 2>/dev/null; then
        EXCL_WARN="⚠ Could not write $EXCL. The output directory .pr-grill/ is NOT git-ignored; do not commit it."
      fi
    fi ;;
esac

# Generated files and lockfiles (a source file merely named *lock* is NOT excluded)
EXCLUDE=(
  ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/yarn.lock' ':(exclude,glob)**/pnpm-lock.yaml'
  ':(exclude,glob)**/bun.lockb' ':(exclude,glob)**/Cargo.lock' ':(exclude,glob)**/Gemfile.lock'
  ':(exclude,glob)**/poetry.lock' ':(exclude,glob)**/composer.lock' ':(exclude,glob)**/go.sum'
  ':(exclude,glob)**/*.lock' ':(exclude,glob)**/*.snap' ':(exclude,glob)**/__snapshots__/**'
  ':(exclude,glob)**/dist/**' ':(exclude,glob)**/build/**' ':(exclude,glob)**/*.min.*'
  ':(exclude,glob)**/*.generated.*' ':(exclude,glob)**/*.map'
)

out() { printf '%s\n' "$@" | tee -a "$SUMMARY"; }
section() { out "" "## $1"; }
# stdin -> summary + stdout; print a fallback when empty
pipe() { local body; body=$(cat); if [ -n "$body" ]; then out "$body"; else out "${1:-(none)}"; fi; }

# Changed files after exclusions. Renames are listed under the new path.
CHANGED=$(git diff -M --name-only "$MB" -- . "${EXCLUDE[@]}")
CHANGED_FILE="$OUT/changed_files.txt"; printf '%s\n' "$CHANGED" > "$CHANGED_FILE"

# ---- header -------------------------------------------------------------
if [ -n "$SINCE_SHA" ]; then
  out "## REVIEW ROUND: changes since ${SINCE_SHA:0:8} ($(git log -1 --format='%s, %cd' --date=short "$SINCE_SHA"))" \
      "BASE: $BASE  HEAD: $HEAD_NAME  merge-base: ${FULL_MB:0:8}  (every section below covers only the delta since ${SINCE_SHA:0:8})"
  [ "$SINCE_SHA" = "$(git rev-parse HEAD)" ] && out "⚠ HEAD is the reviewed commit itself: nothing has been committed since. Only uncommitted changes are shown."
else
  out "## BASE: $BASE  HEAD: $HEAD_NAME  merge-base: ${MB:0:8}"
fi
if [ -z "$SINCE_SHA" ] && [ -f "$OUT/state" ]; then
  PREV=$(sed -n 's/^last_head=//p' "$OUT/state")
  if [ -n "$PREV" ] && git rev-parse --verify --quiet "$PREV^{commit}" >/dev/null && [ "$PREV" != "$(git rev-parse HEAD)" ]; then
    N_SINCE=$(git rev-list --count "$PREV"..HEAD 2>/dev/null || echo "?")
    out "Previous run was at ${PREV:0:8} ($(sed -n 's/^last_run=//p' "$OUT/state")); $N_SINCE commit(s) since. For a review-round delta: --since last"
  fi
fi
BASE_TS=$(git log -1 --format=%ct "$BASE"); NOW_TS=$(date +%s)
BASE_AGE=$(( (NOW_TS - BASE_TS) / 86400 ))
out "Latest commit on base: $(git log -1 --format='%h %cd' --date=short "$BASE") (${BASE_AGE} days ago)"
[ "$BASE_AGE" -gt 7 ] && out "⚠ The base is ${BASE_AGE} days old. Without \`git fetch origin\`, other people's merged work will show up in this diff."
[ "$SHALLOW" = true ] && out "⚠ Shallow clone: commit history and past-author data are incomplete. \`git fetch --unshallow\` gives the full picture."
if [ "$(git rev-parse "$BASE")" = "$(git rev-parse HEAD)" ]; then
  out "⚠ HEAD is at the same commit as $BASE: you are on the base branch (or nothing has been committed on top of it)." \
      "  Only uncommitted changes can be reviewed. Switch to the feature branch or its worktree if that is not what you meant."
fi
WT_COUNT=$(git worktree list 2>/dev/null | grep -c .)
if [ "$WT_COUNT" -gt 1 ]; then
  out "Worktree: $ROOT [$HEAD_NAME]"
  git worktree list | grep -v "^$ROOT " | sed 's/^/  other: /' | tee -a "$SUMMARY"
fi
[ -n "$EXCL_WARN" ] && out "$EXCL_WARN"
# Past battles in this repo: lenses the author stumbled on recently come first in the Q&A
STATS_SH="$(dirname "$0")/pr_grill_stats.sh"
STATS_DIR_EFF="${PR_GRILL_DIR:-$ROOT/.pr-grill}"
if [ -x "$STATS_SH" ] && [ -f "$STATS_DIR_EFF/stats.log" ]; then
  WEAK=$(PR_GRILL_STATS_DIR="$STATS_DIR_EFF" "$STATS_SH" weak | tr '\n' ';' | sed 's/;$//; s/;/; /g')
  out "Past PRs in this repo: $(grep -c . "$STATS_DIR_EFF/stats.log")${WEAK:+  weak lenses lately: $WEAK  <- lead the Q&A with these}"
fi
DIFF_LINES=$(git diff -M "$MB" -- . "${EXCLUDE[@]}" | wc -l | tr -d ' ')
N_FILES=$(printf '%s\n' "$CHANGED" | grep -c .)
if [ "$DIFF_LINES" -le 300 ]; then PLAN="inline (printed at the end of this summary)"; else PLAN="per-file patches under diff/ — read essential changes first"; fi
out "Reading plan: $N_FILES files, $DIFF_LINES diff lines → $PLAN"
out "Output: $OUT"

# Who the author is, inferred from git so the skill does not have to ask:
#   wrote  = self | ai | inherited   (branch commits by others, or AI co-author trailers)
#   knows  = new | some | owner      (past commits by the current user on the changed files)
ME=$(git config user.email 2>/dev/null || true)
BR_MINE=0; BR_OTHERS=0; BR_AI=0; PAST=0
if [ -n "$ME" ]; then
  BR_MINE=$(git log --format=%ae "$FULL_MB"..HEAD | grep -cxF "$ME")
  BR_OTHERS=$(git log --format=%ae "$FULL_MB"..HEAD | grep -cvxF "$ME")
  BR_AI=$(git log --format=%B "$FULL_MB"..HEAD | grep -ciE '^co-authored-by:.*(claude|copilot|cursor|codex|gpt|gemini|devin|aider)')
  # shellcheck disable=SC2086  # CHANGED is a newline-separated list of paths without spaces in practice
  [ -n "$CHANGED" ] && PAST=$(printf '%s\n' "$CHANGED" | xargs git log -n 500 --format=%ae "$FULL_MB" -- 2>/dev/null | grep -cxF "$ME")
fi
if [ "$BR_OTHERS" -gt "$BR_MINE" ]; then WROTE="inherited ($BR_OTHERS of $((BR_MINE + BR_OTHERS)) branch commits by others)"
elif [ "$BR_AI" -gt 0 ]; then WROTE="ai ($BR_AI commit(s) carry an AI co-author trailer)"
else WROTE="self"; fi
if [ "$PAST" -ge 5 ]; then KNOWS="owner ($PAST past commits by you on these files)"
elif [ "$PAST" -ge 1 ]; then KNOWS="some ($PAST past commit(s) by you on these files)"
else KNOWS="new (no past commits by you on these files)"; fi
section "Author profile (inferred from git; the author can correct it in one line)"
out "wrote=$WROTE" "knows=$KNOWS"

section "Uncommitted changes (git status)"
git status --short | pipe "(none)"

section "Untracked files (⚠ NOT included in the diff below; reviewers always ask about new files)"
git ls-files --others --exclude-standard | grep -v "^${OUT#"$ROOT"/}/" | pipe "(none)"

section "Commits"
git log --no-merges --format='- %h %s (%an, %ad)' --date=short "$MB"..HEAD | pipe "(no commits since base; uncommitted changes only)"

section "Changed files (stat)"
git diff -M --stat=120 "$MB" -- . "${EXCLUDE[@]}" | pipe "(nothing changed since ${SINCE_SHA:+${SINCE_SHA:0:8}}${SINCE_SHA:-$BASE} after exclusions: no new commits and no edits in the working tree)"
section "Added / deleted / renamed / mode changes"
git diff -M --summary "$MB" -- . "${EXCLUDE[@]}" | pipe "(none)"

section "Excluded files (lockfiles, generated, snapshots)"
comm -23 <(git diff -M --name-only "$MB" | sort) <(printf '%s\n' "$CHANGED" | sort) | pipe "(none)"

section "Test file changes"
printf '%s\n' "$CHANGED" | grep -Ei '(^|/)(test|tests|spec|specs|__tests__)(/|$)|[._-](test|spec)\.[a-z]+$|_test\.(go|rs|py|rb)$|^tests?_.*\.py$' \
  | pipe "(no test changes <- expect a question about this)"

# ---- reviewers --------------------------------------------------------
section "CODEOWNERS (approximate match; last matching line wins)"
CO=""
for c in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do [ -f "$c" ] && { CO="$c"; break; }; done
if [ -n "$CO" ]; then
  printf '%s\n' "$CHANGED" | while read -r f; do
    [ -z "$f" ] && continue
    owners=""
    while read -r pat rest; do
      case "$pat" in ''|'#'*) continue ;; esac
      anchored=0; case "$pat" in /*) anchored=1; pat="${pat#/}" ;; esac
      case "$pat" in */) pat="${pat}*" ;; esac
      # shellcheck disable=SC2254  # CODEOWNERS patterns are meant to be used as globs
      if [ "$anchored" = 1 ] || [ "${pat#*/}" != "$pat" ]; then
        case "$f" in $pat|$pat/*) owners="$rest" ;; esac
      else
        case "$f" in $pat|$pat/*|*/$pat|*/$pat/*) owners="$rest" ;; esac
      fi
    done < "$CO"
    echo "- $f → ${owners:-(no owner)}"
  done | pipe
else
  out "(no CODEOWNERS)"
fi

section "Top past authors of changed files (top 3; first 15 files)"
printf '%s\n' "$CHANGED" | head -15 | while read -r f; do
  [ -z "$f" ] && continue
  a=$(git log -n 200 --format=%an "$MB" -- "$f" 2>/dev/null | sort | uniq -c | sort -rn | head -3 | awk '{c=$1; $1=""; sub(/^ /,""); printf "%s(%s) ", $0, c}')
  echo "- $f: ${a:-(new file)}"
done | pipe

# ---- added lines with file:line --------------------------------------------
ADDED="$OUT/added_lines.txt"
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" | awk '
  /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); next }
  /^@@/      { m = $0; sub(/^@@ -[0-9]*(,[0-9]*)? \+/, "", m); sub(/[ ,].*/, "", m); n = m + 0; next }
  /^\+/      { print f ":" n ": " substr($0, 2); n++ }
' > "$ADDED"

W='(^|[^A-Za-z0-9_])'   # word boundary that BSD grep understands
section "Suspicious patterns (added lines only, file:line)"
{
  grep -E "${W}(console\.(log|debug|dir|trace)|debugger|breakpoint\(|pdb\.set_trace|binding\.pry|var_dump|dd\()${W}?" "$ADDED"
  grep -E "\.(only|skip)\(|${W}(xit|xdescribe|fit|fdescribe)\(" "$ADDED"
  grep -E "${W}(TODO|FIXME|XXX|HACK)${W}?" "$ADDED"
  grep -E "eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error|${W}as any${W}?|# *noqa|# *type: *ignore|#\[allow\(|nolint|rubocop:disable" "$ADDED"
  grep -E "${W}(localhost|127\.0\.0\.1|0\.0\.0\.0)${W}?|https?://[^\"' ]*\.(local|internal|test)${W}?" "$ADDED"
  grep -E '^[^:]*\.py:[0-9]+: .*(^|[^A-Za-z0-9_.])print\(' "$ADDED"
} | sort -u | pipe

section "Secret-shaped values (⚠ check these first; values are masked here but NOT in full.diff / diff/*.patch)"
# Keep a 4-character prefix so the author can find the line; never echo the whole value into the summary
mask() {
  sed -E \
    -e "s/(AKIA[0-9A-Z]{4}|ghp_[A-Za-z0-9]{4}|github_pat_[A-Za-z0-9_]{4}|gh[ousr]_[A-Za-z0-9]{4}|sk-[A-Za-z0-9_-]{4}|xox[baprs]-[A-Za-z0-9-]{4}|AIza[0-9A-Za-z_-]{4}|eyJ[A-Za-z0-9_-]{4})[A-Za-z0-9_.-]*/\1…[masked]/g" \
    -e "s/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1 …[masked]/" \
    -e "s/([:=][[:space:]]*[\"'][^\"']{4})[^\"']{2,}([\"'])/\1…[masked]\2/g"
}
{
  grep -Ei "(password|passwd|secret|api[_-]?key|access[_-]?key|token|bearer|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{6,}" "$ADDED"
  grep -E "AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{36}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.eyJ" "$ADDED"
  printf '%s\n' "$CHANGED" | grep -E '(^|/)\.env(\.|$)|\.(pem|p12|pfx|key)$' | sed 's/$/  <- the file itself needs a look/'
} | sort -u | mask | pipe

# ---- signatures and callers ---------------------------------------------------
SIG='(export |function |def |class |func |fn |fun |interface |type |struct |enum |trait |impl |const [A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*(:[^=]*)?=[[:space:]]*(\(|async|function))'
# Prose files are skipped here: "type fixes" in a README is not a signature
PROSE=(':(exclude,glob)**/*.md' ':(exclude,glob)**/*.markdown' ':(exclude,glob)**/*.txt' ':(exclude,glob)**/*.rst')
section "Changed function / export signatures (removed/added lines; first 80; code files only)"
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" "${PROSE[@]}" \
  | grep -E "^[-+][^-+].*$SIG" | head -80 | pipe

section "Caller candidates (git grep for identifiers whose signature changed or was removed; defining file excluded)"
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" "${PROSE[@]}" | awk '
  /^--- / { f = $0; sub(/^--- a\//, "", f); next }
  /^-/ && !/^---/ {
    line = substr($0, 2)
    if (match(line, /(function|def|class|func|fn|fun|const|let|var|type|interface|struct|enum|trait)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
      s = substr(line, RSTART, RLENGTH); sub(/^[a-z]+[[:space:]]+/, "", s)
      if (length(s) >= 3 && !(s in seen)) { seen[s] = 1; print f "\t" s }
    }
  }' > "$OUT/identifiers.txt"
IDS_TOTAL=$(wc -l < "$OUT/identifiers.txt" | tr -d ' ')
head -25 "$OUT/identifiers.txt" | while IFS="$(printf '\t')" read -r deffile id; do
  hits=$(git grep -n -w "$id" -- . "${EXCLUDE[@]}" 2>/dev/null | grep -v "^$deffile:" \
    | awk -F: -v cf="$CHANGED_FILE" 'BEGIN { while ((getline l < cf) > 0) c[l] = 1 }
                                       { print $0 (($1 in c) ? "" : "   <- outside diff (possibly not updated)") }')
  total=$(printf '%s' "$hits" | grep -c .)
  echo "### $id (defined in $deffile)"
  if [ "$total" -eq 0 ]; then echo "(no references: removed, unused, or referenced dynamically)"; else
    printf '%s\n' "$hits" | head -8; [ "$total" -gt 8 ] && echo "… $((total - 8)) more"; fi
done | pipe "(none)"
[ "$IDS_TOTAL" -gt 25 ] && out "… $((IDS_TOTAL - 25)) more identifiers omitted ($OUT/identifiers.txt)"

# ---- repository conventions and checks ---------------------------------------------
# ---- hunk index with links (for the Change notes) -------------------------------
# GitHub "Files changed" anchors are #diff-<sha256 of the path>R<new-side line>; blob permalinks need only HEAD.
sha256_hex() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi; }
REMOTE=$(git remote get-url origin 2>/dev/null || true)
GH_REPO=""
case "$REMOTE" in
  git@github.com:*)   GH_REPO="${REMOTE#git@github.com:}" ;;
  https://github.com/*) GH_REPO="${REMOTE#https://github.com/}" ;;
  ssh://git@github.com/*) GH_REPO="${REMOTE#ssh://git@github.com/}" ;;
esac
GH_REPO="${GH_REPO%.git}"; GH_REPO="${GH_REPO%/}"
HEAD_SHA=$(git rev-parse HEAD)
section "Hunks (new-side lines; pick the ones that matter for the Change notes, up to the budget below)"
if [ -n "$GH_REPO" ]; then
  out "Link base: https://github.com/$GH_REPO  (PR anchors need --pr N; blob permalinks use HEAD ${HEAD_SHA:0:8})"
else
  out "(origin is not on github.com: no links, path:line only)"
fi
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" | awk '
  /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); next }
  /^@@/ { m = $0; sub(/^@@ -[0-9]*(,[0-9]*)? \+/, "", m); sub(/ .*/, "", m); split(m, p, ","); n = p[1] + 0; c = (p[2] == "") ? 1 : p[2] + 0
          if (c == 0) print f "\t" n "\t" n "\tdeleted"; else print f "\t" n "\t" (n + c - 1) "\tchanged" }
' > "$OUT/hunks.tsv"
HUNK_TOTAL=$(wc -l < "$OUT/hunks.tsv" | tr -d ' ')
# How many Change-notes lines the PR deserves: proportional to the number of changed files, bounded
BUDGET=$(( (N_FILES + 2) / 3 )); [ "$BUDGET" -lt 3 ] && BUDGET=3; [ "$BUDGET" -gt 10 ] && BUDGET=10
[ "$HUNK_TOTAL" -lt "$BUDGET" ] && BUDGET="$HUNK_TOTAL"
out "Change notes budget: $BUDGET (1 per 3 changed files, min 3, max 10) of $HUNK_TOTAL hunks"
head -60 "$OUT/hunks.tsv" | while IFS="$(printf '\t')" read -r hf hs he hk; do
  [ -z "$hf" ] && continue
  if [ "$hs" = "$he" ]; then range="$hs"; lr="L$hs"; else range="$hs-$he"; lr="L$hs-L$he"; fi
  line="- $hf:$range ($hk)"
  if [ -n "$GH_REPO" ]; then
    anchor=$(printf '%s' "$hf" | sha256_hex)
    line="$line  blob: https://github.com/$GH_REPO/blob/$HEAD_SHA/$hf#$lr"
    [ -n "$PR" ] && line="$line  pr: https://github.com/$GH_REPO/pull/$PR/files#diff-${anchor}R$hs"
  fi
  echo "$line"
done | pipe "(no hunks)"
[ "$HUNK_TOTAL" -gt 60 ] && out "… $((HUNK_TOTAL - 60)) more hunks in $OUT/hunks.tsv"

# ---- review threads vs. the diff (--pr) ---------------------------------------
if [ -n "$PR" ]; then
  section "Review threads on PR #$PR vs. this diff (thread roots only; 'touched' = the diff edits within 3 lines of the comment)"
  if ! command -v gh >/dev/null 2>&1; then
    out "(gh is not installed, so the threads could not be fetched. Paste the review comments instead.)"
  elif ! THREADS=$(gh api "repos/{owner}/{repo}/pulls/$PR/comments" --paginate \
        --jq '.[] | select(.in_reply_to_id == null) | [.id, .path, (.line // .original_line // 0), .user.login, (.body | gsub("[\n\r\t]+"; " ") | .[0:140])] | @tsv' 2>&1); then
    out "(gh api failed: $(printf '%s' "$THREADS" | head -3 | tr '\n' ' '))" \
        "(Common causes: not logged in -> gh auth login; wrong PR number; no network. Paste the comments instead.)"
  elif [ -z "$THREADS" ]; then
    out "(no review comments on PR #$PR)"
  else
    printf '%s\n' "$THREADS" | while IFS="$(printf '\t')" read -r cid cpath cline cauthor cbody; do
      [ -z "$cid" ] && continue
      status="file untouched"
      if printf '%s\n' "$CHANGED" | grep -qxF "$cpath"; then
        status="file touched, not at this line"
        # Old-side hunk ranges in the delta: the reviewed commit's line numbers, which is what the comment refers to
        git diff -M -U0 "$MB" -- "$cpath" | sed -nE 's/^@@ -([0-9]+)(,([0-9]+))? .*/\1 \3/p' | while read -r hs hc; do
          hc=${hc:-1}; [ "$hc" -eq 0 ] && hc=1; he=$((hs + hc - 1))
          if [ "$cline" -ge $((hs - 3)) ] && [ "$cline" -le $((he + 3)) ]; then echo touched; fi
        done | grep -q touched && status="touched"
      fi
      echo "- #$cid $cpath:$cline (@$cauthor) → $status"
      echo "  \"$cbody\""
    done | pipe "(none)"
  fi
fi

section "Review conventions and templates in this repo (read them if present)"
for f in .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md PULL_REQUEST_TEMPLATE.md docs/PULL_REQUEST_TEMPLATE.md \
         CONTRIBUTING.md .github/CONTRIBUTING.md CLAUDE.md REVIEW.md .github/REVIEW.md AGENTS.md; do
  [ -f "$f" ] && echo "- $f"
done | pipe "(none)"

section "Checks reviewers will ask whether you ran (candidates; results NOT included)"
{
  [ -f package.json ] && grep -oE '"(test|test:[a-z]+|lint|typecheck|type-check|check|format:check|build)"[[:space:]]*:' package.json | sed 's/[":[:space:]]//g; s/^/- npm run /'
  [ -f Makefile ] && grep -oE '^(test|lint|check|typecheck)[a-z-]*:' Makefile | sed 's/:$//; s/^/- make /'
  [ -f Cargo.toml ] && echo "- cargo test / cargo clippy"
  [ -f go.mod ] && echo "- go test ./... / go vet ./..."
  { [ -f pyproject.toml ] || [ -f setup.py ] || [ -f pytest.ini ]; } && echo "- pytest"
  [ -f Gemfile ] && echo "- bundle exec rspec / rubocop"
  for w in .github/workflows/*.yml .github/workflows/*.yaml; do [ -f "$w" ] && echo "- CI: $w"; done
} | pipe "(nothing detected)"

# ---- diff --------------------------------------------------------------
git diff -M "$MB" -- . "${EXCLUDE[@]}" > "$OUT/full.diff"
DIFF_LINES=$(wc -l < "$OUT/full.diff" | tr -d ' ')
section "Diff (${DIFF_LINES} lines)"
if [ "$WRITE_DIFF" = 1 ]; then
  printf '%s\n' "$CHANGED" | while read -r f; do
    [ -z "$f" ] && continue
    p="$OUT/diff/$(printf '%s' "$f" | sed 's#/#__#g').patch"
    git diff -M "$MB" -- "$f" > "$p"
    echo "- $f → $p ($(wc -l < "$p" | tr -d ' ') lines)"
  done | pipe
fi
out "Full diff: $OUT/full.diff"
# Remember this run so the next one can offer --since last
printf 'last_head=%s\nlast_run=%s\nbase=%s\n' "$(git rev-parse HEAD)" "$(date '+%Y-%m-%d %H:%M')" "$BASE" > "$OUT/state"
if [ "$FORCE_STDOUT" = 1 ] || [ "$DIFF_LINES" -le 300 ]; then
  out "" '```diff'; cat "$OUT/full.diff" | tee -a "$SUMMARY"; out '```'
else
  out "" "(${DIFF_LINES} lines is too large for stdout. Read the per-file patches above, essential changes first.)"
fi
