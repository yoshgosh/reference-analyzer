#!/usr/bin/env bash
# 解析：プロンプト組立 → エンジン起動 → 出力検証
#
# このファイルはファイルの改名・移動を行わない．AI も行わない（指示文で禁止している）．
# AI は citation_key を返すだけで，改名は lib/place.sh が行う．
#
# 入出力:
#   入力  プロンプト（argv）と作業ディレクトリ（AI のカレント．対象と aux/ だけが入る）
#   出力  RESULT_* のグローバル（構造化出力を検証・正規化したもの）
#   副作用 Notion ページの作成，作業ディレクトリ内の一時ファイル

# AI が実行できるコマンドの唯一の定義元．
# engine_*.sh が許可リストを組み立て，build_prompt が指示文へ注入する．
ALLOWED_COMMANDS="pdftotext pdfimages pdftoppm pdfinfo curl"

# 対象と補助資料の記述を組み立てて prompt.md を書く
build_prompt() {  # <対象の記述> <補助資料の記述（空でよい）>
  local target="$1" aux="$2" sedexpr aux_section=""
  sedexpr="s|{{NOTION_DATA_SOURCE_ID}}|$NOTION_DATA_SOURCE_ID|g;s|{{ALLOWED_COMMANDS}}|$ALLOWED_COMMANDS|g"

  if [ -n "$aux" ]; then
    aux_section="$(printf '%s\n' \
      "" \
      "## 補助資料" \
      "" \
      "次の資料は，上記の対象を補助するものであり，**別の文献ではない**．" \
      "" \
      "$aux")"
  fi

  {
    sed "$sedexpr" "$REPO_ROOT/prompts/registration.md"
    printf '\n\n---\n\n'
    sed "$sedexpr" "$REPO_ROOT/prompts/headless_addendum.md"
    printf '\n\n---\n\n# 今回の対象\n\n%s\n%s\n' "$target" "$aux_section"
  } >"$RECORD_DIR/prompt.md"

  log_msg "prompt.md を作成した（$(wc -c <"$RECORD_DIR/prompt.md" | tr -d ' ') バイト）"
}

# AI を実行し，出力を検証して RESULT_* を設定する．
# 返り値 0 = status が success かつ citation_key が妥当，1 = それ以外
analyze() {  # <対象の記述> <補助資料の記述>
  build_prompt "$1" "$2"

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
      "$raw" "$REPO_ROOT/schema/result.schema.json" "$RESULT_JSON" 2>>"$RUN_LOG"; then
    RESULT_STATUS="$(json_get "$RESULT_JSON" status)"
    CITATION_KEY="$(normalize_key "$(json_get "$RESULT_JSON" citation_key)")"
    TITLE="$(json_get "$RESULT_JSON" title)"
    NOTION_URL="$(json_get "$RESULT_JSON" notion_url)"
    ERROR_MESSAGE="$(json_get "$RESULT_JSON" error)"
  else
    log_msg "出力JSONの検証に失敗した"
    RESULT_STATUS="failed"; CITATION_KEY=""; TITLE=""; NOTION_URL=""
    ERROR_MESSAGE="AIの出力JSONを検証できなかった（記録: ${RECORD_DIR}）"

    # 構造化出力が無くてもページが作成済みであることはありうる．
    # 存在するページを「未作成・再実行可」と通知すると重複登録になるため，
    # transcript から URL を拾って通知の種類を正しく選べるようにする．
    NOTION_URL="$(engine_find_notion_url "${SESSION_ID:-}")"
    if [ -n "$NOTION_URL" ]; then
      log_msg "transcript から作成済みページを検出した: $NOTION_URL"
    fi
    # 記録の形を揃えるため，検証できなかった場合も result.json を残す
    py -c '
import json, sys
json.dump({"status": "failed", "citation_key": "", "title": "",
           "notion_url": sys.argv[3], "error": sys.argv[2]},
          open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
' "$RESULT_JSON" "${engine_error:-$ERROR_MESSAGE}" "$NOTION_URL" 2>/dev/null || true
  fi

  # 成功の定義：終了コード0，status=success，正規化後の citation_key が妥当
  if [ "$ENGINE_RC" = "0" ] && [ "$RESULT_STATUS" = "success" ] && key_is_sane "$CITATION_KEY"; then
    [ -n "${GUARD_WARNING:-}" ] && log_msg "注意: 成功したが混入ガードの警告がある: ${GUARD_WARNING}"
    return 0
  fi

  # エンジン自身の失敗が最も上位の原因なので，これを優先する
  if [ -n "$engine_error" ]; then
    ERROR_MESSAGE="$engine_error"
  elif [ "$RESULT_STATUS" = "success" ] && ! key_is_sane "$CITATION_KEY"; then
    ERROR_MESSAGE="citation_key が妥当でない（正規化後: \"$CITATION_KEY\" / 正規化前: \"$(json_get "$RESULT_JSON" citation_key)\"）．非ASCII名のローマ字化に失敗した可能性がある"
  fi
  [ -z "$ERROR_MESSAGE" ] && ERROR_MESSAGE="原因不明（終了コード=${ENGINE_RC} status=${RESULT_STATUS}）"
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
