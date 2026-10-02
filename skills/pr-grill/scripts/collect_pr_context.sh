#!/usr/bin/env bash
# Collect PR context using git only (no extra installs; works on bash 3.2 / BSD grep).
#
# Usage: collect_pr_context.sh [options] [base-branch]
#   --out DIR    output directory (default: <repo>/.claude/pr-grill/<branch>)
#   --no-diff    do not write per-file patches (diff/*.patch)
#   --stdout     always print the full diff to stdout (default: only when <= 600 lines)
#   -h, --help   this help
#
# Base branch defaults to origin/HEAD -> origin/main -> main -> origin/master -> master -> develop.
# Output: the summary on stdout, plus <out>/summary.md, <out>/full.diff, <out>/diff/<path>.patch
set -uo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

OUT=""; WRITE_DIFF=1; FORCE_STDOUT=0; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --no-diff) WRITE_DIFF=0; shift ;;
    --stdout) FORCE_STDOUT=1; shift ;;
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
[ -z "$BASE" ] && { echo "ERROR: pass the base branch as an argument" >&2; exit 1; }
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "ERROR: branch not found: $BASE" >&2; exit 1; }

MB=$(git merge-base "$BASE" HEAD) || { echo "ERROR: no merge-base between $BASE and HEAD" >&2; exit 1; }
HEAD_NAME=$(git rev-parse --abbrev-ref HEAD)

# ---- output directory -----------------------------------------------------
SLUG=$(printf '%s' "$HEAD_NAME" | sed 's#/#__#g')
[ -z "$OUT" ] && OUT="$ROOT/.claude/pr-grill/$SLUG"
mkdir -p "$OUT" || exit 1
rm -rf "$OUT/diff"; [ "$WRITE_DIFF" = 1 ] && mkdir -p "$OUT/diff"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"

# Keep the default output directory out of commits via .git/info/exclude (never touches tracked files)
case "$OUT" in
  "$ROOT/.claude/pr-grill"*)
    EXCL="$ROOT/.git/info/exclude"
    if ! grep -qs '^\.claude/pr-grill/$' "$EXCL" 2>/dev/null; then
      mkdir -p "$(dirname "$EXCL")" && echo '.claude/pr-grill/' >> "$EXCL"
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
out "## BASE: $BASE  HEAD: $HEAD_NAME  merge-base: ${MB:0:8}"
BASE_TS=$(git log -1 --format=%ct "$BASE"); NOW_TS=$(date +%s)
BASE_AGE=$(( (NOW_TS - BASE_TS) / 86400 ))
out "Latest commit on base: $(git log -1 --format='%h %cd' --date=short "$BASE") (${BASE_AGE} days ago)"
[ "$BASE_AGE" -gt 7 ] && out "⚠ The base is ${BASE_AGE} days old. Without \`git fetch origin\`, other people's merged work will show up in this diff."
out "Output: $OUT"

section "Uncommitted changes (git status)"
git status --short | pipe "(none)"

section "Untracked files (⚠ NOT included in the diff below; reviewers always ask about new files)"
git ls-files --others --exclude-standard | grep -v "^${OUT#"$ROOT"/}/" | pipe "(none)"

section "Commits"
git log --no-merges --format='- %h %s (%an, %ad)' --date=short "$MB"..HEAD | pipe "(no commits since base; uncommitted changes only)"

section "Changed files (stat)"
git diff -M --stat=120 "$MB" -- . "${EXCLUDE[@]}" | pipe
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

section "Secret-shaped values (⚠ check these first)"
{
  grep -Ei "(password|passwd|secret|api[_-]?key|access[_-]?key|token|bearer|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{6,}" "$ADDED"
  grep -E "AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{36}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.eyJ" "$ADDED"
  printf '%s\n' "$CHANGED" | grep -E '(^|/)\.env(\.|$)|\.(pem|p12|pfx|key)$' | sed 's/$/  <- the file itself needs a look/'
} | sort -u | pipe

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
if [ "$FORCE_STDOUT" = 1 ] || [ "$DIFF_LINES" -le 600 ]; then
  out "" '```diff'; cat "$OUT/full.diff" | tee -a "$SUMMARY"; out '```'
else
  out "" "(${DIFF_LINES} lines is too large for stdout. Read the per-file patches above, essential changes first.)"
fi
