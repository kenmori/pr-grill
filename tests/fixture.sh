#!/usr/bin/env bash
# collect_pr_context.sh の回帰テスト。一時リポジトリを作って出力を検証する。
# 使い方: tests/fixture.sh   (終了コード 0 = 全件 pass)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../skills/pr-grill/scripts/collect_pr_context.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pr-grill-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
# yes <説明> <コマンド...>: コマンドが成功すべき / no: 失敗すべき
yes() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
no()  { local d="$1"; shift; if "$@"; then fail "$d"; else ok "$d"; fi; }
# セクション見出しから次の見出しまでを取り出す
section() { awk -v h="## $1" 'index($0, h) == 1 { p = 1; next } /^## / { p = 0 } p' "$OUT"; }
in_section() { section "$1" | grep -Eq "$2"; }
in_out() { grep -Eq "$1" "$OUT"; }

# ---- 一時リポジトリ -------------------------------------------------------
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
# 1. 関数リネーム(呼び出し元 src/caller.ts は更新しない)
sed -i.bak 's/oldName/newName/' src/lib.ts && rm src/lib.ts.bak
# 2. console.log・秘密情報の混入。ファイル名に lock を含むソース
printf 'console.log("dbg")\nconst apiKey = "sk-abcdefghijklmnopqrstuvwxyz"\nconst token = "hardcoded-token"\nexport const tick = () => 2\n' > src/clock.ts
# 3. 'token' という単語を含むだけのコード(秘密情報ではない)
printf 'export const tokenize = (s: string) => s.split(" ")\n' > src/tokenizer.ts
# 4. ネストした dist とロックファイル(除外されるべき)
printf 'new bundle\n' > packages/x/dist/bundle.js
printf '{"name":"x","lockfileVersion":3,"changed":true}\n' > package-lock.json
git add -A; git commit -qm "rename oldName to newName"
# 5. 未追跡ファイル(テスト未変更)
printf 'export const fresh = 1\n' > src/brand_new.ts

# ---- 実行 ----------------------------------------------------------------
echo "# 既定の出力先で実行"
STDOUT="$TMP/stdout.txt"
bash "$SCRIPT" main > "$STDOUT" 2>"$TMP/stderr.txt"; CODE=$?
if [ "$CODE" -eq 0 ]; then ok "exit code 0"; else fail "exit code $CODE"; cat "$TMP/stderr.txt"; fi
OUTDIR="$REPO/.claude/pr-grill/feature__rename"; OUT="$OUTDIR/summary.md"
if [ -f "$OUT" ]; then ok "summary.md が生成される"; else fail "summary.md がない($OUTDIR)"; exit 1; fi
yes "stdout と summary.md が一致" diff -q "$OUT" "$STDOUT"

echo "# 検出すべきもの"
yes "リネームした関数の未更新の呼び出し元を差分外として指摘" in_out 'src/caller\.ts:.*oldName.*差分外'
yes "console.log を file:line 付きで検出"                   in_section "要注意パターン" '^src/clock\.ts:1: console\.log'
yes "sk- 形式の鍵を検出"                                     in_section "秘密情報らしき値" '^src/clock\.ts:2: .*sk-abcdef'
yes "token = \"literal\" を検出"                             in_section "秘密情報らしき値" '^src/clock\.ts:3: .*hardcoded-token'
yes "テスト未変更を指摘"                                     in_out 'テストの変更なし'
yes "未追跡ファイルを列挙"                                   in_section "未追跡ファイル" '^src/brand_new\.ts$'
yes "CODEOWNERS を近似マッチ(後勝ち)"                       in_section "CODEOWNERS" '^- src/lib\.ts → @team-src'
yes "package.json の test/lint を列挙"                      in_out '^- npm run test'
yes "ファイル別パッチへの導線"                               in_out 'src__lib\.ts\.patch'
yes "ファイル別パッチが存在"                                 test -f "$OUTDIR/diff/src__lib.ts.patch"

echo "# 誤検出してはいけないもの"
yes "clock.ts は lock ファイル扱いされない"   in_section "変更ファイル(統計)" 'src/clock\.ts'
no  "ネストした dist が統計に出ない"           in_section "変更ファイル(統計)" 'packages/x/dist'
no  "package-lock.json が統計に出ない"         in_section "変更ファイル(統計)" 'package-lock\.json'
yes "除外一覧に dist が載る"                   in_section "除外したファイル" 'packages/x/dist/bundle\.js'
no  "除外一覧に clock.ts は載らない"           in_section "除外したファイル" 'clock'
no  "tokenizer は要注意扱いされない"           in_section "要注意パターン" 'tokenizer'
no  "tokenizer は秘密情報扱いされない"         in_section "秘密情報らしき値" 'tokenizer'
no  "定義ファイル自身は呼び出し元から除く"     in_section "呼び出し元候補" '^src/lib\.ts:'
no  "出力先は .git/info/exclude で無視される"  sh -c "cd '$REPO' && git status --short | grep -q '\.claude/pr-grill'"

echo "# オプション"
bash "$SCRIPT" --out "$TMP/custom" --no-diff main > /dev/null 2>&1
yes "--out で出力先を変更"      test -f "$TMP/custom/summary.md"
yes "--no-diff でパッチを書かない" test ! -d "$TMP/custom/diff"
yes "--help"                     sh -c "bash '$SCRIPT' --help | grep -q -- --out"
no  "存在しない base は失敗"     sh -c "bash '$SCRIPT' no-such-branch 2>/dev/null"
no  "git リポジトリ外は失敗"     sh -c "cd '$TMP' && bash '$SCRIPT' 2>/dev/null"

echo "# テストファイル変更あり"
printf 'test("y", () => {})\n' >> tests/lib.test.ts
bash "$SCRIPT" main > /dev/null 2>&1
yes "テストファイルの変更を列挙" in_section "テストファイルの変更" '^tests/lib\.test\.ts$'
no  "テスト未変更の指摘が消える" in_out 'テストの変更なし'

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
