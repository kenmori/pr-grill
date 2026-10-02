#!/usr/bin/env bash
# PR の文脈を git だけで収集する(追加インストール不要。bash 3.2 / BSD grep 対応)
#
# 使い方: collect_pr_context.sh [options] [base-branch]
#   --out DIR    出力先ディレクトリ(既定: <repo>/.claude/pr-grill/<branch>)
#   --no-diff    ファイル別パッチ(diff/*.patch)を書き出さない
#   --stdout     差分本体も必ず stdout に出す(既定は 600 行以下のときだけ)
#   -h, --help   このヘルプ
#
# base 省略時は origin/HEAD → origin/main → main → origin/master → master → develop の順で自動判定。
# 出力: stdout に summary.md と同じ内容。<out>/summary.md, <out>/full.diff, <out>/diff/<path>.patch
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
    -*) echo "ERROR: 不明なオプション: $1" >&2; usage >&2; exit 2 ;;
    *) BASE="$1"; shift ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: git リポジトリ内で実行してください" >&2; exit 1
fi
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 1

# ---- base ブランチ判定 ----------------------------------------------------
if [ -z "$BASE" ]; then
  BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  for c in origin/main main origin/master master develop; do
    [ -n "$BASE" ] && break
    git rev-parse --verify --quiet "$c^{commit}" >/dev/null && BASE="$c"
  done
fi
[ -z "$BASE" ] && { echo "ERROR: base ブランチを引数で指定してください" >&2; exit 1; }
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "ERROR: ブランチが見つかりません: $BASE" >&2; exit 1; }

MB=$(git merge-base "$BASE" HEAD) || { echo "ERROR: $BASE と HEAD の merge-base が取れません" >&2; exit 1; }
HEAD_NAME=$(git rev-parse --abbrev-ref HEAD)

# ---- 出力先 -------------------------------------------------------------
SLUG=$(printf '%s' "$HEAD_NAME" | sed 's#/#__#g')
[ -z "$OUT" ] && OUT="$ROOT/.claude/pr-grill/$SLUG"
mkdir -p "$OUT" || exit 1
rm -rf "$OUT/diff"; [ "$WRITE_DIFF" = 1 ] && mkdir -p "$OUT/diff"
SUMMARY="$OUT/summary.md"
: > "$SUMMARY"

# 既定の出力先はコミットしないよう .git/info/exclude に登録する(リポジトリのファイルは触らない)
case "$OUT" in
  "$ROOT/.claude/pr-grill"*)
    EXCL="$ROOT/.git/info/exclude"
    if ! grep -qs '^\.claude/pr-grill/$' "$EXCL" 2>/dev/null; then
      mkdir -p "$(dirname "$EXCL")" && echo '.claude/pr-grill/' >> "$EXCL"
    fi ;;
esac

# 生成物・ロックファイルの除外(ファイル名に lock を含むだけのソースは除外しない)
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
# stdin をそのまま summary + stdout へ。空なら代替文を出す
pipe() { local body; body=$(cat); if [ -n "$body" ]; then out "$body"; else out "${1:-(なし)}"; fi; }

# 変更ファイル一覧(除外後)。rename は新パスで扱う
CHANGED=$(git diff -M --name-only "$MB" -- . "${EXCLUDE[@]}")
CHANGED_FILE="$OUT/changed_files.txt"; printf '%s\n' "$CHANGED" > "$CHANGED_FILE"

# ---- ヘッダ -------------------------------------------------------------
out "## BASE: $BASE  HEAD: $HEAD_NAME  merge-base: ${MB:0:8}"
BASE_TS=$(git log -1 --format=%ct "$BASE"); NOW_TS=$(date +%s)
BASE_AGE=$(( (NOW_TS - BASE_TS) / 86400 ))
out "base の最新コミット: $(git log -1 --format='%h %cd' --date=short "$BASE")(${BASE_AGE}日前)"
[ "$BASE_AGE" -gt 7 ] && out "⚠ base が ${BASE_AGE} 日前で止まっています。\`git fetch origin\` していないと、他人のマージ済み変更が差分に混ざります"
out "出力先: $OUT"

section "未コミットの変更(git status)"
git status --short | pipe "(なし)"

section "未追跡ファイル(⚠ 以下の差分には含まれていない。新規ファイルの意図はレビューで必ず聞かれる)"
git ls-files --others --exclude-standard | grep -v "^${OUT#"$ROOT"/}/" | pipe "(なし)"

section "コミット"
git log --no-merges --format='- %h %s (%an, %ad)' --date=short "$MB"..HEAD | pipe "(base から分岐したコミットなし。未コミットの変更のみ)"

section "変更ファイル(統計)"
git diff -M --stat=120 "$MB" -- . "${EXCLUDE[@]}" | pipe
section "新規・削除・リネーム・モード変更"
git diff -M --summary "$MB" -- . "${EXCLUDE[@]}" | pipe "(なし)"

section "除外したファイル(ロック・生成物・スナップショット)"
comm -23 <(git diff -M --name-only "$MB" | sort) <(printf '%s\n' "$CHANGED" | sort) | pipe "(なし)"

section "テストファイルの変更"
printf '%s\n' "$CHANGED" | grep -Ei '(^|/)(test|tests|spec|specs|__tests__)(/|$)|[._-](test|spec)\.[a-z]+$|_test\.(go|rs|py|rb)$|^tests?_.*\.py$' \
  | pipe "(テストの変更なし ← 想定質問の候補)"

# ---- レビュアー --------------------------------------------------------
section "CODEOWNERS(近似マッチ。最後に一致した行が優先)"
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
      # shellcheck disable=SC2254  # CODEOWNERS のパターンを glob として使うのが目的
      if [ "$anchored" = 1 ] || [ "${pat#*/}" != "$pat" ]; then
        case "$f" in $pat|$pat/*) owners="$rest" ;; esac
      else
        case "$f" in $pat|$pat/*|*/$pat|*/$pat/*) owners="$rest" ;; esac
      fi
    done < "$CO"
    echo "- $f → ${owners:-(担当なし)}"
  done | pipe
else
  out "(CODEOWNERS なし)"
fi

section "変更ファイルの主な過去作者(上位3名。先頭15ファイル)"
printf '%s\n' "$CHANGED" | head -15 | while read -r f; do
  [ -z "$f" ] && continue
  a=$(git log -n 200 --format=%an "$MB" -- "$f" 2>/dev/null | sort | uniq -c | sort -rn | head -3 | awk '{c=$1; $1=""; sub(/^ /,""); printf "%s(%s) ", $0, c}')
  echo "- $f: ${a:-(新規)}"
done | pipe

# ---- 追加行を file:line 付きで取り出す ---------------------------------------
ADDED="$OUT/added_lines.txt"
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" | awk '
  /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); next }
  /^@@/      { m = $0; sub(/^@@ -[0-9]*(,[0-9]*)? \+/, "", m); sub(/[ ,].*/, "", m); n = m + 0; next }
  /^\+/      { print f ":" n ": " substr($0, 2); n++ }
' > "$ADDED"

W='(^|[^A-Za-z0-9_])'   # 単語境界(BSD grep でも動く形)
section "要注意パターン(追加行のみ。file:line)"
{
  grep -E "${W}(console\.(log|debug|dir|trace)|debugger|breakpoint\(|pdb\.set_trace|binding\.pry|var_dump|dd\()${W}?" "$ADDED"
  grep -E "\.(only|skip)\(|${W}(xit|xdescribe|fit|fdescribe)\(" "$ADDED"
  grep -E "${W}(TODO|FIXME|XXX|HACK)${W}?" "$ADDED"
  grep -E "eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error|${W}as any${W}?|# *noqa|# *type: *ignore|#\[allow\(|nolint|rubocop:disable" "$ADDED"
  grep -E "${W}(localhost|127\.0\.0\.1|0\.0\.0\.0)${W}?|https?://[^\"' ]*\.(local|internal|test)${W}?" "$ADDED"
  grep -E '^[^:]*\.py:[0-9]+: .*(^|[^A-Za-z0-9_.])print\(' "$ADDED"
} | sort -u | pipe

section "秘密情報らしき値(⚠ 最優先で確認)"
{
  grep -Ei "(password|passwd|secret|api[_-]?key|access[_-]?key|token|bearer|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{6,}" "$ADDED"
  grep -E "AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{36}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.eyJ" "$ADDED"
  printf '%s\n' "$CHANGED" | grep -E '(^|/)\.env(\.|$)|\.(pem|p12|pfx|key)$' | sed 's/$/  ← ファイル自体が要確認/'
} | sort -u | pipe

# ---- シグネチャと呼び出し元 ---------------------------------------------------
SIG='(export |function |def |class |func |fn |fun |interface |type |struct |enum |trait |impl |const [A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*(:[^=]*)?=[[:space:]]*(\(|async|function))'
section "変更された関数・export のシグネチャ(削除/追加行。先頭80件)"
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" \
  | grep -E "^[-+][^-+].*$SIG" | head -80 | pipe

section "呼び出し元候補(シグネチャが変わった/消えた識別子を git grep。定義ファイル自身は除く)"
git diff -M -U0 "$MB" -- . "${EXCLUDE[@]}" | awk '
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
                                       { print $0 (($1 in c) ? "" : "   ← 差分外(更新されていない可能性)") }')
  total=$(printf '%s' "$hits" | grep -c .)
  echo "### $id(定義: $deffile)"
  if [ "$total" -eq 0 ]; then echo "(参照なし — 削除済み or 未使用 or 動的参照)"; else
    printf '%s\n' "$hits" | head -8; [ "$total" -gt 8 ] && echo "… 他 $((total - 8)) 件"; fi
done | pipe "(なし)"
[ "$IDS_TOTAL" -gt 25 ] && out "… 他 $((IDS_TOTAL - 25)) 識別子は省略($OUT/identifiers.txt)"

# ---- リポジトリの規約・チェック ---------------------------------------------
section "このリポジトリのレビュー規約・テンプレート(あれば読むこと)"
for f in .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md PULL_REQUEST_TEMPLATE.md docs/PULL_REQUEST_TEMPLATE.md \
         CONTRIBUTING.md .github/CONTRIBUTING.md CLAUDE.md REVIEW.md .github/REVIEW.md AGENTS.md; do
  [ -f "$f" ] && echo "- $f"
done | pipe "(なし)"

section "レビュアーが「実行した?」と聞くチェック(候補。実行結果は含まれていない)"
{
  [ -f package.json ] && grep -oE '"(test|test:[a-z]+|lint|typecheck|type-check|check|format:check|build)"[[:space:]]*:' package.json | sed 's/[":[:space:]]//g; s/^/- npm run /'
  [ -f Makefile ] && grep -oE '^(test|lint|check|typecheck)[a-z-]*:' Makefile | sed 's/:$//; s/^/- make /'
  [ -f Cargo.toml ] && echo "- cargo test / cargo clippy"
  [ -f go.mod ] && echo "- go test ./... / go vet ./..."
  { [ -f pyproject.toml ] || [ -f setup.py ] || [ -f pytest.ini ]; } && echo "- pytest"
  [ -f Gemfile ] && echo "- bundle exec rspec / rubocop"
  for w in .github/workflows/*.yml .github/workflows/*.yaml; do [ -f "$w" ] && echo "- CI: $w"; done
} | pipe "(検出できず)"

# ---- 差分本体 --------------------------------------------------------------
git diff -M "$MB" -- . "${EXCLUDE[@]}" > "$OUT/full.diff"
DIFF_LINES=$(wc -l < "$OUT/full.diff" | tr -d ' ')
section "差分本体(${DIFF_LINES} 行)"
if [ "$WRITE_DIFF" = 1 ]; then
  printf '%s\n' "$CHANGED" | while read -r f; do
    [ -z "$f" ] && continue
    p="$OUT/diff/$(printf '%s' "$f" | sed 's#/#__#g').patch"
    git diff -M "$MB" -- "$f" > "$p"
    echo "- $f → $p($(wc -l < "$p" | tr -d ' ') 行)"
  done | pipe
fi
out "全体: $OUT/full.diff"
if [ "$FORCE_STDOUT" = 1 ] || [ "$DIFF_LINES" -le 600 ]; then
  out "" '```diff'; cat "$OUT/full.diff" | tee -a "$SUMMARY"; out '```'
else
  out "" "(${DIFF_LINES} 行と大きいので stdout には出していない。上のファイル別パッチを本質的変更から順に読むこと)"
fi
