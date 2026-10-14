#!/usr/bin/env bash
# 解析と登録：対象の記述 → プロンプト組立 → エンジン起動 → 出力検証 → Notion への登録
#
# このファイルはファイルの改名・移動を行わない．AI も行わない（指示文で禁止している）．
# AI は citation_key を返すだけで，改名は lib/place.sh が行う．
#
# AI は Notion に触れない．AI が返した内容を，create_page がスクリプトから登録する．
#
# 入出力:
#   入力  TARGET_KIND，TARGET_LABEL（PDF のファイル名 または URL），AUX_DESC（空でよい）．
#         作業ディレクトリには対象のコピーと aux/ だけが入っている（lib/run_one.sh が用意する）
#   出力  RESULT_JSON，CITATION_KEY，TITLE，ERROR_MESSAGE，NOTION_URL，
#         USAGE_SUMMARY（AI の使用量．通知の usage:）
#   副作用 Notion ページの作成，作業ディレクトリ内の一時ファイル，記録ディレクトリへの保存

# AI が実行できるコマンドの唯一の定義元．
# engine_*.sh が許可リストを組み立て，build_prompt が指示文へ注入する．
ALLOWED_COMMANDS="pdftotext pdfimages pdftoppm pdfinfo curl"

# 「今回の対象」の記述．PDF のときは下調べ（lib/pdf_prep.py）を済ませて結果を足す．
# 本文テキストは作業ディレクトリの fulltext.txt に置かれる．
target_description() {
  if [ "$TARGET_KIND" = url ]; then
    printf '%s\n' \
      "- 種別: URL（Webページ・GitHubリポジトリ等）" \
      "- URL: $TARGET_LABEL" \
      "" \
      "このURLの資料のみを処理せよ．改名・保存するファイルは無い．"
    return 0
  fi

  printf '%s\n' \
    "- 種別: PDFファイル" \
    "- ファイル: ./$TARGET_LABEL" \
    "- このファイルは作業ディレクトリ内のコピーである．" \
    "" \
    "この1本のみを処理せよ．"
  # 下調べに失敗しても止めない．AI が自分で実行し直せる
  py "$REPO_ROOT/lib/pdf_prep.py" "$WORK_DIR/$TARGET_LABEL" "$WORK_DIR/fulltext.txt" 2>>"$RUN_LOG" || true
}

# prompt.md を書く．
# 既存タグを Notion から取得して埋め込むので，取得できなければ 1 を返す（AI は起動しない）．
build_prompt() {
  local tags target aux_section=""

  if ! tags="$(py "$REPO_ROOT/lib/notion.py" tags 2>>"$RUN_LOG")"; then
    ERROR_MESSAGE="Notion のデータベースを確認できなかった（詳細: ${RUN_LOG}）"
    return 1
  fi

  target="$(target_description)"

  if [ -n "${AUX_DESC:-}" ]; then
    aux_section="$(printf '%s\n' \
      "" \
      "## 補助資料" \
      "" \
      "次の資料は，上記の対象を補助するものであり，**別の文献ではない**．" \
      "" \
      "$AUX_DESC")"
  fi

  if ! py "$REPO_ROOT/lib/render_prompt.py" headless_addendum.md \
      "EXISTING_TAGS=${tags:-（まだ無い）}" "ALLOWED_COMMANDS=$ALLOWED_COMMANDS" \
      >"$RECORD_DIR/prompt.md" 2>>"$RUN_LOG"; then
    ERROR_MESSAGE="指示文を組み立てられなかった（詳細: ${RUN_LOG}）"
    return 1
  fi
  printf '\n\n---\n\n# 今回の対象\n\n%s\n%s\n' "$target" "$aux_section" >>"$RECORD_DIR/prompt.md"

  log_msg "prompt.md を作成した（$(wc -c <"$RECORD_DIR/prompt.md" | tr -d ' ') バイト）"
}

# 対象と経路を記録する．再開（ref --resume）が経路（ステップの並び）と対象を知るために使う．
save_target() {
  py -c '
import json, sys
keys = ("kind", "mode", "path", "url", "label")
json.dump(dict(zip(keys, sys.argv[2:])), open(sys.argv[1], "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
' "$RECORD_DIR/target.json" "$TARGET_KIND" "${RUN_MODE:-}" "${TARGET_PATH:-}" \
    "$([ "$TARGET_KIND" = url ] && printf '%s' "$TARGET_LABEL")" "$TARGET_LABEL"
}

# AI を実行し，出力を検証する．
# 返り値 0 = エンジンが正常終了し，出力が検証に通り，status が success，1 = それ以外
analyze() {
  local raw="$RECORD_DIR/engine_raw.json" errout="$RECORD_DIR/engine.stderr"
  local rc=0 engine_error verr status

  save_target
  if ! build_prompt; then
    log_msg "$ERROR_MESSAGE"
    step_failed analyze
    return 1
  fi

  # 足場のファイル（prompt.md 等）は記録ディレクトリに置き，AI のカレントには置かない．
  # 置くと AI が「対象以外のファイルがある」と報告してしまう．
  log_msg "エンジンを起動する"
  run_engine "$WORK_DIR" "$RECORD_DIR/prompt.md" "$raw" "$errout" || rc=$?
  log_msg "エンジン終了コード=$rc"

  SESSION_ID="$(engine_session_id "$raw")"
  [ -n "$SESSION_ID" ] && log_msg "session_id=$SESSION_ID"
  USAGE_SUMMARY="$(engine_usage_summary "$raw")"
  [ -n "$USAGE_SUMMARY" ] && log_msg "使用量: $USAGE_SUMMARY"

  # エンジン自身が失敗した場合は，その理由を優先して報告する．
  # 利用上限（429）などを「出力の検証に失敗」として埋もれさせてはならない．
  engine_error="$(engine_error_summary "$raw")"
  [ -n "$engine_error" ] && log_msg "エンジンのエラー: $engine_error"

  # 検証器は標準エラーにだけ書く．失敗の理由は最後の行にある
  RESULT_JSON="$RECORD_DIR/result.json"
  if verr="$(py "$REPO_ROOT/lib/validate_result.py" \
      "$raw" "$REPO_ROOT/schema/result.schema.json" "$WORK_DIR" "$RECORD_DIR" 2>&1)"; then
    [ -n "$verr" ] && log_msg "$verr"
    status="$(json_get "$RESULT_JSON" status)"
    CITATION_KEY="$(json_get "$RESULT_JSON" citation_key)"
    TITLE="$(json_get "$RESULT_JSON" title)"
    ERROR_MESSAGE="$(json_get "$RESULT_JSON" error)"
  else
    log_msg "$verr"
    status=failed; CITATION_KEY=""; TITLE=""
    ERROR_MESSAGE="AIの出力を検証できなかった: $(printf '%s' "$verr" | tail -n 1 | sed 's/^検証失敗: //')"
  fi

  if [ "$rc" = 0 ] && [ "$status" = success ]; then
    [ -n "${GUARD_WARNING:-}" ] && log_msg "注意: 成功したが混入ガードの警告がある: ${GUARD_WARNING}"
    step_completed analyze
    return 0
  fi
  step_failed analyze

  # エンジン自身の失敗が最も上位の原因なので，これを優先する
  [ -n "$engine_error" ] && ERROR_MESSAGE="$engine_error"
  [ -z "$ERROR_MESSAGE" ] && ERROR_MESSAGE="原因不明（終了コード=${rc} status=${status}）"
  return 1
}

# 検証済みの出力から Notion ページを作る．
# lib/notion.py は失敗時に作りかけのページをゴミ箱へ移すので，失敗は原則
# 「ページ未作成」である．ゴミ箱へ移せなかった場合だけ NOTION_URL が残り，
# notion_page.json に complete: false で記録される（再開時に捨てる）．
# 返り値 0 = 作成した，1 = 作成できなかった
create_page() {
  local rc=0
  NOTION_URL="$(py "$REPO_ROOT/lib/notion.py" register "$RESULT_JSON" "$RECORD_DIR" 2>>"$RUN_LOG")" || rc=$?
  if [ "$rc" = 0 ]; then
    log_msg "Notion ページを作成した: $NOTION_URL"
    step_completed create
    return 0
  fi
  step_failed create
  ERROR_MESSAGE="Notion への登録に失敗した: $(tail -n 1 "$RUN_LOG")"
  log_msg "$ERROR_MESSAGE"
  return 1
}

save_records() {
  if engine_save_transcript "$RECORD_DIR" "${SESSION_ID:-}"; then
    log_msg "実行記録（transcript）を保存した"
  else
    log_msg "警告: 実行記録（transcript）を取得できなかった"
  fi
  log_msg "記録先=$RECORD_DIR"
}
