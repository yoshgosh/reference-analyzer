#!/usr/bin/env bash
# Slack Incoming Webhook による通知
#
# - 1資料につき1通を送る．成功・失敗とも送る．
# - 送信に失敗しても処理全体は失敗扱いにしない（ログに記録するのみ）．
# - Webhook URL をログや通知本文に出力しない．

slack_post() {  # <本文（Slack mrkdwn）>
  local text="$1" payload rc=0

  if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    log_msg "Slack: SLACK_WEBHOOK_URL が未設定のため通知を送らなかった"
    return 0
  fi

  payload="$(py -c '
import json, sys
sys.stdout.write(json.dumps({"text": sys.argv[1]}, ensure_ascii=False))
' "$text")"

  # URL は引数に出さず標準入力から渡す（ps で見えないようにする）
  curl -sS -X POST -H 'Content-Type: application/json' \
    --max-time 15 --data-binary @- \
    "$SLACK_WEBHOOK_URL" <<<"$payload" >/dev/null 2>>"$RUN_LOG" || rc=$?

  if [ "$rc" != "0" ]; then
    log_msg "Slack: 通知の送信に失敗した（curl 終了コード=${rc}．処理は失敗扱いにしない）"
  else
    log_msg "Slack: 通知を送信した"
  fi
  return 0
}

notify_success() {  # <配置結果の説明>
  local placement="$1" text
  text="$(printf '%s\n' \
    ":white_check_mark: *登録完了* — ${TITLE:-（タイトル不明）}" \
    "• Citation Key: \`${CITATION_KEY}\`" \
    "• Notion: ${NOTION_URL:-（URLなし）}" \
    "• Rating: ${RATING:-（なし）}" \
    "• 代表画像: ${IMAGE_STATUS:-（記録なし）}" \
    "• ファイル: ${placement:-（なし）}" \
    "• エンジン: ${PAPER_ENGINE} / ${PAPER_MODEL} / effort=${PAPER_EFFORT} / 所要 $(elapsed) 秒 / run_id \`${RUN_ID}\`")"
  [ -n "${GUARD_WARNING:-}" ] && text="$text
• :warning: ${GUARD_WARNING}"
  slack_post "$text"
}

notify_failure() {  # <対象の表示名>
  local target="$1" text
  text="$(printf '%s\n' \
    ":x: *登録失敗* — ${target}" \
    "• 理由: ${ERROR_MESSAGE:-（不明）}" \
    "• Notion: ${NOTION_URL:-（ページ未作成）}" \
    "• エンジン: ${PAPER_ENGINE} / ${PAPER_MODEL} / effort=${PAPER_EFFORT} / 所要 $(elapsed) 秒 / run_id \`${RUN_ID}\`" \
    "• ログ: ${RECORD_DIR}")"
  [ -n "${GUARD_WARNING:-}" ] && text="$text
• :warning: ${GUARD_WARNING}"
  slack_post "$text"
}
