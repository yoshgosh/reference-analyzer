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
  in_progress/              ← 取り込んだが直下へ出ていないPDF（失敗したものもここ）
  .work/                    ← 1実行ごとの作業ディレクトリ
  .logs/                    ← 実行記録（保存期間あり）
```

## 準備

```sh
cp .env.example .env     # NOTION_DATA_SOURCE_ID と SLACK_BOT_TOKEN / SLACK_CHANNEL を記入する
```

必要なもの．

- `claude` コマンド（PATH 上にあること）
- Slack アプリの Bot トークン … **Incoming Webhook ではなく Web API を使う**（後述）
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
| 対象の確保 | コピー（原本は動かさない） | `inbox` → `in_progress` へ `mv` |
| 成功時のファイル | **元の場所で改名するだけ**（移動しない） | 改名して `PAPER_ROOT` 直下へ移動 |
| 失敗時のファイル | **触らない**（元のまま） | `in_progress` に元の名前で残る |

**自動は「手動と同じ処理」の前後に移動を1回ずつ足したものである．**

```
① inbox/paper.pdf → in_progress/paper.pdf         確保（mv）
② in_progress のファイルに対して手動と同じ処理      コピーを AI に見せ，最後にその場で改名
③ in_progress/<Key>.pdf → <Key>.pdf               直下へ出す（mv）
```

そのため `place_in_place`（対象をその場で改名する）を両経路で共有し，
自動の `place_result` はそれを呼んでから `move_into` で直下へ出すだけになっている．

**ユーザーのファイルは作業ディレクトリに入らない．入るのはコピーだけである．**
これは `.work/` を「いつ削除しても安全な場所」にするための不変条件である．
自動が本物を `.work/` に置いていると，取り残されたときに保存期間で消えてしまう．

失敗したものを inbox へ戻さないのは，次の変化で再処理され，失敗を繰り返すか
重複登録になるためである．手動はユーザーが明示的に指したファイルなので，
失敗時に別の場所へ移すと驚きが大きく，再処理のループも起きない．

**`bin/ref` は `inbox/` 配下のファイルを拒否する．** inbox は自動処理の持ち場で，
手動で指すと自動が確保のために `mv` した瞬間に対象が消える．

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
  lib/find_notion_url.py  transcript から作成済みページのURLを探す
  lib/cleanup.sh          保存期間を過ぎた記録の削除
  launchd/install.sh      launchd エージェントの導入・解除・状態確認

指示文・設定
  prompts/registration.md       書誌項目・要約・Notion登録の指示（何を作るか）
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
  → place_result     ← 経路ごと（手動=その場で改名／自動=その場で改名 ＋ 直下へ移動）
  → 記録 → 通知 → 枠を解放 → 片付け
```

**ユーザーのファイルに触る処理は `lib/place.sh` だけに閉じている**（`rename_to_key` と `move_into`）．
`lib/analyze.sh` と `lib/core.sh` はファイルの改名・移動を行わない．

一意な名前の決定は「着地させる関数」が行う．手動は `rename_to_key` が原本の
ディレクトリ内で解決する．自動は `in_progress` で `rename_to_key`，`PAPER_ROOT` で
`move_into` がそれぞれ解決するので，直下に同名があれば最終的に `<Key>_2.pdf` になる．
確保のときも `move_into` を使うため，`in_progress` に同名が居れば `paper_2.pdf` に逃がす．

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
待っているプロセスはファイルを掴まない．

**この順序は入れ替えてはならない．** 待機中に異常終了したとき，
ファイルが inbox に残っていれば次の `RunAtLoad` で拾われる．先に確保していると
`in_progress` に残り，`WatchPaths` は inbox だけなので誰も拾わず黙って止まる．
副次的に，`in_progress` に待ち行列のファイルが混ざらない利点もある．

枠の状態はディスク上にあるため，**起動経路（手動・自動）や起動回数に関わらず合計が効く**．
launchd は同じジョブを二重に起動しないが，`scan_inbox.sh` と手動 `bin/ref` は別プロセスなので
重なりうる．キューの数を1つに制限するのではなく枠の総数を抑えることで上限が保たれる．

`scan_inbox.sh` 側に配分の上限は持たせていない．何件起動しても枠の数だけが実際に処理されるため，
同じことを二重に行う必要がない．

異常終了で枠が残った場合は，枠に書いた PID の生存を確認して回収する
（生きているプロセスの枠は奪わない）．

同じ資料の二重処理は2つの仕組みで防ぐ．役割が違う．

| 仕組み | 何を防ぐか |
|---|---|
| 確保の `mv`（原子的） | 自動の2プロセスが同じ inbox のファイルを取ること |
| 資料ロック（実パスを鍵にする） | 同じファイルに対して別の処理が始まること |

**資料ロックは両経路が取る．** 手動は原本のパスに，自動は確保後の `in_progress` の
パスに立てる．`in_progress` はパスが安定しているため，処理中のファイルに人が
`ref` をかけられてしまい，放っておくと同じ論文でNotionページが2つできる．
自動が `.work/<run_id>/` に隠していた間は，この札は不要だった．

ロックの取得順は経路間で逆である（手動は資料ロック→枠，自動は枠→資料ロック）．
対象を知るタイミングが違うため避けられないが，交差するのは
inbox のファイルを手動で指した場合だけなので，`bin/ref` がそれを拒否して根本から消している．

## Slack 通知

1資料につき1メッセージである．枠を取得した直後に `⏳ 処理中` を投稿し，
終了時に `chat.update` で**同じメッセージを書き換える**．チャンネルが流れない．

Incoming Webhook は使えない．応答が `ok` という文字列だけで，
書き換えに必要な `ts` を返さないためである（実測で確認済み）．

```
SLACK_BOT_TOKEN=xoxb-...      # Bot Token Scopes に chat:write
SLACK_CHANNEL=C0C8ME3G3DJ     # チャンネルID を推奨
```

`SLACK_CHANNEL` はチャンネル名（`#name`）でも動くが，**IDを推奨する**．
名前だと非公開チャンネルで使えず，名前の解決に `channels:read` スコープが
追加で必要になり，チャンネル名を変えると壊れる．

### ステップごとの成否を出す

1資料の処理はステップの連なりである．どこまで進んだかを通知にそのまま並べる．

| | ステップ | 判定根拠 | 担い手 |
|---|---|---|---|
| ① | 確保 | 自動のみ．`inbox` → `in_progress` へ `mv` | シェル |
| ② | ページ作成 | `notion_url` が非空 | AI |
| ③ | ページ完成 | `status` == `success` | AI |
| ④ | 改名 | `rename_to_key` | シェル |
| ⑤ | 移動 | 自動のみ．`in_progress` → `PAPER_ROOT` へ `mv` | シェル |

AIの出力2項目が，そのままAIの担当する2ステップに対応する．

経路に存在するステップだけを出す．宣言は経路側にあり（`STEP_LIST`），
手動はファイルを移動しないので ⑤ を持たず，URL は改名する対象が無いので ④ も持たない．

| 経路 | `STEP_LIST` |
|---|---|
| 手動・PDF | `page complete rename` |
| 手動・URL | `page complete` |
| 自動 | `page complete rename move` |

① は通知に出さない．確保に失敗したときは二重処理を避けるため通知せず終了するので，
通知に現れる場面では必ず完了している．

### 終端は2つだけ

**全ステップが完了したら ✅，ひとつでも欠けたら ❌** である．
何が残っているかはステップの行が示すので，状態に名前を付けて区別しない．

```
❌ 失敗（自動） — tidier-drawings.pdf
ページ作成 ✅  ページ完成 ❌  改名 ❌  移動 ❌
• 理由: 図3が存在するがアップロードに失敗した
• Notion: https://app.notion.com/p/... ← 既存ページ．削除してから再実行
• ファイル: ~/Research/Papers/in_progress/tidier-drawings.pdf（改名していない）
```

❌ は「未完了」の意味である．着手して失敗したのか，前段で止まって未実施なのかは
`• 理由:` が示すので，ステップ側では区別しない．

**②③ が完了していてファイル側だけが欠けている場合は，AIの再実行は不要**で，
ファイルを動かすだけで終わる．これはステップの行から読み取れる．

```
❌ 失敗（自動） — Tidier Drawings of Trees
ページ作成 ✅  ページ完成 ✅  改名 ✅  移動 ❌
• Citation Key: `Reingold1981TidierDrawings`
• ファイル: ~/Research/Papers/in_progress/Reingold1981TidierDrawings.pdf → ~/Research/Papers/ へ移してください
```

`• Notion:` の行が，再実行の前に既存ページを消す必要があるかどうかを示す．

| ② | 表示 |
|---|---|
| ❌ | `ページ未作成 — そのまま再実行できます` |
| ✅ ＋ ③ ❌ | `<URL> ← 既存ページ．削除してから再実行` |
| ✅ ＋ ③ ✅ | `<URL>` |

### 再実行

**`in_progress/` に残っているものが未完了である．** 直下へ出たものが完了したものである．
`<run_id>_` のような接頭辞は付かないので，元の名前のまま再実行できる．

```sh
# ② が ❌ のとき（ページ未作成）
mv ~/Research/Papers/in_progress/paper.pdf ~/Research/Papers/inbox/

# ② が ✅ のとき（ページ作成済み）— 先に Notion のページを削除する
#   削除せずに再実行すると，同じ論文で2件目のページができる
```

手動で失敗した場合は原本に触っていないので，同じコマンドを打ち直すだけである．

`in_progress/` のファイルを `bin/ref` で直接指してもよい．手動はファイルを移動しないので，
成功すると `in_progress/` の中で改名されたまま残り，直下へ移すのは手作業になる．
枠の空きを待たずに走る点だけが利点である．

`in_progress/` にあるものが「実行中」か「失敗」かは見分けられない．
並列は既定2件で1本あたり1分程度なので，残っているものは実質的に失敗である．

### エンジン自身の失敗は区別して報告する

利用上限（429）・認証切れ・ネットワーク障害は**資料の問題ではない**．
`engine_raw.json` の `is_error` / `api_error_status` / `result` を見て，
AI が資料を読んで `failed` と判断した場合と区別し，原因をそのまま通知に出す．

```
• 理由: 利用上限またはレート制限に達した（429） — You've hit your session limit · resets 10:40am (Asia/Tokyo)
```

これを入れる前は「AIの出力JSONを検証できなかった」と表示されるだけで，
上限に達したことも回復時刻も分からなかった．判定は `lib/engine_claude.sh` の
`engine_error_summary` にあり，エンジン固有なので engine 層に置いている．

なお上限超過でもファイルは `in_progress/` へ移る．回復後に手で inbox へ戻して再実行する．

`notion_url` が空かどうかが「再実行の前に既存ページを消す必要があるか」を決める．
そのため指示文では，ページを作成した後に `failed` となった場合も
`notion_url` を必ず記録するよう求めている．

### 構造化出力が得られなかった場合

構造化出力は AI が最後にまとめて返すため，利用上限（429）などで途中切断されると
得られない．**しかしその時点でページが作成済みであることはありうる．**

存在するページを「未作成・そのまま再実行可」と通知すると，再実行で重複登録になる．
そのため検証に失敗した場合は，`transcript.jsonl` に残る `notion-create-pages` の
結果からURLを拾い，② を正しく判定する（`lib/find_notion_url.py`）．

400 などで拒否された呼び出しは無視する（ページは作られていないため）．
AI 側に手順を足していないので，AI が指示に従うかどうかに依存しない．

## AI の最終出力

```
status        "success" | "failed"
citation_key  スクリプトが改名に使う
title         通知の見出し
notion_url    ページを作成したら failed でも必ず入れる
error         失敗した段階と理由．成功時は空
```

Rating は Notion のプロパティには入るが，スクリプトへは返さない．
スクリプト側で必要とする場面がないためである．

`success` になるのは，Notion 登録が完了し，**かつ代表画像が入っている**場合のみである．
図表が存在するのに入れられなければ `failed` とする（代表画像は要約の一部であり，
入っていない登録を完了とはみなさない）．対象に図表がそもそも無ければ画像なしで `success`．

この基準は HANDOVER §7.1（「画像の失敗は全体の失敗としない」）から変更している．

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
| `slack_post.json` / `slack_update.json` | Slack API の応答（通知が届かない場合の調査用） |

成功時は作業ディレクトリを削除し，失敗時は調査用に残す（保存期間の削除対象に含める）．
`in_progress/` のPDF自体は保存期間では削除しない（未完了のまま残す）．

`transcript.jsonl` は Claude Code 自身が保存するセッションファイルを
`session_id` で検索して複製したものである．AI がどのコマンドを実行して
どこで失敗したかを特定できる．

## 環境変数

`.env` に書く（`.gitignore` 済み）．`.env.example` に雛形がある．

| 変数名 | 既定値 | 説明 |
|---|---|---|
| `NOTION_DATA_SOURCE_ID` | （必須） | 登録先データソースID |
| `SLACK_BOT_TOKEN` | （必須） | Slack Bot トークン（`chat:write`）．**秘密情報** |
| `SLACK_CHANNEL` | （必須） | 投稿先．チャンネルID を推奨 |
| `PAPER_ROOT` | `$HOME/Research/Papers` | 処理済みPDFの保存先．他フォルダの基準 |
| `PAPER_INBOX_DIR` | `$PAPER_ROOT/inbox` | 自動処理の置き場 |
| `PAPER_IN_PROGRESS_DIR` | `$PAPER_ROOT/in_progress` | 取り込んだが直下へ出ていないPDF |
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
| §7.1 画像の失敗 | 画像が入らなければ `failed` とする | 代表画像は要約の一部であり，入っていない登録を完了とはみなさない |
| §7.4 出力スキーマ | 8項目 → 6項目（`rating_reason`・`image_status` を削除） | 前者はどこにも表示しておらず，後者は `status` と `error` で表せる |
| §10 通知 | Webhook → Web API．1資料1メッセージを書き換える | Webhook は `ts` を返さず書き換えができない |

## 2つの指示文の分担

同じことを2箇所に書かない．矛盾した場合にどちらが効くか分からなくなり，
片方だけ直した状態が生まれる．

| | 範囲 |
|---|---|
| `registration.md` | **何を作るか**．書誌項目の定義，要約の構成，Notion のスキーマと登録設定，タグの追加手順 |
| `headless_addendum.md` | **無人実行での追加・変更**．対象の限定，補助資料，Web検索の扱い，コマンドの制約，画像の取得手順，最終出力 |

一方から他方を参照する場合は節番号で指す（例：「§6 に定める」）。

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
- `in_progress/` にあるファイルが「実行中」か「失敗」かは区別できない．
  `failed/` を分けていたときは区別できたが，フォルダを2つ持つ構成をやめた．
