# reference-analyzer

論文PDFまたはWebページを AI に読解させ，要約と書誌情報を Notion のデータベースへ
登録する．PDFは Citation Key に改名し，結果を Slack に通知する．macOS 専用．

```
inbox に PDF を置く ──┐
                       ├──▶ AI が読解・要約 ──▶ スクリプトが登録 ──┬──▶ Notion に1ページ
ref <PDF|URL> ────────┘                                            ├──▶ PDF を <CitationKey>.pdf に改名
                                                                    └──▶ Slack に通知
```

**1コマンド = 1文献 = AIプロセス1回 = Notionページ1つ**である．

内部の作りと設計の理由は [DESIGN.md](DESIGN.md) にある．

## 必要なもの

| | 用途 | 入手・確認 |
|---|---|---|
| macOS | launchd と TCC に依存している | — |
| `claude` コマンド | AI の実行 | `claude --version` |
| poppler | PDFからの文字・画像抽出 | `brew install poppler` |
| Notion のデータベース | 登録先 | 下記のプロパティが必要 |
| Notion の内部コネクション | Notion への登録 | 下記「Notion 側の準備」 |
| Slack アプリ | 通知 | Bot Token Scopes に `chat:write` |

`launchd/install.sh status` で一括して確認できる．

## Notion 側の準備

登録先のデータベースに次のプロパティが必要である．**名前と形式が一致していないと登録に失敗する．**

| プロパティ名 | 形式 | 内容 |
|---|---|---|
| `Citation Key` | タイトル | 引用キー（例 `Reingold1981TidierDrawings`） |
| `Title` | テキスト | 原文タイトル |
| `DOI` | URL | DOIリンクまたは公開URL |
| `Summary` | テキスト | 概要（一段落） |
| `Tag` | マルチセレクト | 分野・手法のタグ |
| `Author` | テキスト | 著者（所属）・公開者 |
| `Year` | 数値 | 出版年・公開年 |
| `Publication` | テキスト | ジャーナル／会議／公開元 |
| `Citation` | テキスト | BibTeX |
| `Rating` | セレクト | `★` / `★★` / `★★★` |
| `Favorite` | セレクト | `❤︎` / `❤︎❤︎` / `❤︎❤︎❤︎`（AI は設定しない） |

`Tag` には新しい選択肢が追加されることがある（既存の選択肢は保持する）．`Rating` と
`Favorite` の選択肢は追加しない．要約の本文はページ本文に書き，先頭に代表画像を1枚挿入する．

登録はスクリプトが Notion の API で行う．そのための内部コネクションを作る．

1. https://app.notion.com/developers/connections の **Internal connections** で
   **Create a new connection** を押し，登録先のワークスペースを選ぶ（ワークスペースのオーナー権限が要る）
2. **Configuration** タブで権限を Read content・Update content・Insert content にし，
   ユーザー情報は不要とする．同じタブのトークンを `.env` の `NOTION_TOKEN` に書く
3. 登録先のデータベースの **•••** → **Connections** → **+ Add connection** で，作った
   コネクションを接続する（接続しないと API がデータベースを見つけられない）

`NOTION_DATA_SOURCE_ID` はデータベースIDではなく**データソースID**である．データベースの
設定メニューからコピーする．正しく設定できたかは `launchd/install.sh status` の `Notion` の行で確かめられる．

## 導入

**1. 設定ファイル**

```sh
cp .env.example .env
```

`NOTION_TOKEN`・`NOTION_DATA_SOURCE_ID`・`SLACK_BOT_TOKEN`・`SLACK_CHANNEL` を記入する．
他は既定値で動く．

**2. Slack アプリ**

Bot Token Scopes に `chat:write` を付与し，**投稿先チャンネルにアプリを招待する**．
`SLACK_CHANNEL` はチャンネルIDを推奨する（名前だと非公開チャンネルで使えず，
`channels:read` が追加で必要になり，チャンネル名を変えると壊れる）．

**3. 自動起動の登録**

```sh
launchd/install.sh install     # 解除は uninstall，確認は status
```

`~/Research/Papers/` 以下のディレクトリが作られる．

> **`PAPER_ROOT` を `~/Documents`・`~/Desktop`・`~/Downloads` 配下に置いてはならない．**
> launchd から起動したスクリプトはこれらを列挙・読取できない（macOS の TCC）．
> しかもエラーにならず「対象なし」として終わるため気づきにくい．

## 使い方

### 手動

```sh
bin/ref paper.pdf                    # PDF を1本
bin/ref https://arxiv.org/abs/...    # Webページ・GitHubリポジトリ等
```

同じ文献を補助する資料を添えられる．ファイル・フォルダ・URL を混ぜてよい．

```sh
bin/ref paper.pdf --with appendix.pdf
bin/ref paper.pdf --with supp/ https://github.com/owner/repo
```

フォルダを渡しても順番に処理はしない．**同じ文献を補助する資料としてまとめて1度のAIプロセスに渡す．**

2本の文献を登録するときは `ref` を2回実行する．`--with` なしで2つ渡すとエラーになる
（黙って1本目の補助資料として扱うと，別の文献の情報が同じページに混ざるため）．

```sh
bin/ref a.pdf b.pdf      # エラー
```

### 自動

`~/Research/Papers/inbox/` に PDF を置くと走る．補助資料は付けられない．

取り込むのは `.pdf` だけで，隠しファイル・`.icloud`・`.crdownload`・`.download`・
`.part`・`.partial`・`.tmp` は無視する．**ファイルサイズが2秒変化しないことを確認してから**
取り込むので，ダウンロード途中のファイルを掴まない．

複数のファイルを同時に置いてよい．同時に処理する数は `PAPER_PARALLEL`（既定2）までで，
残りは順番待ちになる．

### してはいけないこと

- **`inbox/` のファイルを `bin/ref` で指定しない．** 拒否される．inbox は自動処理の持ち場で，
  手動で指すと自動が取り込んだ瞬間に対象が消える．
- 同じ資料に同時に2回実行しない．検知して拒否される．

## ファイルの行き先

**手動はファイルを移動しない．** 成功したらその場で改名するだけで，失敗したら触らない．

```
~/Downloads/paper.pdf ──成功──▶ ~/Downloads/Reingold1981TidierDrawings.pdf
                      ──失敗──▶ ~/Downloads/paper.pdf（そのまま）
```

**自動は直下へ出す．**

```
inbox/paper.pdf
  │
  ▼
in_progress/paper.pdf   ← 処理中．失敗したものもここに残る
  │
  ▼
~/Research/Papers/Reingold1981TidierDrawings.pdf
```

直下に同名があれば `_2`・`_3` が付く．

| ディレクトリ | 中身 |
|---|---|
| `~/Research/Papers/` | 完了したPDF |
| `inbox/` | 自動処理の置き場 |
| `in_progress/` | **完了していないPDF**（処理中か失敗） |
| `.work/` | 作業用．AIに見せるコピーだけが入る．完了すると消える |
| `.logs/` | 実行記録．既定7日で消える |

## 通知の読み方

1資料につき1メッセージで，処理の進行に応じて中身が書き換わる．

```
🚀 Started: ~/Research/Papers/inbox/paper.pdf
run_id: `20261013-171025-53515`, trigger: auto, model: claude / sonnet / medium
```

```
✅ Completed: Beyond ChatBots: ExploreLLM for Structured Thoughts…
citation_key: `Ma2023BeyondChatbots`
file: `~/Research/Papers/Ma2023BeyondChatbots.pdf`
usage: 10 turns, 180k in / 4.2k out tokens, $0.14 (list price)
run_id: `20261013-171025-53515`, trigger: auto, model: claude / sonnet / medium, duration: 84sec
```

```
🚨 Failed: Tidier Drawings of Trees
① fetch file: completed
② analyze source: completed
③ create page: failed
④ rename file: skipped
⑤ move file: skipped
error: Notion への登録に失敗した: POST /pages が 502 で拒否された
retry: `ref --register 20261013-171025-53515`
citation_key: `Reingold1981TidierDrawings`
file: `~/Research/Papers/in_progress/tidier-drawings.pdf`
usage: 11 turns, 205k in / 4.6k out tokens, $0.16 (list price)
run_id: `20261013-171025-53515`, trigger: auto, model: claude / sonnet / medium, duration: 63sec
```

見出しは3つである．

| 見出し | 意味 |
|---|---|
| `🚀 Started` | 処理を始めた |
| `✅ Completed` | 全ステップが完了した．作業は要らない |
| `🚨 Failed` | 完了していないステップがある |

`🚨 Failed` のときだけステップが並ぶ．

| ステップ | 内容 |
|---|---|
| `fetch file` | inbox から in_progress へ移す（自動のみ） |
| `analyze source` | AI が資料を読み，書誌情報・要約・代表画像を作る |
| `create page` | スクリプトが Notion ページを作る（**代表画像の挿入を含む**） |
| `rename file` | Citation Key に改名する |
| `move file` | 直下へ移す（自動のみ） |

手動は `fetch file` と `move file` を持たないので `①②③` になる．

| 状態 | 意味 |
|---|---|
| `completed` | 完了した |
| `failed` | 着手したが達成しなかった |
| `skipped` | 手前で止まったので実行していない |

見出しの資料名はタイトルで，Notion ページができていればそのリンクになる．タイトルが
取れていないときは対象そのもの（ファイルの場所またはURL）が出る．

`warning:` の行は見出しを変えない．作業ディレクトリの祖先に `CLAUDE.md` があるときに出る
（無関係な指示がAIに読み込まれるおそれがある）．

`usage:` の行は AI の使用量である．ターン数，入力と出力のトークン数，API の定価で換算した
金額を示す．サブスクリプションで使っている場合，金額は実際の請求額ではなく，利用上限の
減り方の目安である．入力はターンごとに文脈全体を読み直す分を含むので，ターン数とほぼ比例する．
AI を動かしていない実行（`ref --register` など）では出ない．

`retry:` の行は，解析は済んだが Notion への登録だけが失敗したときに出る（「失敗したとき」を参照）．

## 失敗したとき

**`in_progress/` に残っているものが，完了していないものである．** 元の名前のままなので，
inbox へ戻せば再実行できる．

```sh
mv ~/Research/Papers/in_progress/paper.pdf ~/Research/Papers/inbox/
```

手動で失敗した場合は原本に触っていないので，同じコマンドを打ち直すだけでよい．

### 登録だけが失敗したとき

**`retry:` の行が出ていれば，AI を再実行せずに登録だけをやり直せる．** 解析の結果と代表画像は
実行記録に残っているので，利用量を消費しない．

```sh
bin/ref --register 20261013-171025-53515
```

成功すると，元の実行と同じく改名し，自動の場合は直下へ移す．実行記録は既定7日で消えるので，
それまでに行う．登録に失敗したときは作りかけのページをゴミ箱へ移すので，ページの削除は要らない．

### 原因別

| `error:` の内容 | 対処 |
|---|---|
| `利用上限またはレート制限に達した（429）` | 表示されたリセット時刻を過ぎてから再実行する |
| `有効なPDFではない` / `内容が空だった` | ファイルを正しいものに差し替える |
| `citation_key が妥当でない` | 繰り返すなら書誌情報が取れていない．`--with` で公式サイトを添える |
| `図表は存在するが…取得できなかった` | そのまま再実行する．繰り返すなら `--with` で公式サイトを添える |
| `Notion への登録に失敗した` | `retry:` の行のコマンドで登録だけをやり直す |
| `Notion のデータベースを確認できなかった` | 下の「困ったとき」の `Notion` の行を見る（AI は起動していない） |

### 困ったとき

```sh
tail -f ~/Research/Papers/.logs/launchd.err.log   # 自動処理のログ
ls ~/Research/Papers/.logs/<run_id>/              # 1実行の記録
```

記録には `prompt.md`（AIに渡した指示文の全文）・`transcript.jsonl`（AIの全操作）・
`result.json`（AIの最終出力）・`image.*`（代表画像）・`notion_page.json`（作成したページ）が入っている．

| 症状 | 原因 |
|---|---|
| 自動処理が走らない | `launchd/install.sh status` で登録と PATH を確認する |
| ログに `対象なし（inbox=… 全 N ファイル）`．**N が 0 でない** | TCC．`PAPER_ROOT` が `~/Documents` 等の配下にある |
| 通知が来ない | `SLACK_BOT_TOKEN`・`SLACK_CHANNEL`．アプリをチャンネルに招待したか |
| `launchd/install.sh status` の `Notion` が `401` | `NOTION_TOKEN` が誤っているか，再発行された |
| 同 `404` | データベースにコネクションを接続していないか，`NOTION_DATA_SOURCE_ID` が誤っている |
| 同 `プロパティが想定と違う` | 「Notion 側の準備」の表と名前・形式を揃える |

## 設定

`.env` に書く．既定値で動くので，必要なものだけ書けばよい．

| 変数 | 既定 | 内容 |
|---|---|---|
| `NOTION_TOKEN` | （必須） | Notion の内部コネクションのトークン |
| `NOTION_DATA_SOURCE_ID` | （必須） | 登録先のデータソースID |
| `SLACK_BOT_TOKEN` | （必須） | Bot トークン |
| `SLACK_CHANNEL` | （必須） | チャンネルID |
| `PAPER_ROOT` | `~/Research/Papers` | 置き場所の親．**`~/Documents` 配下は不可** |
| `PAPER_INBOX_DIR` | `$PAPER_ROOT/inbox` | 自動処理の置き場 |
| `PAPER_IN_PROGRESS_DIR` | `$PAPER_ROOT/in_progress` | 完了していないPDF |
| `PAPER_WORK_DIR` | `$PAPER_ROOT/.work` | 作業ディレクトリ |
| `PAPER_LOG_DIR` | `$PAPER_ROOT/.logs` | 実行記録 |
| `PAPER_ENGINE` | `claude` | `claude` のみ（`codex` は未実装） |
| `PAPER_MODEL` | `opus` | 節約したい場合は `sonnet` |
| `PAPER_EFFORT` | `medium` | `low` / `medium` / `high` / `xhigh` / `max` |
| `PAPER_PARALLEL` | `2` | 同時に処理する資料の数（手動と自動の合計） |
| `PAPER_LOG_RETENTION_DAYS` | `7` | 実行記録を残す日数 |
| `PAPER_SETTLE_SECONDS` | `2` | inbox のファイルのサイズ安定を待つ秒数 |
| `PAPER_MAX_ROUNDS` | `20` | 処理後に inbox を再走査する上限回数 |
| `PAPER_AUX_MAX_FILES` | `100` | `--with` の上限（ファイル数） |
| `PAPER_AUX_MAX_BYTES` | `52428800` | `--with` の上限（50MB） |

## 制約

- **重複は検知しない．** 同じ資料を2回処理すれば Notion に2件登録される．
- `in_progress/` にあるファイルが「処理中」か「失敗」かは見分けられない．同時実行は既定2件で
  1本あたり1分程度なので，残っているものは実質的に失敗である．
- URL を対象にする経路は未検証である．
- 対話画面から起動するスキル，OS通知，`claude` 以外のエンジンは用意していない．
