# reference-analyzer

論文PDF・Webページを読解して要約し，Notion の References データベースへ登録する．
処理済みPDFは Citation Key に改名し，結果を Slack へ通知する．

設計の経緯と仕様の背景は [HANDOVER.md](HANDOVER.md) にある．
ただし実装にあたって変更した点があり（§4 の保存先，§7.2 の起動コマンド），
**動作の正本は本書とコードである**．差分は「仕様からの変更」に記す．

## 現状

| 段階 | 内容 | 状態 |
|---|---|---|
| 1 | Claude Code で PDF 1本を手動処理 | 完了 |
| 2 | 並列処理・失敗処理・記録・保存期間 | 完了（2本同時で混入なしを確認） |
| 3 | launchd による自動起動（inbox） | 完了 |
| 4 | URL の手動処理 | 実装済み・**検証待ち** |
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

```
~/Research/Papers/          ← PAPER_ROOT
  Smith2024Example.pdf      ← 処理済みPDF（直下に並ぶ）
  inbox/                    ← 自動処理の置き場（launchd が監視）
  failed/                   ← 失敗したPDF
  .work/                    ← 1実行ごとの作業ディレクトリ
  .logs/                    ← 実行記録（保存期間あり）
```

## 準備

```sh
cp .env.example .env     # NOTION_DATA_SOURCE_ID と SLACK_WEBHOOK_URL を記入する
```

必要なもの．

- `claude` コマンド（PATH 上にあること）
- Notion MCP の認証 … `claude mcp add --transport http --scope user notion https://mcp.notion.com/mcp` の後，
  **対話モードの `/mcp` で OAuth 認証**（初回のみ・手動．非対話では認証できない）
- poppler … `brew install poppler`（`pdftotext`, `pdfimages`, `pdftoppm`, `pdfinfo`）

`claude mcp list` で `notion: ✔ Connected` を確認できる．
`launchd/install.sh status` でも一括して確認できる．

## 使い方

**1コマンド = 1文献 = AI プロセス1回 = Notion 1ページ**である．

```sh
bin/ref paper.pdf                    # PDF を1本処理する
bin/ref https://arxiv.org/abs/...    # Webページ・GitHubリポジトリ等を処理する
```

同じ文献を補助する資料を添えられる．ファイル・フォルダ・URL を混在できる．

```sh
bin/ref paper.pdf --with appendix.pdf
bin/ref paper.pdf --with supp/ https://github.com/owner/repo
bin/ref https://arxiv.org/abs/... --with notes.md
```

フォルダを渡しても順次処理はしない．**同じ文献を補助する資料としてまとめて1度の AI プロセスに渡す**．

2本の文献を登録したいときは `ref` を2回実行する．`--with` を付けずに2つ目を渡すと
エラーになる（黙って1つ目の補助資料として扱うと，別の文献の情報が同じページに混ざるため）．

```sh
bin/ref a.pdf b.pdf      # エラー
```

自動処理は `~/Research/Papers/inbox/` に PDF を置くと走る（launchd が検知する）．
inbox は単体PDFのみで，補助資料は付けられない．

### 手動と自動の違い

| | 手動（`bin/ref`） | 自動（inbox） |
|---|---|---|
| 対象の数 | 1コマンドに1つ（＋補助資料） | inbox にある全件 |
| 補助資料 | 付けられる（`--with`） | 付けられない |
| 配分の並列 | なし（1コマンド1プロセス） | あり |
| 対象の確保 | コピー（原本は動かさない） | アトミックな `mv` |
| 成功時のファイル | **元の場所で改名するだけ**（移動しない） | 改名して `PAPER_ROOT` 直下へ移動 |
| 失敗時のファイル | **触らない**（元のまま） | `failed/<run_id>_<元名>` へ移動 |

非対称なのは意図的である．自動は inbox にファイルを残すと次の変化で再処理され，
失敗を繰り返して通知が溜まる．手動はユーザーが明示的に指したファイルなので，
失敗時に別の場所へ移すと驚きが大きく，再処理のループも起きない．

### inbox の取り込み条件

- 拡張子 `.pdf` のみ（大文字小文字を区別しない）
- 隠しファイル，`.icloud`，`.crdownload`，`.download`，`.part`，`.partial`，`.tmp` は無視する
- **サイズが `PAPER_SETTLE_SECONDS`（既定2秒）変化しないことを確認してから取り込む**
  （ダウンロードやコピーの途中のファイルを掴まないため）
- 処理の終了後に inbox を再走査する（処理中に追加された分を取りこぼさない）

## 自動起動（launchd）

```sh
launchd/install.sh install     # 登録する（事前確認つき）
launchd/install.sh status      # 状態・埋め込んだ claude のパスの有効性・最近のログ
launchd/install.sh uninstall   # 解除する
```

`WatchPaths` で inbox の変化を検知する．launchd は対話シェルの環境変数・PATH を
引き継がないため，導入時の `claude` の実パスを `PATH` の先頭に埋め込む．
nvm 等で Node を入れ替えてパスが変わった場合は `status` が検出するので，再導入する．

launchd は同じジョブを二重に起動しない．`RunAtLoad` を有効にしているため，
停止中に置かれたPDFもログイン時に処理される．

## AI の実行環境

`claude -p` を資料1本ごとに新規起動する．渡すフラグの意図は
[lib/engine_claude.sh](lib/engine_claude.sh) の冒頭に記している．

AI が実行できるコマンドは次に限られる（許可リスト外は確認待ちにならず拒否される）．

```
pdftotext  pdfimages  pdftoppm  pdfinfo  curl
```

- **1回の呼び出しで1コマンド**にする必要がある．`;` による連結は全体が拒否される
- パイプ（`|`）は使える
- `python3` は意図的に許可していない（後述の「既知の制約」）

一覧は [lib/engine_claude.sh](lib/engine_claude.sh)（実際の許可）と
[prompts/headless_addendum.md](prompts/headless_addendum.md)（AI への告知）の
2箇所にあり，変更時は両方を直す必要がある．

### モデルと effort

```
PAPER_MODEL=opus      # opus / sonnet / fable / haiku
PAPER_EFFORT=medium   # low / medium / high / xhigh / max
```

**明示的に固定している．** `--restricted` は user/project/local の設定ファイルを
無視するため，指定しないと CLI の組み込み既定に依存し，更新で静かに変わる．
実行記録の1行目に `model=` と `effort=` が入るので，後から遡れる．

サブスクリプション認証で動くため，`engine_raw.json` の `total_cost_usd` は
リスト価格への換算値であって請求額ではない（`costBasis=list`）．
実際の制約はプランの利用上限で，1本あたり Opus 換算で $1 相当を消費する．
節約が必要なら `PAPER_MODEL=sonnet` に落とせる．

## 構成

```
入口
  bin/ref                 手動の入口（対象1つ ＋ --with 補助資料）
  lib/scan_inbox.sh       inbox を走査し，1件ごとにワーカーを起動（launchd から）
  lib/process_inbox.sh    inbox の1件を処理する

共有
  lib/run_one.sh          1資源の処理の流れ（骨格）
  lib/analyze.sh          プロンプト組立 → エンジン起動 → 出力検証
  lib/place.sh            改名と移動
  lib/core.sh             環境・ログ・ロック・同時実行の枠・混入ガード

部品
  lib/engine_claude.sh    claude -p の呼び出し
  lib/notify_slack.sh     Slack 通知
  lib/validate_result.py  最終出力の検証と正規化
  lib/cleanup.sh          保存期間を過ぎた記録の削除
  launchd/install.sh      launchd エージェントの導入・解除・状態確認

指示文・設定
  prompts/registration.md       指示文の正本（現行の claude.ai プロジェクト指示文）
  prompts/headless_addendum.md  無人実行用の追加ルール（混入防止・補助資料・コマンド制約・JSON出力）
  schema/result.schema.json     AI の最終出力スキーマ
  config/mcp.json               AI に見せる MCP サーバー（notion のみ）
```

### 流れと差し替え点

処理の流れは `lib/run_one.sh` の1箇所にあり，経路ごとに違うのは**2つの関数だけ**である．
呼び出し側（`bin/ref` と `lib/process_inbox.sh`）がこれを定義して差し替える．

```
run_one()
  枠を取る → 実行ディレクトリ作成 → 混入ガード
  → prepare_target   ← 経路ごと（手動=コピー／自動=mv で確保）
  → analyze          ← 共有
  → place_result     ← 経路ごと（手動=原本を改名／自動=改名して移動）
  → 記録 → 通知 → 枠を解放 → 片付け
```

**ユーザーのファイルに触る処理は `lib/place.sh` だけに閉じている**（`rename_to_key` と `move_into`）．
`lib/analyze.sh` と `lib/core.sh` はファイルの改名・移動を行わない．

一意な名前の決定は「最終的な置き場所に着地させる関数」が行う．
手動は `rename_to_key` が原本のディレクトリ内で解決し，
自動は作業ディレクトリ内で改名したうえで `move_into` が `PAPER_ROOT` で解決する．
そのため自動では，`PAPER_ROOT` に同名があれば最終的に `<Key>_2.pdf` になる．

エンジン差分は `lib/engine_<名前>.sh` に閉じているので，
Codex 対応は共有部分に手を入れずに追加できる．

### 並列と run_id

自動は1件ごとに `lib/process_inbox.sh` を**別プロセスとして**起動する．
`run_id` の末尾がプロセスID（`$$`）であり，bash ではサブシェルでも `$$` が親のままで，
`BASHPID` は bash 4.0 以降（macOS は 3.2）にしか無い．
サブシェルで並列化すると同時起動した2本が同じ `run_id` を持ち，
作業ディレクトリと記録を共有してしまう．

## 混入防止

「論文同士の情報が混ざってはならない」が最重要要件である．次の多重の手当てで担保する．

| 層 | 手段 |
|---|---|
| プロセス | 資料1本につき新規に起動する（`--continue`・`--resume` は使わない） |
| 作業領域 | 資料1本ごとに専用ディレクトリを作り，AI のカレントディレクトリにする |
| 設定 | `--restricted` で user/project/local の設定ファイルを無視する |
| MCP | `--strict-mcp-config` ＋ `--mcp-config` で Notion 以外（claude.ai コネクタ等）を遮断する |
| ファイルツール | `--restricted` で `Read`/`Write`/`Glob`/`Grep` を作業ディレクトリに限定する |
| コマンド | 許可リスト外を拒否する．`od`・`head`・`grep` 等も作業ディレクトリ外では拒否される |
| 元ファイル | AI には対象PDFの**コピー**のみを見せ，元ファイルには触れさせない |
| 足場ファイル | `prompt.md` 等は記録ディレクトリ側に書き，作業ディレクトリには対象と `aux/` だけを置く |
| 起動時検査 | 作業ディレクトリの祖先の `CLAUDE.md` を探し，あれば警告をログと Slack に出す |
| 指示文 | 対象1本のみを扱うこと，Web検索結果はタイトル／著者／DOI の一致を確認したものだけ使うことを明示する |

検証として，主題の近い2本（ツリー型チャットUIの論文と Sensecape）を同時に処理し，
各ページの固有値12項目が自分のPDFにのみ存在することを確認した．
一方のページに現れた相手の論文名は，原稿の参考文献リストに実在する正当な引用であった．

### 補助資料は別プロセスでは守れない

補助資料の機能は**意図的に複数の資料を1プロセスへ渡す**ものなので，
「プロセスが分かれている」という保証が最初から存在しない．
対象と補助資料の取り違えを防ぐのは次の2つだけである．

| 手段 | 内容 |
|---|---|
| 作業ディレクトリの構造 | 対象は直下，補助資料は `aux/` 配下．パスでどちらか分かる |
| 指示文 | 書誌情報は**対象からのみ**取る．補助資料は要約と代表画像のためにのみ使う．別の文献だと判断したら使わず `error` に記録する |

```
.work/<run_id>/
  Smith2024.pdf        ← 対象（AI から見て ./Smith2024.pdf）
  aux/                 ← 補助資料
    appendix.pdf
    data.csv
```

また `bin/ref` は `--with` を省いた2つ目の引数を**エラーにする**．
黙って補助資料として扱うと，2本の文献を登録しようとした人が
気づかないまま1ページに混ざった要約を得てしまうためである．

## 同時実行数の制御

システム全体で同時に処理する資料を `PAPER_PARALLEL`（既定2）件に抑える．
**仕組みは枠（slot）1つだけ**で，`lib/run_one.sh` の先頭で取り，終わりに解放する．

```
.work/.locks/slots/slot-1, slot-2, …   ← mkdir のアトミック性で排他する．中に PID を書く
```

枠は「**1資源を処理する許可**」である．取得してから対象を確保するので，
待っているプロセスはファイルを掴まない．取得より前に対象を確保していると，
待機中に異常終了したときPDFが作業ディレクトリに取り残され，保存期間で消えてしまう．

枠の状態はディスク上にあるため，**起動経路（手動・自動）や起動回数に関わらず合計が効く**．
launchd は同じジョブを二重に起動しないが，`scan_inbox.sh` と手動 `bin/ref` は別プロセスなので
重なりうる．キューの数を1つに制限するのではなく枠の総数を抑えることで上限が保たれる．

`scan_inbox.sh` 側に配分の上限は持たせていない．何件起動しても枠の数だけが実際に処理されるため，
同じことを二重に行う必要がない．

異常終了で枠が残った場合は，枠に書いた PID の生存を確認して回収する
（生きているプロセスの枠は奪わない）．

同じ資料の二重処理は経路ごとに防ぐ．自動は作業ディレクトリへのアトミックな `mv` による確保，
手動は原本を動かさないため実パスを鍵にしたロックで代替する．

## 実行記録

`PAPER_LOG_DIR/<run_id>/` に保存する（既定 7 日で削除）．

| ファイル | 内容 |
|---|---|
| `run.log` | 開始・終了，対象，エンジン，モデル，effort，終了コード，配置先 |
| `result.json` | 検証・正規化済みの最終出力 |
| `engine_raw.json` | エンジンの生出力（`session_id`，トークン数等を含む） |
| `transcript.jsonl` | AI の実行記録（ツール呼び出しの全経過） |
| `prompt.md` | 実際に渡した指示文 |
| `engine.stderr` | エンジンの標準エラー出力 |

成功時は作業ディレクトリを削除し，失敗時は調査用に残す（保存期間の削除対象に含める）．
`failed/` のPDF自体は保存期間では削除しない．

`transcript.jsonl` は Claude Code 自身が保存するセッションファイルを
`session_id` で検索して複製したものである．AI がどのコマンドを実行して
どこで失敗したかを特定できる．

## 環境変数

`.env` に書く（`.gitignore` 済み）．`.env.example` に雛形がある．

| 変数名 | 既定値 | 説明 |
|---|---|---|
| `NOTION_DATA_SOURCE_ID` | （必須） | 登録先データソースID |
| `SLACK_WEBHOOK_URL` | （必須） | Slack Incoming Webhook URL．**秘密情報** |
| `PAPER_ROOT` | `$HOME/Research/Papers` | 処理済みPDFの保存先．他フォルダの基準 |
| `PAPER_INBOX_DIR` | `$PAPER_ROOT/inbox` | 自動処理の置き場 |
| `PAPER_FAILED_DIR` | `$PAPER_ROOT/failed` | 失敗したPDF |
| `PAPER_WORK_DIR` | `$PAPER_ROOT/.work` | 作業ディレクトリ |
| `PAPER_LOG_DIR` | `$PAPER_ROOT/.logs` | 実行記録 |
| `PAPER_ENGINE` | `claude` | `claude` または `codex`（codex は未実装） |
| `PAPER_MODEL` | `opus` | AI のモデル |
| `PAPER_EFFORT` | `medium` | AI の effort |
| `PAPER_PARALLEL` | `2` | システム全体の同時処理数 |
| `PAPER_LOG_RETENTION_DAYS` | `7` | 実行記録の保存日数 |
| `PAPER_SETTLE_SECONDS` | `2` | inbox で書き込み完了と判定するまでの待ち時間 |
| `PAPER_MAX_ROUNDS` | `20` | inbox の再走査の上限 |
| `PAPER_AUX_MAX_BYTES` | `52428800`（50MB） | 補助資料の合計サイズの上限 |
| `PAPER_AUX_MAX_FILES` | `100` | 補助資料のファイル数の上限 |

`PAPER_ROOT` を変えれば他のフォルダはすべて追従する．
Webhook URL はログや通知本文に出力しない．

## 仕様からの変更

[HANDOVER.md](HANDOVER.md) から変更した点．いずれも実測に基づく．

| 箇所 | 変更 | 理由 |
|---|---|---|
| §4 保存先 | `~/Documents/研究/論文` → `~/Research/Papers` | TCC により launchd から `~/Documents` を列挙できない |
| §7.2 起動コマンド | `--restricted` / `--strict-mcp-config` / `--mcp-config` を併用 | 作業ディレクトリ外の読取と Notion 以外の MCP を実際に遮断できる |
| §5 環境変数 | `PAPER_MODEL` / `PAPER_EFFORT` を追加 | 指定しないと CLI の既定に依存し，更新で静かに変わる |
| §6.2 手動コマンド | PDFを inbox 経由にせず，その場で改名する | 「手動起動は移動させない」との決定による |
| §8.2 多重起動 | 同時実行数をシステム全体の枠で抑える | `scan_inbox.sh` と手動コマンドは別プロセスで重なりうる |
| §6.2 手動コマンド | 1コマンド1文献にし，`--with` で補助資料を添える | フォルダを「複数の文献」ではなく「同じ文献を補助する資料」として扱うため |

## 既知の制約

- **`curl` の `file://` は作業ディレクトリ外を読める．** 混入防止の最後の穴である．
  Notion へのファイルアップロードに必須（`WebFetch` では POST できない）なため残している．
  アップロード専用の自前ラッパーに置き換えれば塞げる．
- 補助資料と対象の取り違えは，作業ディレクトリの構造と指示文だけで防いでいる．
  プロセスの分離では守れない（意図的に1プロセスへ渡すため）．
- AI は Notion データベースに新しいタグを追加できる（指示文で承認不要としているため）．
  これまでに `reflection`・`sensemaking`・`creativity` が追加された．
- 重複登録は検知しない（同じ資料を2回処理すれば2件登録される．仕様どおり）．
- URL モード（段階4）は実装済みだが未検証である．
