# pr-grill

自分の PR を**レビューで守れる状態**にする Claude Code スキル。PR を出す前と、レビュー対応中に使う。

レビュアー向けではなく**作者向け**。差分を読み、影響範囲を追い、レビュアーが聞きそうな質問を予測する。そして他のツールがやらない部分——「コードから言えること」と「作者にしか分からないこと」を分け、作者に 1 問ずつインタビューして、すべての判断を自分の言葉で説明できるところまで持っていく。

[English README](README.md)

## 出力に付くラベル

生成される `PR_QA.md` の回答には必ず次のどれかが付く:

| ラベル | 意味 |
|---|---|
| `[コード根拠]` | 差分・周辺コード・テスト・git 履歴から事実として言える(`ファイル:行` 付き) |
| `[推測]` | 妥当な推測。根拠を一言添える |
| `[作者確認]` | 意図・トレードオフ・却下案など作者しか知らないこと。Claude は捏造しない |
| `[作者回答]` | 作者が自分の言葉で答えた(Grill 後) |
| `[作者承認]` | Claude の仮説に作者が同意しただけ。`[作者回答]` より弱く、そう明示される |

この分離が核。Claude がでっち上げた「理由」を作者がレビューで口にするのが最悪の結果なので、それを構造的に防ぐ。

## モード

| モード | 言い方 | やること |
|---|---|---|
| **Brief**(既定) | 「PR 出す前に確認したい」 | 変更の地図・振る舞いの差分・影響範囲・ラベル付き想定問答・独自チェック → `PR_QA.md` |
| **Grill** | 「詰めて」「意図を整理したい」 | `[作者確認]` を決定木の根から 1 問ずつ解消([grill-me](https://github.com/mattpocock/skills) の考え方を PR に適用) |
| **Drill** | 「試験して」「理解度チェック」 | 口頭試問。1 問ずつ出題しコードと照らして採点、弱点を列挙 |
| **Reply** | レビューコメントを貼る | コメントを分類し、根拠付きの返信案を作る(レビュアーが間違っている場合も含む) |

Brief の独自チェック: AI 生成コードの説明責任チェック(「この行が無いと何が壊れる?」)、Revert 思考実験、却下案台帳、深夜障害テスト、PR 説明文と差分の整合性、意図しない約束の検出、未実行チェックの列挙、CODEOWNERS からのレビュアー予測。

## インストール

```bash
npx skills add kenmori/pr-grill
```

手動:

```bash
git clone https://github.com/kenmori/pr-grill
cp -r pr-grill/skills/pr-grill ~/.claude/skills/pr-grill
```

必要なのは `git` と `bash`(3.2 以上。macOS 標準の bash で動く)だけ。`gh` があれば PR タイトル・本文・レビュアーも取る。

## 使い方

任意のリポジトリのフィーチャーブランチで:

```
> PR 出す前に確認したい
```

Claude が `scripts/collect_pr_context.sh` を実行し、`.claude/pr-grill/<ブランチ名>/PR_QA.md` を書き出す(`.git/info/exclude` に自動登録されるのでコミットされない)。最後に、未解消の最初の 1 問を Grill で詰めるか聞いてくる。

収集スクリプトは単体でも使える:

```bash
skills/pr-grill/scripts/collect_pr_context.sh [--out DIR] [--no-diff] [--stdout] [base-branch]
```

base の鮮度、未追跡ファイル、除外した生成物、テスト変更の有無、CODEOWNERS、要注意パターンと秘密情報らしき値(`ファイル:行` 付き)、変更されたシグネチャ、**差分外の呼び出し元**(更新し忘れたもの)、リポジトリのレビュー規約、レビュアーが「実行した?」と聞くチェックを出す。大きい差分は `diff/` にファイル別に分割される。

## 開発

```bash
shellcheck skills/pr-grill/scripts/collect_pr_context.sh tests/fixture.sh
tests/fixture.sh
```

`tests/fixture.sh` は、関数のリネーム・`console.log` の混入・ハードコードされた鍵・ネストした `dist/`・`clock.ts` という名前のソース(ロックファイル扱いしてはいけない)・未追跡ファイルを含む使い捨てリポジトリを作り、それぞれを正しく扱えることを検証する。

## クレジット

Grill モードは Matt Pocock の [grill-me](https://github.com/mattpocock/skills) の決定木インタビューを PR 向けに適用したもの。
