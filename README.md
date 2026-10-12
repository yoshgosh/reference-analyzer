# reference-analyzer

論文PDF・Webページを読解して要約し，Notion の References データベースへ登録する．
処理済みPDFは Citation Key に改名し，結果を Slack へ通知する．

仕様の正本は [HANDOVER.md](HANDOVER.md) である．本書は使い方と現状をまとめる．

## 現状

| 段階 | 内容 | 状態 |
|---|---|---|
| 1 | Claude Code で PDF 1本を手動処理 | 実装済み・**通し検証待ち** |
| 2 | 並列処理・失敗処理・記録・保存期間 | 完了（2本同時で混入なしを確認） |
| 3 | launchd による自動起動（inbox） | 実装済み・**成功例の確認待ち** |
| 4 | URL の手動処理 | 実装済み・検証待ち |
| 5 | Codex 対応 | 未実装 |

## 置き場所と macOS のプライバシー保護（重要）

データ一式は **`~/Research/Papers/`** に置く．`PAPER_ROOT` で変更できるが，
**`~/Documents`・`~/Desktop`・`~/Downloads` の配下には置いてはならない．**

launchd から起動したスクリプトは，これらのフォルダに対して次の非対称な制約を受ける
（macOS の TCC．実測で確認済み）．

| 操作 | 結果 |
|---|---|
| 列挙（`ls` / `find`） | **失敗**（Operation not permitted） |
| 既存ファイルの中身を読む | **失敗** |
| 特定パスの存在判定（`[ -e ]`） | 成功 |
| 書き込み・`mv` での配置 | 成功 |

列挙できないため inbox を走査できず，**エラーも出ず「対象なし」として静かに終わる**．
`auto_queue.sh` はこの区別がつくよう，対象が無い場合に inbox のパスと実ファイル数を記録する．

```
対象なし（inbox=/Users/you/Research/Papers/inbox 全 0 ファイル）   ← ファイルがあるのに 0 なら TCC
```

`/bin/bash` にフルディスクアクセスを与えれば `~/Documents` でも動くが，
bash で起動する全スクリプトが全ディスクへのアクセス権を得るため採らない．

## 準備

```sh
cp .env.example .env     # NOTION_DATA_SOURCE_ID と SLACK_WEBHOOK_URL を記入する
```

必要なもの．

- `claude` コマンド（PATH 上にあること）
- Notion MCP の認証 … `claude mcp add --transport http --scope user notion https://mcp.notion.com/mcp` の後，対話モードの `/mcp` で OAuth 認証（初回のみ・手動）
- poppler … `brew install poppler`（`pdftotext`, `pdfimages`, `pdftoppm`）

`claude mcp list` で `notion: ✔ Connected` を確認できる．

## 使い方

```sh
bin/ref paper.pdf              # PDF を処理する（移動せず，その場で改名する）
bin/ref ~/Downloads/papers/    # フォルダ直下の *.pdf を処理する（再帰しない）
bin/ref https://arxiv.org/...  # Webページ・GitHubリポジトリ等を処理する
bin/ref a.pdf b.pdf <URL>      # 混在してよい
```

自動処理は `~/Research/Papers/inbox/` に PDF を置くと走る（launchd が検知する）．

### 手動と自動の違い

| | 手動（`bin/ref`） | 自動（inbox） |
|---|---|---|
| 成功時のファイル | **元の場所で改名するだけ**（移動しない） | `PAPER_ROOT` 直下へ移動 |
| 失敗時のファイル | **触らない**（元のまま） | `failed/` へ移動 |

## 自動起動（launchd）

```sh
launchd/install.sh install     # 登録する（事前確認つき）
launchd/install.sh status      # 状態・埋め込んだ claude のパスの有効性・最近のログ
launchd/install.sh uninstall   # 解除する
```

`WatchPaths` で inbox の変化を検知する．launchd は対話シェルの環境を引き継がないため，
導入時の `claude` の実パスを `PATH` の先頭に埋め込む．Node を入れ替えてパスが変わった場合は
`status` が検出するので，再導入する．

launchd は同じジョブを二重に起動しない．`RunAtLoad` を有効にしているため，
停止中に置かれたPDFもログイン時に処理される．

## 構成

```
bin/ref                 手動の入口．引数を PDF／フォルダ／URL に振り分ける
lib/core.sh             【共有】環境・混入ガード・プロンプト組立・AI起動・検証・記録
lib/engine_claude.sh    claude -p の呼び出し
lib/validate_result.py  AI の最終出力の検証と正規化
lib/manual_one.sh       手動1本：ロック → 作業用コピー → core → その場で改名
lib/auto_one.sh         自動1本：アトミック mv で確保 → core → PAPER_ROOT か failed/ へ
lib/auto_queue.sh       自動の入口：inbox を走査し並列で配る（launchd から起動される）
launchd/install.sh      launchd エージェントの導入・解除・状態確認
lib/notify_slack.sh     Slack 通知
lib/cleanup.sh          保存期間を過ぎた記録の削除
prompts/registration.md 指示文の正本（現行の claude.ai プロジェクト指示文）
prompts/headless_addendum.md  無人実行用の追加ルール（混入防止・JSON出力）
schema/result.schema.json     AI の最終出力スキーマ
config/mcp.json         AI に見せる MCP サーバー（notion のみ）
```

`lib/core.sh` は自動・手動の両方から source する唯一の共有実装である．
対象ファイルの確保と最終的な配置だけが経路ごとに分かれており，
ユーザーのファイルに触るコードは各経路の出口に閉じている．

## 混入防止

「論文同士の情報が混ざってはならない」が最重要要件である．次の多重の手当てで担保する．

1. 資料1本につき AI のプロセスを新規に起動する（`--continue` 等は使わない）．
2. 資料1本ごとに専用の作業ディレクトリを作り，AI のカレントディレクトリにする．
3. `--restricted` によりファイルツールを作業ディレクトリに限定する．
   作業ディレクトリ外の `Read` は拒否される（実測で確認済み）．
4. `--strict-mcp-config` ＋ `--mcp-config` により Notion 以外の MCP（claude.ai コネクタ等）を遮断する．
5. AI には対象PDFの**コピー**のみを見せ，元ファイルには触れさせない．
6. 起動時に作業ディレクトリの祖先の `CLAUDE.md` を検査し，あれば警告をログと Slack に出す．
7. `prompts/headless_addendum.md` で，対象1本のみを扱うこと・Web検索結果はタイトル／著者／DOI の一致を
   確認したものだけ使うことを明示する．

## 同時実行数の制御

システム全体で同時に走る AI プロセスを `PAPER_PARALLEL`（既定2）個に抑える．

制御点は `lib/core.sh` の `ra_process` 1箇所だけであり，AI の起動直前に枠（slot）を取り，
終了後に解放する．自動・手動のどちらの経路も，起動回数がいくつでも，総量は一定になる．

```
.work/.locks/slots/slot-1, slot-2, …   ← mkdir のアトミック性で排他する．中に PID を書く
```

launchd は同じジョブを二重に起動しないが，自動キューと手動 `bin/ref` は別プロセスなので
重なりうる．キューの数を1つに制限するのではなく枠の総数を抑えることで，
経路の組み合わせに関わらず上限が保たれる．

異常終了で枠が残った場合は，枠に書いた PID の生存を確認して回収する
（生きているプロセスの枠は奪わない）．

## 実行記録

`PAPER_LOG_DIR/<run_id>/` に保存する（既定 7 日で削除）．

| ファイル | 内容 |
|---|---|
| `run.log` | 開始・終了，対象，エンジン，終了コード，配置先 |
| `result.json` | 検証・正規化済みの最終出力 |
| `engine_raw.json` | エンジンの生出力（`session_id`，コスト等を含む） |
| `transcript.jsonl` | AI の実行記録（ツール呼び出しの経過） |
| `prompt.md` | 実際に渡した指示文 |
| `engine.stderr` | エンジンの標準エラー出力 |

成功時は作業ディレクトリを削除し，失敗時は調査用に残す（保存期間の削除対象に含める）．

## 環境変数

[HANDOVER.md §5](HANDOVER.md) を参照．`.env` に書く．
