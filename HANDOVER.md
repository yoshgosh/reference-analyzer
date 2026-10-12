# handover.md：論文PDF自動要約・Notion登録パイプライン 実装仕様

> 本書は，設計検討（claude.ai チャット）で確定した仕様を，実装担当のコーディングエージェントへ引き継ぐためのものである．
> 「確定」はユーザーが明示的に承認した事項，「実装者判断」は本書で暫定的に定めた既定値（変更してよいが報告すること），「要検証」は事実確認が済んでいない事項を表す．

---

## 1. 目的

現在 claude.ai のチャット（プロジェクト）で1本ずつ手作業で行っている「論文PDFの要約 → Notionデータベース登録」を，次の形で自動化する．

- 決まったフォルダ（inbox）にPDFを置くと，自動で処理が始まる．
- コマンドでファイル／フォルダ／URLを指定して処理することもできる．
- 処理済みPDFは Citation Key に改名して保存する．
- 結果は Slack に通知する．

### 最重要要件

**論文同士の情報が混ざってはならない．** 1つの資料の処理に，他の資料・過去の実行・メモリの情報が入り込まないことを，設計と検証の両面で担保する．

---

## 2. 全体構造（確定）

3層で分担する．

| 層 | 役割 | 実体 |
|---|---|---|
| 見張り役 | inbox への追加を検知して段取り役を起動 | macOS launchd（WatchPaths） |
| 段取り役 | 資料を1本ずつAIへ渡す，改名・移動，ログ，通知 | シェルスクリプト（bash） |
| 作業担当 | PDF読解，Web検索，要約，Rating，代表画像，Notion登録 | Claude Code（`claude -p`）または Codex（`codex exec`） |

### 分担の原則（確定）

- 判断を要する処理はすべてAIが行う（既存の指示文に書かれた内容すべて．**Notion登録もAIが行う**）．
- 機械的な処理（監視，配分，改名，移動，記録，通知）はスクリプトが行う．
- **AIはファイルの改名・移動を行わない．** AIは結果をJSONで返し，スクリプトが改名する．

### 独立性の原則（確定）

- 資料1本につき，AIのプロセスを1つ新規に起動する．
- 過去の実行を引き継ぐオプション（`--continue`，`--resume`，`codex exec resume` 等）は使用しない．
- 資料1本ごとに専用の作業ディレクトリを作る．

---

## 3. 確定仕様一覧

| 項目 | 仕様 |
|---|---|
| 実行環境 | macOS |
| AIエンジン | Claude Code と Codex の両方に対応し，環境変数で切り替える．**まず Claude Code で実装・検証し，その後 Codex に対応する** |
| 起動方法 | 自動（inbox）と手動コマンドの両方 |
| 対象資料 | inbox：PDFのみ．手動コマンド：PDF，フォルダ，URL（Webページ・GitHub等） |
| ファイル名 | Citation Key（例：`Smith2024Example.pdf`）．同名がある場合は `_2`，`_3` を付与 |
| 保存先 | `~/Documents/研究/論文/` 直下（iCloud同期下．まずこの構成で試行する） |
| 通知 | Slack Incoming Webhook のみ．成功・失敗とも送る．OS通知は使わない |
| 重複 | 検知しない．同じ資料でもそのまま登録する（既存指示文の「重複登録する」と整合） |
| 同時処理数 | 既定2．環境変数で変更可能 |
| 実行記録 | 成功・失敗とも保存する．保存期間は既定7日，環境変数で変更可能 |
| 指示文・設定の正本 | リポジトリ．秘密情報・ID類は `.env` |
| スキル（対話画面からの起動） | 当面作らない |
| Notion「要確認」プロパティ | 追加しない |

---

## 4. ディレクトリ構成

### 4.1 データ側（確定）

```
~/Documents/研究/論文/          ← PAPER_ROOT
  Smith2024Example.pdf          ← 処理済みPDF（直下に並ぶ）
  inbox/                        ← 自動処理の置き場（launchd が監視）
  failed/                       ← 失敗したPDF
  .work/                        ← 1実行ごとの作業ディレクトリ（隠し）
  .logs/                        ← ログ・実行記録（隠し，保存期間あり）
```

- 各サブフォルダは，個別の環境変数で別の場所へ移せるようにする（§5）．
- iCloud同期で問題が出た場合の対処方針：まず `inbox` と `.work` を同期対象外（例：`~/Papers/`）へ移す（環境変数の変更のみで対応できること）．

### 4.2 リポジトリ側（確定：名前 `reference-analyzer` と場所．構成は実装者判断）

```
~/dev/reference-analyzer/
  bin/
    paper                       ← 手動コマンドの入口
  lib/
    process_queue.sh            ← inbox を走査し並列で配る
    run_one.sh                  ← 資料1本の処理
    notify_slack.sh             ← Slack 通知
    cleanup.sh                  ← 保存期間を過ぎた記録の削除
  prompts/
    registration.md             ← 既存の指示文（正本）
    headless_addendum.md        ← 無人実行用の追加ルール
  schema/
    result.schema.json          ← AIの最終出力スキーマ
  launchd/
    com.user.reference-analyzer.plist.template
  .env.example                  ← コミットする（値は空）
  .env                          ← コミットしない（.gitignore）
  README.md
```

**注意（要検証）**：データ側のディレクトリはリポジトリの外に置く．Claude Code は起動ディレクトリの上位にある `CLAUDE.md` も読み込むため，作業ディレクトリがリポジトリ内にあると，開発用の指示が論文処理に混入するおそれがある．

---

## 5. 環境変数

| 変数名 | 既定値 | 説明 | 区分 |
|---|---|---|---|
| `PAPER_ROOT` | `~/Documents/研究/論文` | 処理済みPDFの保存先．他フォルダの基準 | 確定 |
| `PAPER_INBOX_DIR` | `$PAPER_ROOT/inbox` | 自動処理の置き場 | 確定 |
| `PAPER_FAILED_DIR` | `$PAPER_ROOT/failed` | 失敗したPDF | 確定 |
| `PAPER_WORK_DIR` | `$PAPER_ROOT/.work` | 作業ディレクトリ | 確定 |
| `PAPER_LOG_DIR` | `$PAPER_ROOT/.logs` | ログ・実行記録 | 確定 |
| `PAPER_ENGINE` | `claude` | `claude` または `codex` | 確定 |
| `PAPER_PARALLEL` | `2` | 同時処理数 | 確定 |
| `PAPER_LOG_RETENTION_DAYS` | `7` | 実行記録の保存日数 | 確定 |
| `NOTION_DATA_SOURCE_ID` | （必須） | 登録先データソースID | 確定 |
| `SLACK_WEBHOOK_URL` | （必須） | Slack Incoming Webhook URL．**秘密情報** | 確定 |

- `.env` はリポジトリ直下に置き，`.gitignore` に含める．`.env.example` には変数名のみ記載する．
- 現行の指示文は `data_source_id` を直接記載しているため，`prompts/registration.md` では `{{NOTION_DATA_SOURCE_ID}}` のようなプレースホルダーにし，実行時に置換する（実装者判断）．
- 日本語を含むパス（`研究/論文`）を正しく扱うこと．すべての変数展開をクォートする．

---

## 6. 処理の流れ

### 6.1 自動（inbox）

1. launchd が `PAPER_INBOX_DIR` の変化を検知し，`lib/process_queue.sh` を起動する．
2. inbox 内の `*.pdf` のうち，**書き込みが完了したもの**だけを対象とする（§8.1）．
3. 対象を `PAPER_PARALLEL` 並列で `run_one.sh` に渡す．

### 6.2 手動コマンド（`bin/paper`）

インターフェースは実装者判断とするが，次を満たすこと．

```
paper <PDFファイル...>     # 指定したPDFを処理
paper <フォルダ>           # フォルダ内のPDFを処理
paper <URL...>             # Webページ・GitHub等を処理
```

- PDFとフォルダは inbox に入れて，自動と同じ経路で処理する（処理本体を1つに保つため）．
- URLは inbox を経由せず，`run_one.sh` をURLモードで呼ぶ．URLの場合は改名・保存するファイルがないため，Notion登録・記録・通知のみ行う．
- 未決事項：指定したPDFを移動するかコピーするか，フォルダを再帰的に探索するか（§13）．

### 6.3 1本の処理（`run_one.sh`）

1. 実行ID（例：`20261012-153000-<pid>`）を採番し，`PAPER_WORK_DIR/<ID>/` を作る．
2. PDFをアトミックな `mv` で作業ディレクトリへ移す（他プロセスとの取り合い防止．失敗したら何もせず終了）．
3. 指示文（`registration.md` ＋ `headless_addendum.md` ＋ 対象パス・作業ディレクトリ）を組み立てる．
4. 作業ディレクトリをカレントにしてAIを起動する（§7）．
5. 最終出力（JSON）を検証する．
6. 成功：`citation_key` を ASCII 英数字・`.`・`_`・`-` に正規化し，`PAPER_ROOT/<Key>.pdf` へ移動（同名時は `_2` 等）．
7. 失敗：`PAPER_FAILED_DIR/<ID>_<元のファイル名>` へ移動．
8. 実行記録を `PAPER_LOG_DIR/<ID>/` に保存する（§9）．
9. Slack に通知する（§10）．
10. 成功時は作業ディレクトリを削除．失敗時は調査用に残す（保存期間の削除対象に含める）．

**成功の定義**：AIの終了コードが0，かつ出力JSONの `status` が `success`，かつ正規化後の `citation_key` が空でない．

---

## 7. AIの呼び出し

### 7.1 指示文

- 正本は `prompts/registration.md`（現行の claude.ai プロジェクト指示文をそのまま移す）．
- `prompts/headless_addendum.md` に無人実行用の差分を記載する．内容（確定事項を反映）：
  - 対象は指定した資料1本のみ．他の資料・過去の会話・メモリ・作業ディレクトリ外のファイルの情報を使わない．
  - Web検索で得た情報は，対象と同一の資料（タイトル・著者・DOIが一致）に関するものだけ使う．
  - ユーザーは不在．質問しない．判断できない項目は空欄にする．
  - 一時ファイルは作業ディレクトリ内にのみ作る．
  - 対象PDFの改名・移動・削除をしない．
  - Citation Key は ASCII 英数字のみで構成する（日本語著者はローマ字化）．
  - 代表画像のアップロード手順：Notion MCP の `notion-create-file-upload` を呼び，返却されたアップロード先へ `curl` で送信し，そのファイルを参照する画像ブロックを本文の先頭に置く．失敗したら画像なしで登録を続け，理由を記録する．
  - ステップ4（完了報告）を，§7.4 のJSON出力に置き換える．

### 7.2 Claude Code（第一実装対象）

```bash
claude -p "$PROMPT" \
  --output-format json \
  --json-schema "$(cat schema/result.schema.json)" \
  --permission-mode dontAsk \
  --allowedTools "Read,Write,WebSearch,WebFetch,Bash(python3 *),Bash(curl *),Bash(pdftotext *),Bash(pdfimages *),mcp__notion"
```

- 構造化出力は結果JSONの `structured_output` に入る（確認済み）．
- `--permission-mode dontAsk` では，許可リスト外の操作は確認待ちにならず拒否される（確認済み）．許可リストは最初の検証で過不足を調整すること．
- `--bare` は使わない．`--bare` はサブスクリプションのログインやキーチェーンを読まずAPIキーを要求するため（確認済み），Notion MCP の OAuth 認証も使えなくなる見込み（要検証）．
- Notion MCP の登録：`claude mcp add --transport http --scope user notion https://mcp.notion.com/mcp` → 対話モードの `/mcp` で OAuth 認証（初回のみ，手動）．

### 7.3 Codex（第二実装対象）

```bash
codex exec --skip-git-repo-check \
  --sandbox workspace-write \
  -c 'sandbox_workspace_write.network_access=true' \
  -c 'approval_policy="never"' \
  -c 'web_search="live"' \
  --json \
  --output-schema schema/result.schema.json \
  -o "$WORK/result.json" \
  "$PROMPT"
```

- **`--ephemeral` は付けない**（実行記録を残すため．確定）．
- `--json` で全イベント（コマンド実行，MCP呼び出し，Web検索等）が JSONL で標準出力に出る（確認済み）．これを実行記録として保存する．
- 既定は読み取り専用サンドボックスのため `--sandbox workspace-write` を指定（確認済み）．
- `sandbox_workspace_write.network_access` のキー名，および `approval_policy="never"` 下で Notion MCP 呼び出しが拒否されないかは要検証．
- Notion MCP の登録：`codex mcp add notion --url https://mcp.notion.com/mcp` → `codex mcp login notion`．

### 7.4 出力スキーマ（`schema/result.schema.json`）

```json
{
  "type": "object",
  "properties": {
    "status": { "type": "string", "enum": ["success", "failed"] },
    "citation_key": { "type": "string" },
    "title": { "type": "string" },
    "notion_url": { "type": "string" },
    "rating": { "type": "string" },
    "rating_reason": { "type": "string" },
    "image_status": { "type": "string" },
    "error": { "type": "string" }
  },
  "required": ["status", "citation_key", "title", "notion_url", "rating", "rating_reason", "image_status", "error"],
  "additionalProperties": false
}
```

- 該当しない項目は空文字列とする（Codex の構造化出力は全項目必須の形式に合わせる）．
- `status` は Notion 登録まで完了した場合のみ `success`．
- ページ作成後に失敗した場合も `notion_url` を必ず記録させる（調査・手動補修のため）．

---

## 8. 堅牢性

### 8.1 inbox の取り込み条件

- 拡張子 `.pdf`（大文字小文字を区別しない）のみ．隠しファイル，iCloud のプレースホルダー（`.icloud`），ダウンロード途中のファイル（`.crdownload`，`.download` 等）は無視する．
- サイズが一定時間（例：2秒）変化しないことを確認してから取り込む（実装者判断）．

### 8.2 多重起動

- launchd の発火が重なっても，同じPDFを二重に処理しないこと．§6.3 のアトミックな `mv` による確保で担保する．
- 処理中に新しいPDFが追加された場合も，取りこぼさないこと（処理終了時に inbox を再走査する等．実装者判断）．

### 8.3 launchd 実行時の環境

- launchd は対話シェルの環境変数・PATH を引き継がない．plist で PATH を明示し，`.env` はスクリプト側で読み込む．
- `claude`／`codex` の実行ファイルの場所を PATH に含める．

---

## 9. 実行記録（確定：保存する．期間7日）

`PAPER_LOG_DIR/<ID>/` に次を保存する．

| ファイル | 内容 |
|---|---|
| `run.log` | 開始・終了時刻，対象，エンジン，終了コード，移動先 |
| `result.json` | AIの最終出力 |
| `transcript.*` | AIの実行記録（ツール呼び出しの経過） |
| `prompt.md` | 実際に渡した指示文（再現・調査用） |

- Claude Code：結果JSONの `session_id` を記録する．実行記録は Claude Code が保存するセッションファイル（`.jsonl`）を複製する，または `--output-format stream-json --verbose` で取得する（どちらが構造化出力と両立するかは要検証）．
- Codex：`--json` の出力をそのまま保存する．
- `cleanup.sh`：処理開始時に，`PAPER_LOG_RETENTION_DAYS` を過ぎた `PAPER_LOG_DIR` と `PAPER_WORK_DIR` 配下を削除する．`failed/` のPDF自体は削除しない（実装者判断）．
- Claude Code・Codex がそれぞれ自前で保存するセッション記録の保存期間は，本仕様の対象外とする（必要なら別途設定）．

---

## 10. Slack 通知（確定：Webhook，成功・失敗とも）

- `SLACK_WEBHOOK_URL` へ `curl` で JSON を POST する．
- 1資料につき1通（実装者判断）．

| 種別 | 含める情報 |
|---|---|
| 成功 | タイトル，Citation Key，Notion ページURL，Rating，代表画像の結果，エンジン，所要時間 |
| 失敗 | 元のファイル名またはURL，失敗理由（`error`），作成済みなら Notion URL，実行ID，ログの場所 |

- 送信に失敗しても処理全体は失敗扱いにしない．ログに記録するのみ（OS通知は使わない．確定）．
- Webhook URL をログや通知本文に出力しない．

---

## 11. 実装の段階（実装者判断．順序は確定事項「まずClaude」に従う）

| 段階 | 内容 | 完了条件 |
|---|---|---|
| 1 | Claude Code で PDF 1本を手動処理 | Notion にページ（代表画像つき）が作成され，PDFが改名・保存され，Slack に通知が届く |
| 2 | 複数PDFの並列処理・失敗処理・記録・保存期間 | 2本以上を同時に処理し，内容が混ざらない．失敗時に `failed/` へ移り通知が届く |
| 3 | launchd による自動起動 | inbox に置くだけで段階2と同じ結果になる |
| 4 | URL の手動処理 | Webページ・GitHub の登録ができる |
| 5 | Codex 対応 | `PAPER_ENGINE=codex` で段階1〜4と同じ結果になる |

---

## 12. 要検証事項（優先順）

1. **混入しないこと**：異なる2本を同時に処理し，要約・書誌・画像が入れ替わったり混ざったりしないこと．
2. **Claude Code の自動メモリ・CLAUDE.md**：作業ディレクトリを毎回変えても，自動メモリやユーザー全体の `~/.claude/CLAUDE.md` 等が論文処理に影響しないか．影響する場合の無効化方法．
3. **Notion への画像アップロード**：`notion-create-file-upload` ＋ `curl` で画像ブロックが作成できるか．
4. **非対話実行での Notion MCP 認証**：OAuth 認証済みの状態で `claude -p`／`codex exec` から利用できるか．認証切れ時に失敗として検知・通知できるか．
5. **許可リストの過不足**：`dontAsk` 下で必要な操作が拒否されないか．
6. **iCloud 配下での動作**：launchd から `~/Documents` 配下へ読み書きできるか（macOS のアクセス許可），同期中の書きかけファイルで誤起動しないか，`.work` の同期で遅延・競合が起きないか，処理済みPDFの実体が退避されて困らないか．
7. **Codex 固有**：ネットワーク許可の設定キー名，`approval_policy="never"` 下での MCP 呼び出し．
8. **Notion API のレート制限**：同時処理数2で問題が出ないか．

---

## 13. 未決事項（実装前または実装中にユーザーへ確認すること）

1. 手動コマンドでPDFを指定した場合，元のファイルを**移動**するか**コピー**するか．
2. フォルダを指定した場合，サブフォルダまで**再帰的**に探索するか．
3. 段階1の検証に使うテスト用PDF（ユーザーが用意する）．
4. 手動コマンドの名前（本書では仮に `paper`．候補として `ref`）．

---

## 14. 対象外（今回は作らない）

- 重複検知
- 対話画面から起動するスキル
- Notion への書き込みをスクリプトで行う方式
- Notion データベースのプロパティ追加
- OS 通知
- Claude Code／Codex 以外のエンジン

---

## 15. 参考

- 設計検討時の試作スクリプト一式（`process_inbox.sh`，`run_one.sh`，`headless_addendum.md`，`schema.json`，`com.user.paperinbox.plist`，`README.md`）がある．構成の参考とし，本書と食い違う箇所は本書を優先すること．
- Claude Code 非対話実行：https://code.claude.com/docs/en/headless
- Codex 非対話実行：https://learn.chatgpt.com/docs/non-interactive-mode
- Codex サンドボックス：https://learn.chatgpt.com/docs/sandboxing.md
- Codex 設定：https://developers.openai.com/codex/config-basic