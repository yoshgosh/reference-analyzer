# 内部の作り

使い方は [README.md](README.md) にある．本書は手を入れる人向けに，何がどう作られていて
なぜそうなっているかを書く．macOS 標準の bash 3.2 で動くように書いている．

## 全体の流れ

処理の流れは `lib/run_one.sh` の1箇所にあり，**経路ごとに違うのは2つの関数だけ**である．

```
run_one()
  枠を取る → 実行ディレクトリ作成 → 混入ガード → 開始を通知
  → prepare_target   ← 経路ごと（手動=コピー／自動=mv で取り込む）
  → analyze          ← 共有（プロンプト組立 → エンジン起動 → 出力検証）
  → place_result     ← 経路ごと（手動=その場で改名／自動=その場で改名 ＋ 直下へ移動）
  → 記録 → 通知 → 枠を解放 → 片付け
```

**自動は「手動と同じ処理」の前後に移動を1回ずつ足したものである．**

```
① inbox/paper.pdf → in_progress/paper.pdf        取り込み（mv）
② in_progress のファイルに対して手動と同じ処理     コピーをAIに見せ，最後にその場で改名
③ in_progress/<Key>.pdf → <Key>.pdf              直下へ出す（mv）
```

そのため `rename_step`（対象をその場で改名する）を両経路で共有し，自動の `place_result` は
それを呼んでから `move_into` で直下へ出すだけになっている．

## ファイル

```
入口
  bin/ref                 手動の入口（対象1つ ＋ --with 補助資料）
  lib/scan_inbox.sh       inbox を走査し，1件ごとにワーカーを起動（launchd から）
  lib/process_inbox.sh    inbox の1件を処理する

共有
  lib/run_one.sh          1資源の処理の流れ（骨格）
  lib/analyze.sh          プロンプト組立 → エンジン起動 → 出力検証
  lib/place.sh            改名と移動（ユーザーのファイルに触るのはここだけ）
  lib/core.sh             環境・ログ・ロック・同時実行の枠・ステップ・混入ガード

部品
  lib/engine_claude.sh    claude -p の呼び出し
  lib/notify_slack.sh     Slack 通知
  lib/validate_result.py  最終出力の検証と正規化
  lib/find_notion_url.py  transcript から作成済みページのURLを探す
  lib/cleanup.sh          保存期間を過ぎた記録の削除
  launchd/install.sh      launchd エージェントの導入・解除・状態確認

指示文・設定
  prompts/registration.md       書誌項目・要約・Notion登録の指示（何を作るか）
  prompts/headless_addendum.md  無人実行用の追加ルール（混入防止・コマンド制約・JSON出力）
  schema/result.schema.json     AI の最終出力スキーマ
  config/mcp.json               AI に見せる MCP サーバー（notion のみ）
```

**ユーザーのファイルに触る処理は `lib/place.sh` だけに閉じている**（`rename_to_key` と
`move_into`）．`lib/analyze.sh` と `lib/core.sh` はファイルの改名・移動を行わない．

エンジンの差分は `lib/engine_<名前>.sh` に閉じているので，別のエンジンは共有部分に
手を入れずに追加できる．

一意な名前の決定は「着地させる関数」が行う．手動は `rename_to_key` が原本のディレクトリ内で
解決する．自動は `in_progress` で `rename_to_key`，直下で `move_into` がそれぞれ解決するので，
同名があれば `<Key>_2.pdf` になる．取り込みのときも `move_into` を使うため，`in_progress` に
同名が居れば `paper_2.pdf` に逃がす．

## ユーザーのファイルは作業ディレクトリに入らない

入るのはコピーだけである．これは `.work/` を「いつ削除しても安全な場所」にするための
不変条件である．本物を `.work/` に置くと，取り残されたときに保存期間で失う．

失敗したものを inbox へ戻さないのも同じ理由による．次の変化で再処理され，失敗を繰り返すか
重複登録になる．手動はユーザーが明示的に指したファイルなので，失敗時に別の場所へ移すと
驚きが大きい．

`bin/ref` は `inbox/` 配下のファイルを拒否する．inbox は自動処理の持ち場で，手動で指すと
自動が取り込みのために `mv` した瞬間に対象が消える（ロックの取得順も経路間で交差する）．

## ステップ

| キー | 表示 | 判定根拠 | 担い手 |
|---|---|---|---|
| `fetch` | `fetch file` | 自動のみ．`inbox` → `in_progress` へ `mv` | シェル |
| `create` | `create page` | `notion_url` が非空 | AI |
| `finish` | `finish page` | `status` == `success` | AI |
| `rename` | `rename file` | `rename_to_key` | シェル |
| `move` | `move file` | 自動のみ．`in_progress` → 直下へ `mv` | シェル |

AIの出力2項目が，そのままAIの担当する2ステップに対応する．内部のキーは表示名の動詞
そのものであり，語を二重に持たない．

経路に存在するステップだけを出す．宣言は経路側にあり（`STEP_LIST`），**番号は並び順**である．

| 経路 | `STEP_LIST` |
|---|---|
| 手動・PDF | `create finish rename` |
| 手動・URL | `create finish` |
| 自動 | `fetch create finish rename move` |

状態は3つで，**作業単位のライフサイクルを過去分詞で言う系統**に揃えている（見出しの
`Started` / `Completed` / `Failed` と同じ系統）．既定値は `skipped` である．

| 状態 | 意味 |
|---|---|
| `completed` | 達成した |
| `failed` | 着手したが達成しなかった |
| `skipped` | 始まらなかった（前段が失敗したので実行されなかった） |

**状態名に `error` を使わない．** 理由の項目名が `error:`（スキーマの項目名）であり，
同じメッセージの中で `error` が2つの意味で並んでしまう．

## 通知

1資料につき1メッセージである．枠を取得した直後に `🚀 Started` を投稿し，終了時に
`chat.update` で**同じメッセージを書き換える**．チャンネルが流れない．

Incoming Webhook は使えない．応答が `ok` という文字列だけで，書き換えに必要な `ts` を
返さないためである．

見出しは3つで，`✅ Completed` はステップを出さない（全部 `completed` と分かっているため
情報量がない）．`warning:` の行は見出しを変えず，どちらの見出しでも出る．

### 開始の通知は枠を取った直後に出す

順序は 枠 → 実行ディレクトリ作成 → **開始通知** → 取り込み（`fetch`）である．

取り込みより後に出すと，取り込みに失敗したことを通知できない．`fetch` をステップとして
数えるなら，その失敗も通知されなければ筋が通らない．そのため，取り込みに失敗した場合も
黙って終了せず `🚨 Failed` を出す．

```
🚨 Failed: ~/Research/Papers/in_progress/paper.pdf
① fetch file: completed
② create page: skipped
③ finish page: skipped
④ rename file: skipped
⑤ move file: skipped
error: この資料は既に処理中である
```

`fetch file` は `mv` が成功したかどうかだけを表す．上の例は移動はできたが札が取れなかった
場合で，**`failed` のステップが1つも無い `🚨 Failed`** になる．見出しと `error:` が理由を
持つので成立する．

### エンジン自身の失敗は区別して報告する

利用上限（429）・認証切れ・ネットワーク障害は**資料の問題ではない**．`engine_raw.json` の
`is_error` / `api_error_status` / `result` を見て，AI が資料を読んで `failed` と判断した
場合と区別し，原因をそのまま通知に出す．

```
error: 利用上限またはレート制限に達した（429） — You've hit your session limit · resets 10:40am (Asia/Tokyo)
```

判定は `lib/engine_claude.sh` の `engine_error_summary` にあり，エンジン固有なので
engine 層に置いている．

### 構造化出力が得られなかった場合

構造化出力は AI が最後にまとめて返すため，利用上限などで途中切断されると得られない．
**しかしその時点でページが作成済みであることはありうる．**

存在するページを「未作成・そのまま再実行可」と通知すると，再実行で重複登録になる．
そのため検証に失敗した場合は，`transcript.jsonl` に残る `notion-create-pages` の結果から
URLを拾い，`create` ステップを正しく判定する（`lib/find_notion_url.py`）．400 などで
拒否された呼び出しは無視する（ページは作られていないため）．AI 側に手順を足していないので，
AI が指示に従うかどうかに依存しない．

## 混入防止

**論文同士の情報が混ざってはならない．** 設計上の最上位要件である．

### 機械的に強制している層

| 施策 | 何を塞ぐか |
|---|---|
| `--restricted` | `Read`/`Write`/`Glob`/`Grep` を作業ディレクトリに限定する．user/project/local の設定ファイルも無視する |
| `--strict-mcp-config` ＋ `--mcp-config` | notion 以外の MCP を遮断する（他のコネクタ経由の流入） |
| `--allowedTools` | 許可した5コマンド以外の Bash を拒否する |
| `--permission-mode dontAsk` | 許可リスト外は確認待ちにならず拒否される（無人実行で止まらない） |

許可コマンドの定義元は `lib/analyze.sh` の 1 箇所で，そこから `--allowedTools` と指示文の
両方に注入される．

```
ALLOWED_COMMANDS="pdftotext pdfimages pdftoppm pdfinfo curl"
```

**`python3` は許可しない．** `--restricted` が制限するのはファイルツールだけで，Bash 経由の
`python3` は作業ディレクトリ外を自由に読める．

**`--bare` は使わない．** OAuth・キーチェーンを読まず `ANTHROPIC_API_KEY` を要求するため，
サブスクリプションの認証が通らない．

モデルと effort は明示的に固定する．`--restricted` が設定ファイルを無視するため，指定しないと
CLI の既定に依存し，更新で静かに変わる．

### 分離による層

| 施策 | 内容 |
|---|---|
| 1資料＝1プロセス＝1作業ディレクトリ | 会話の引き継ぎ（`--resume` 等）は使わない |
| ユーザーのファイルを作業ディレクトリに入れない | 入るのはコピーだけ |
| 足場ファイルをAIに見せない | `prompt.md`・`engine_raw.json`・`engine.stderr` は記録ディレクトリ側に書く |

3つ目を守らないと，AI が「対象以外のファイルがある」と `error` に報告する．

### 検知して通知する層

`find_ancestor_claude_md` が作業ディレクトリの**祖先すべて**を遡って `CLAUDE.md` /
`CLAUDE.local.md` を探す．`--restricted` は設定ファイルを無視するが，`CLAUDE.md` の
自動読込はプロセスを分けても防げないため，**検知して `warning:` に出す**扱いである．
塞いではいない．

### 指示文だけの層

- 対象は1文献のみ．Notion ページは1つだけ作る
- 他の文献・過去の会話・記憶を使わない
- 補助資料から**書誌情報を取らない**（要約と代表画像のためにのみ使う）
- Web検索はタイトル・著者・DOI の一致を確認してから使う
- 改名・移動を AI が行わない

**補助資料の取り違えはここだけで防いでいる．** 意図的に1プロセスへ渡す仕様なので，プロセスの
分離では守れない．作業ディレクトリの構造（対象は直下，補助資料は `aux/` 配下）で区別させる．

### 残っている穴

**`curl` の `file://`．** `--restricted` が制限するのはファイルツールだけで，Bash 経由は
対象外である．`curl file:///path` で作業ディレクトリ外を読める．Notion へのファイル
アップロードに必須（`WebFetch` では POST できない）なため残している．アップロード専用の
ラッパーに置き換えれば塞げる．

## 同時実行の制御

システム全体で同時に処理する資料を `PAPER_PARALLEL`（既定2）件に抑える．**仕組みは枠（slot）
1つだけ**で，`lib/run_one.sh` の先頭で取り，終わりに解放する．

```
.work/.locks/slots/slot-1, slot-2, …   ← mkdir のアトミック性で排他する．中に PID を書く
```

枠は「**1資源を処理する許可**」である．取得してから対象を取り込むので，待っているプロセスは
ファイルを掴まない．

**この順序は入れ替えてはならない．** 待機中に異常終了したとき，ファイルが inbox に残っていれば
次の `RunAtLoad` で拾われる．先に取り込んでいると `in_progress` に残り，`WatchPaths` は inbox
だけなので誰も拾わず黙って止まる．副次的に，`in_progress` に待ち行列のファイルが混ざらない
利点もある．

枠の状態はディスク上にあるため，**起動経路（手動・自動）や起動回数に関わらず合計が効く**．
launchd は同じジョブを二重に起動しないが，`scan_inbox.sh` と手動 `bin/ref` は別プロセスなので
重なりうる．異常終了で枠が残った場合は，枠に書いた PID の生存を確認して回収する（生きている
プロセスの枠は奪わない）．

`scan_inbox.sh` 側に配分の上限は持たせていない．何件起動しても枠の数だけが実際に処理される．

### 同じ資料の二重処理

2つの仕組みで防ぐ．役割が違う．

| 仕組み | 何を防ぐか |
|---|---|
| 取り込みの `mv`（原子的） | 自動の2プロセスが同じ inbox のファイルを取ること |
| 資料ロック（実パスを鍵にする） | 同じファイルに対して別の処理が始まること |

**資料ロックは両経路が取る．** 手動は原本のパスに，自動は取り込み後の `in_progress` のパスに
立てる．`in_progress` はパスが安定しているため，処理中のファイルに人が `ref` をかけられて
しまい，放っておくと同じ論文でNotionページが2つできる．

ロックの取得順は経路間で逆である（手動は資料ロック→枠，自動は枠→資料ロック）．対象を知る
タイミングが違うため避けられないが，交差するのは inbox のファイルを手動で指した場合だけなので，
`bin/ref` がそれを拒否して根本から消している．

### 並列と run_id

自動は1件ごとに `lib/process_inbox.sh` を**別プロセスとして**起動する．`run_id` の末尾が
プロセスID（`$$`）であり，bash ではサブシェルでも `$$` が親のままで，`BASHPID` は bash 4.0
以降（macOS は 3.2）にしか無い．サブシェルで並列化すると同時起動した2本が同じ `run_id` を
持ち，作業ディレクトリと記録を共有してしまう．

## launchd と TCC

`WatchPaths` は inbox **ディレクトリ**の変化を通知する．どのファイルかは渡ってこないので，
改めて走査して見つかった全件を処理する．1回の検知で複数件になりうる．launchd は同じジョブを
二重に起動しないが，実行中に起きた変化は終了後に再実行される．

`scan_inbox.sh` は候補を全部バックグラウンド起動し，**全部の終了を待ってから**再走査する
（`PAPER_MAX_ROUNDS` まで）．待機中のプロセスが取り込みを済ませていなくても，再走査はその後
なので同じファイルを二度投入しない．

検知から処理開始までは，検知 約1秒 ＋ サイズ安定の待ち2秒 ＋ `ThrottleInterval` 0〜10秒である．

`install.sh` は `claude` の実体があるディレクトリを PATH の先頭に焼き込む．launchd は
ログインシェルの PATH を引き継がないためである．

### TCC（macOS のプライバシー保護）

launchd から起動したスクリプトは `~/Documents`・`~/Desktop`・`~/Downloads` に対して
**非対称な制約**を受ける．

| 操作 | 結果 |
|---|---|
| ディレクトリの列挙・既存ファイルの読取 | **失敗する**（`Operation not permitted`） |
| `[ -e ]` による存在確認・書き込み・`mv` | 成功する |

列挙できないだけなので，スクリプトからは「対象なし」と区別がつかない．そのため
`scan_inbox.sh` は対象が無いときにファイル数を出す．

```
対象なし（inbox=/Users/x/Research/Papers/inbox 全 3 ファイル）
```

**ファイル数が 0 でないのに何も処理されないなら TCC である．** `/bin/bash` にフルディスク
アクセスを与えれば `~/Documents` でも動くが，bash で起動する全スクリプトが全ディスクへの
アクセス権を得るため採らない．

## AI の入出力

### 2つの指示文

| ファイル | 役割 |
|---|---|
| `prompts/registration.md` | **何を作るか**．書誌項目の定義，Citation Key の規則，要約の必須トピック，Notion のスキーマ |
| `prompts/headless_addendum.md` | **無人実行での追加・変更**．対象の限定，補助資料，Web検索の扱い，コマンドの制約，代表画像の取得手順，最終出力 |

**同じ指示を両方に書かない．** 一方から他方を参照する場合は節番号で指す（例：「§6 に定める」）．

`{{NOTION_DATA_SOURCE_ID}}` と `{{ALLOWED_COMMANDS}}` は `build_prompt` が置換する．

### 最終出力

```
status        "success" | "failed"   → ステップ finish page の判定
citation_key  スクリプトが改名に使う
title         通知の見出し
notion_url    ページを作成したら failed でも必ず入れる → ステップ create page の判定
error         失敗した段階と理由．成功時は空 → 通知の error: 行
```

通知の `error:` という項目名はここから来ている．そのため**ステップの状態名には `error` を
使わない**（同じ語が2つの意味で並ぶ）．

Rating は Notion のプロパティには入るが，スクリプトへは返さない．スクリプト側で必要とする
場面がないためである．

`success` になるのは，Notion 登録が完了し，**かつ代表画像が入っている**場合のみである．
図表が存在するのに入れられなければ `failed` とする（代表画像は要約の一部であり，入っていない
登録を完了とはみなさない）．対象に図表がそもそも無ければ画像なしで `success` とする．

`citation_key` は正規化してから使う．NFKD 分解して ASCII だけを残すので `Müller` は
`Muller` になる．正規化後に空・3文字未満・英字を含まない場合は妥当でないとして失敗にする．

### 代表画像の取得順

**対象そのものから取れるものを優先する．**

1. `pdfimages` でPDFから抽出する
2. 図がベクタで取れない場合は公式サイト（arXiv HTML版等）から取る
3. それも取れない場合は `pdftoppm` でページを画像化し，`-x -y -W -H` で図の範囲を切り出す

理由は3つある．**確実性** — PDFは必ず手元にあるが，HTMLはarXivの一部にしか無い．
**費用** — HTMLは「200の確認 → img一覧 → 取得」で3回，PDFは `-list` → `-png` で2回であり，
HTMLが無い場合はそのうえでPDF経路を全部やることになる．**混入防止** — PDF抽出は対象ファイル
自身からの取得なので混入の余地がないが，HTML経路は別論文の図を拾う余地が残る．

ページ全体を代表画像にはしない（本文が写り込む）．

対象が URL の場合は PDF が無いので 2 のみを行う．

### コマンド実行の制約を指示文にも書く

`--allowedTools` で拒否されるだけでは，AI が「コマンドの実行そのものが禁じられた」と
判断して代表画像を諦める．そのため指示文に明記している．

- 1回の呼び出しで実行するコマンドは1つだけにする（`;` で連結すると全体が拒否される）
- パイプ（`|`）は使用できる
- あるコマンドが拒否されても，別のコマンドで目的を達せられることが多い．特に代表画像の取得を
  1度の拒否で諦めてはならない

## 実行記録

```
.logs/<run_id>/
  run.log           経過（ステップの状態もここに出る）
  prompt.md         AIに渡した指示文の全文
  engine_raw.json   エンジンの生出力
  engine.stderr     エンジンの標準エラー
  result.json       検証・正規化した最終出力
  transcript.jsonl  AIの全操作（ツール呼び出しと結果）
  slack_post.json   Slack API の応答
  slack_update.json 同
```

`run_id` は `<日時>-<PID>` である．成功時は作業ディレクトリを削除し，失敗時は調査用に残す
（保存期間の削除対象に含める）．`in_progress/` のPDF自体は保存期間では削除しない．

## 保留している作業

### Codex 対応

`PAPER_ENGINE=codex` は受け付けるが `lib/engine_codex.sh` が無く，明示的なエラーで止まる．
`codex` コマンド自体も未インストールである．

`lib/engine_codex.sh` に実装すべき関数は次の6つで，共有側に手を入れる必要はない．

```
run_engine              エンジンを起動して生出力を書く
engine_error_summary    エンジン自身の失敗を1行にまとめる
engine_session_id       生出力から session_id を取る
engine_transcript_path  session_id から transcript のパスを得る
engine_save_transcript  transcript を記録ディレクトリへ保存する
engine_find_notion_url  transcript から作成済みページのURLを探す
```

起動は次の形になる見込みである．

```sh
codex exec --skip-git-repo-check \
  --cd "$WORK_DIR" \
  --model "$PAPER_MODEL" \
  -c "model_reasoning_effort=\"$PAPER_EFFORT\"" \
  --sandbox workspace-write \
  -c 'sandbox_workspace_write.network_access=true' \
  -c 'approval_policy="never"' \
  -c 'web_search="live"' \
  --json \
  --output-schema schema/result.schema.json \
  -o "$RECORD_DIR/result.json" \
  "$PROMPT"
```

`--json` は全イベント（コマンド実行，MCP呼び出し，Web検索等）を JSONL で標準出力に出すので，
これを実行記録として保存する．transcript は `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`
にある．既定は読み取り専用サンドボックスなので `--sandbox workspace-write` が必要である．
`--ephemeral` は付けない（実行記録を残すため）．出力の形が claude と違うので，engine 層で
同じ形に正規化する（`lib/validate_result.py` は触らない）．

**判断が必要な問題が3つある．**

1. **混入防止の水準が下がる．** `--restricted` はファイルツールの**読み取り**も作業ディレクトリに
   限定するが，codex の `workspace-write` が制御するのは書き込みと承認で，読み取りは限定され
   ない．他の論文PDFを読める状態になる．
2. **コマンドの許可リストが無い．** `ALLOWED_COMMANDS` を `--allowedTools` で強制している防御が
   消える．`python3` を外した判断（作業ディレクトリ外を読めるため）が効かなくなる．さらに
   Notion への画像アップロードに `curl` が必要なので，サンドボックスにネットワーク許可を
   与えることになる．
3. **MCP を notion だけに限定する手段が無い．** `--strict-mcp-config` に相当するオプションが
   codex に無く，`~/.codex/config.toml` に書かれた他の MCP サーバーも AI から見える．
   `CODEX_HOME` を専用ディレクトリにすれば分離できるが，`auth.json` もその配下にあるため，
   その中で `codex login` と `codex mcp login` を対話で行う必要がある．

**未検証の点が2つある．** `sandbox_workspace_write.network_access` のキー名，および
`approval_policy="never"` 下で Notion MCP 呼び出しが拒否されないか．

### `curl` の `file://` を塞ぐ

アップロード専用のラッパーに置き換える案がある（混入防止の節を参照）．

## 作らないもの

- 重複検知
- 対話画面から起動するスキル
- Notion への書き込みをスクリプトで行う方式（**Notion 登録は AI が持つ**）
- Notion データベースへのプロパティ追加
- OS 通知（Slack のみ）
- Claude Code・Codex 以外のエンジン
