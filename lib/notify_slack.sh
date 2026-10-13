#!/usr/bin/env bash
# Slack 通知（Web API）
#
# 1資料につき1メッセージ．枠を取得した直後に「処理中」を投稿し，
# 終了時に chat.update で同じメッセージを書き換える．
#
# Incoming Webhook は使わない．応答が "ok" という文字列だけで，
# 書き換えに必要な ts を返さないためである（実測で確認済み）．
#
# 終端は2つしかない．全ステップが完了したら ✅，ひとつでも欠けたら ❌ である．
# 何が残っているかはステップの行が示すので，状態に名前を付けて区別しない．
#
#   ✅ 完了   全ステップ ok                     → 作業なし
#   ❌ 失敗   ひとつ以上が未完了                → ステップの行を見て対処する
#
# ❌ のうち，page と complete が ok でファイル側だけが欠けている場合は，
# AI の再実行は不要で，ファイルを動かすだけで終わる．
#
# 送信に失敗しても処理全体は失敗扱いにしない（ログに記録するのみ）．
# トークンをログや通知本文に出力しない．

SLACK_TS=""        # 投稿したメッセージの ts（書き換えに使う）
SLACK_CHANNEL_ID=""  # 応答から得たチャンネルID（chat.update は ID が必要）

# Slack API を呼ぶ．本文（JSON）は標準入力から受け取る．
slack_call() {  # <メソッド名> <応答の保存先>
  local method="$1" out="$2" rc=0
  curl -sS -X POST "$SLACK_API/$method" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-type: application/json; charset=utf-8' \
    --max-time 15 --data-binary @- >"$out" 2>>"$RUN_LOG" || rc=$?
  return "$rc"
}

slack_ok() {  # <応答のパス>
  [ -f "$1" ] || return 1
  [ "$(json_get "$1" ok)" = "True" ] && return 0
  return 1
}

slack_enabled() {
  [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL:-}" ]
}

# 処理の開始を投稿する（枠を取得した後に呼ぶ）
notify_start() {  # <対象の表示名>
  local target="$1" resp text

  if ! slack_enabled; then
    log_msg "Slack: SLACK_BOT_TOKEN または SLACK_CHANNEL が未設定のため通知しない"
    return 0
  fi

  text="$(printf '%s\n' \
    ":hourglass_flowing_sand: *処理中*（$(mode_label)） — ${target}" \
    "run_id \`${RUN_ID}\`")"

  resp="$RECORD_DIR/slack_post.json"
  if ! py -c '
import json, os, sys
sys.stdout.write(json.dumps({"channel": os.environ["SLACK_CHANNEL"], "text": sys.argv[1]},
                            ensure_ascii=False))
' "$text" | slack_call chat.postMessage "$resp"; then
    log_msg "Slack: 開始通知の送信に失敗した（curl）"
    return 0
  fi

  if slack_ok "$resp"; then
    SLACK_TS="$(json_get "$resp" ts)"
    SLACK_CHANNEL_ID="$(json_get "$resp" channel)"
    log_msg "Slack: 開始を通知した（ts=${SLACK_TS}）"
  else
    log_msg "Slack: 開始通知が拒否された（error=$(json_get "$resp" error)）"
  fi
  return 0
}

# 開始通知を書き換える．投稿できていなければ新規に投稿する．
slack_finish() {  # <本文>
  local text="$1" resp

  if ! slack_enabled; then
    return 0
  fi

  if [ -z "$SLACK_TS" ]; then
    # 開始通知が出せていなかった場合は，結果だけでも新規に投稿する
    resp="$RECORD_DIR/slack_post.json"
    py -c '
import json, os, sys
sys.stdout.write(json.dumps({"channel": os.environ["SLACK_CHANNEL"], "text": sys.argv[1]},
                            ensure_ascii=False))
' "$text" | slack_call chat.postMessage "$resp" || true
    slack_ok "$resp" && log_msg "Slack: 結果を新規に投稿した" \
      || log_msg "Slack: 結果の投稿に失敗した（error=$(json_get "$resp" error)）"
    return 0
  fi

  resp="$RECORD_DIR/slack_update.json"
  py -c '
import json, sys
sys.stdout.write(json.dumps({"channel": sys.argv[1], "ts": sys.argv[2], "text": sys.argv[3]},
                            ensure_ascii=False))
' "$SLACK_CHANNEL_ID" "$SLACK_TS" "$text" | slack_call chat.update "$resp" || true

  if slack_ok "$resp"; then
    log_msg "Slack: 結果に書き換えた"
  else
    log_msg "Slack: 書き換えに失敗した（error=$(json_get "$resp" error)）"
  fi
  return 0
}

mode_label() {
  case "${RUN_MODE:-}" in
    auto)   printf '自動' ;;
    manual) printf '手動' ;;
    *)      printf '不明' ;;
  esac
}

run_footer() {
  printf '• %s / %s / effort=%s ・ %s秒 ・ run_id `%s`' \
    "$PAPER_ENGINE" "$PAPER_MODEL" "$PAPER_EFFORT" "$(elapsed)" "$RUN_ID"
}

# ステップの行．経路に存在するステップだけを STEP_LIST の順に出す．
step_label() {  # <ステップ名>
  case "$1" in
    page)     printf 'ページ作成' ;;
    complete) printf 'ページ完成' ;;
    rename)   printf '改名' ;;
    move)     printf '移動' ;;
    *)        printf '%s' "$1" ;;
  esac
}

step_line() {
  local s out="" mark
  for s in $STEP_LIST; do
    if [ "$(step_state "$s")" = ok ]; then
      mark=':white_check_mark:'
    else
      mark=':x:'
    fi
    out="${out}${out:+  }$(step_label "$s") ${mark}"
  done
  printf '%s' "$out"
}

# Notion の行．再実行の前に既存ページを消す必要があるかどうかを示す．
notion_line() {
  if [ -z "${NOTION_URL:-}" ]; then
    printf 'ページ未作成 — そのまま再実行できます'
  elif [ "$(step_state complete)" = ok ]; then
    printf '%s' "$NOTION_URL"
  else
    printf '%s ← 既存ページ．削除してから再実行' "$NOTION_URL"
  fi
}

# 結果の通知（開始通知を書き換える）
notify_result() {
  local body

  if steps_all_ok; then
    body=":white_check_mark: *完了*（$(mode_label)） — ${TITLE:-$TARGET_LABEL}"
  else
    body=":x: *失敗*（$(mode_label)） — ${TITLE:-$TARGET_LABEL}"
  fi
  body="${body}
$(step_line)"

  if ! steps_all_ok && [ -n "${ERROR_MESSAGE:-}" ]; then
    body="${body}
• 理由: ${ERROR_MESSAGE}"
  fi
  if [ -n "${CITATION_KEY:-}" ]; then
    body="${body}
• Citation Key: \`${CITATION_KEY}\`"
  fi
  body="${body}
• Notion: $(notion_line)"
  if [ -n "${PLACEMENT:-}" ]; then
    body="${body}
• ファイル: ${PLACEMENT}"
  fi
  body="${body}
$(run_footer)"
  if ! steps_all_ok; then
    body="${body}
• ログ: ${RECORD_DIR}"
  fi
  if [ -n "${GUARD_WARNING:-}" ]; then
    body="${body}
• :warning: ${GUARD_WARNING}"
  fi

  slack_finish "$body"
}
