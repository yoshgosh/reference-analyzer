#!/usr/bin/env bash
# 解析と登録：プロンプト組立 → エンジン起動 → 出力検証 → Notion への登録
#
# このファイルはファイルの改名・移動を行わない．AI も行わない（指示文で禁止している）．
# AI は citation_key を返すだけで，改名は lib/place.sh が行う．
#
# AI は Notion に触れない．AI が返した内容を，create_page がスクリプトから登録する．
#
# 入出力:
#   入力  プロンプト（argv）と作業ディレクトリ（AI のカレント．対象と aux/ だけが入る）
#   出力  RESULT_* のグローバル（構造化出力を検証・正規化したもの），NOTION_URL
#   副作用 Notion ページの作成，作業ディレクトリ内の一時ファイル，記録ディレクトリへの保存

# AI が実行できるコマンドの唯一の定義元．
# engine_*.sh が許可リストを組み立て，build_prompt が指示文へ注入する．
ALLOWED_COMMANDS="pdftotext pdfimages pdftoppm pdfinfo curl"

# 対象と補助資料の記述を組み立てて prompt.md を書く．
# 既存タグを Notion から取得して埋め込むので，取得できなければ 1 を返す（AI は起動しない）．
build_prompt() {  # <対象の記述> <補助資料の記述（空でよい）>
  local target="$1" aux="$2" tags aux_section=""

  if ! tags="$(py "$REPO_ROOT/lib/notion.py" tags 2>>"$RUN_LOG")"; then
    ERROR_MESSAGE="Notion のデータベースを確認できなかった（詳細: ${RUN_LOG}）"
    return 1
  fi

  if [ -n "$aux" ]; then
    aux_section="$(printf '%s\n' \
      "" \
      "## 補助資料" \
      "" \
      "次の資料は，上記の対象を補助するものであり，**別の文献ではない**．" \
      "" \
      "$aux")"
  fi

  py -c '
import sys
repo, tags, commands, target, aux, out = sys.argv[1:7]
parts = [open(f"{repo}/prompts/{name}", encoding="utf-8").read()
         for name in ("registration.md", "headless_addendum.md")]
text = "\n\n---\n\n".join(parts)
text = text.replace("{{EXISTING_TAGS}}", tags or "（まだ無い）")
text = text.replace("{{ALLOWED_COMMANDS}}", commands)
text += f"\n\n---\n\n# 今回の対象\n\n{target}\n{aux}\n"
open(out, "w", encoding="utf-8").write(text)
' "$REPO_ROOT" "$tags" "$ALLOWED_COMMANDS" "$target" "$aux_section" "$RECORD_DIR/prompt.md"

  log_msg "prompt.md を作成した（$(wc -c <"$RECORD_DIR/prompt.md" | tr -d ' ') バイト）"
}

# 対象の所在を記録する．登録だけをやり直すとき（ref --register）に，
# 改名・移動の対象を知るために使う．
save_target() {
  py -c '
import json, sys
keys = ("kind", "mode", "path", "url", "label")
json.dump(dict(zip(keys, sys.argv[2:])), open(sys.argv[1], "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
' "$RECORD_DIR/target.json" "$TARGET_KIND" "${RUN_MODE:-}" "${TARGET_PATH:-}" \
    "$([ "$TARGET_KIND" = url ] && printf '%s' "$TARGET_LABEL")" "$TARGET_LABEL"
}

# AI を実行し，出力を検証して RESULT_* を設定する．
# 返り値 0 = status が success かつ citation_key が妥当，1 = それ以外
analyze() {  # <対象の記述> <補助資料の記述>
  save_target
  if ! build_prompt "$1" "$2"; then
    log_msg "$ERROR_MESSAGE"
    step_failed analyze
    return 1
  fi

  # 足場のファイルは AI のカレントディレクトリに置かない．
  # 置くと AI が「対象以外のファイルがある」と報告してしまう．
  local raw="$RECORD_DIR/engine_raw.json"
  local errout="$RECORD_DIR/engine.stderr"
  local rc=0

  log_msg "エンジンを起動する"
  run_engine "$WORK_DIR" "$RECORD_DIR/prompt.md" "$raw" "$errout" || rc=$?
  ENGINE_RC="$rc"
  log_msg "エンジン終了コード=$rc"

  SESSION_ID="$(engine_session_id "$raw")"
  [ -n "$SESSION_ID" ] && log_msg "session_id=$SESSION_ID"

  # エンジン自身が失敗した場合は，その理由を優先して報告する．
  # 利用上限（429）などを「出力JSONの検証に失敗」として埋もれさせてはならない．
  local engine_error
  engine_error="$(engine_error_summary "$raw")"
  [ -n "$engine_error" ] && log_msg "エンジンのエラー: $engine_error"

  RESULT_JSON="$RECORD_DIR/result.json"
  if py "$REPO_ROOT/lib/validate_result.py" \
      "$raw" "$REPO_ROOT/schema/result.schema.json" "$WORK_DIR" "$RECORD_DIR" 2>>"$RUN_LOG"; then
    RESULT_STATUS="$(json_get "$RESULT_JSON" status)"
    CITATION_KEY="$(normalize_key "$(json_get "$RESULT_JSON" citation_key)")"
    TITLE="$(json_get "$RESULT_JSON" title)"
    ERROR_MESSAGE="$(json_get "$RESULT_JSON" error)"
  else
    log_msg "出力JSONの検証に失敗した"
    RESULT_STATUS="failed"; CITATION_KEY=""; TITLE=""
    ERROR_MESSAGE="AIの出力JSONを検証できなかった（詳細: ${RUN_LOG}）"
  fi

  # 成功の定義：終了コード0，status=success，正規化後の citation_key が妥当
  if [ "$ENGINE_RC" = "0" ] && [ "$RESULT_STATUS" = "success" ] && key_is_sane "$CITATION_KEY"; then
    [ -n "${GUARD_WARNING:-}" ] && log_msg "注意: 成功したが混入ガードの警告がある: ${GUARD_WARNING}"
    step_completed analyze
    return 0
  fi
  step_failed analyze

  # エンジン自身の失敗が最も上位の原因なので，これを優先する
  if [ -n "$engine_error" ]; then
    ERROR_MESSAGE="$engine_error"
  elif [ "$RESULT_STATUS" = "success" ] && ! key_is_sane "$CITATION_KEY"; then
    ERROR_MESSAGE="citation_key が妥当でない（正規化後: \"$CITATION_KEY\" / 正規化前: \"$(json_get "$RESULT_JSON" citation_key)\"）．非ASCII名のローマ字化に失敗した可能性がある"
  fi
  [ -z "$ERROR_MESSAGE" ] && ERROR_MESSAGE="原因不明（終了コード=${ENGINE_RC} status=${RESULT_STATUS}）"
  return 1
}

# 検証済みの出力から Notion ページを作る．
# lib/notion.py は失敗時に作りかけのページをゴミ箱へ移すので，失敗は原則
# 「ページ未作成」である．ゴミ箱へ移せなかった場合だけ NOTION_URL が残る．
# 返り値 0 = 作成した，1 = 作成できなかった
create_page() {
  local url rc=0
  # 正規化後のキーで登録する（ファイル名と Notion のキーを一致させる）
  py -c '
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
r["citation_key"] = sys.argv[2]
json.dump(r, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
' "$RESULT_JSON" "$CITATION_KEY"

  url="$(py "$REPO_ROOT/lib/notion.py" register "$RESULT_JSON" "$RECORD_DIR" 2>>"$RUN_LOG")" || rc=$?
  NOTION_URL="$url"
  if [ "$rc" = "0" ]; then
    log_msg "Notion ページを作成した: $NOTION_URL"
    step_completed create
    return 0
  fi
  step_failed create
  ERROR_MESSAGE="Notion への登録に失敗した: $(tail -n 1 "$RUN_LOG")"
  log_msg "$ERROR_MESSAGE"
  # ページが残っていなければ，AI を再実行せずに登録だけをやり直せる
  [ -z "$NOTION_URL" ] && RETRY_HINT="ref --register $RUN_ID"
  return 1
}

save_records() {
  if engine_save_transcript "$WORK_DIR" "$RECORD_DIR" "${SESSION_ID:-}"; then
    log_msg "実行記録（transcript）を保存した"
  else
    log_msg "警告: 実行記録（transcript）を取得できなかった"
  fi
  log_msg "記録先=$RECORD_DIR"
}
