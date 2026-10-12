#!/usr/bin/env bash
# Slack Incoming Webhook による通知
#
# - 1資料につき1通を送る．成功・失敗とも送る．
# - 送信に失敗しても処理全体は失敗扱いにしない（ログに記録するのみ）．
# - Webhook URL をログや通知本文に出力しない．

ra_slack_post() {  # <本文（Slack mrkdwn）>
  local text="$1" payload rc=0

  if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    ra_log "Slack: SLACK_WEBHOOK_URL が未設定のため通知を送らなかった"
    return 0
  fi

  payload="$(ra_py -c '
import json, sys
sys.stdout.write(json.dumps({"text": sys.argv[1]}, ensure_ascii=False))
' "$text")"

  # URL は引数に出さず標準入力から渡す（ps で見えないようにする）
  curl -sS -X POST -H 'Content-Type: application/json' \
    --max-time 15 \
    --data-binary @- \
    "$SLACK_WEBHOOK_URL" <<<"$payload" >/dev/null 2>>"$RA_RUN_LOG" || rc=$?

  if [ "$rc" != "0" ]; then
    ra_log "Slack: 通知の送信に失敗した（curl 終了コード=${rc}．処理は失敗扱いにしない）"
  else
    ra_log "Slack: 通知を送信した"
  fi
  return 0
}

# 成功通知 : タイトル，Citation Key，Notion URL，Rating，代表画像，エンジン，所要時間
ra_notify_success() {  # <配置結果の説明>
  local placement="$1" text
  text="$(printf '%s\n' \
    ":white_check_mark: *登録完了* — ${RA_TITLE:-（タイトル不明）}" \
    "• Citation Key: \`${RA_CITATION_KEY}\`" \
    "• Notion: ${RA_NOTION_URL:-（URLなし）}" \
    "• Rating: ${RA_RATING:-（なし）}" \
    "• 代表画像: ${RA_IMAGE_STATUS:-（記録なし）}" \
    "• ファイル: ${placement}" \
    "• エンジン: ${PAPER_ENGINE} / 所要 $(ra_elapsed) 秒 / run_id \`${RA_RUN_ID}\`")"
  [ -n "${RA_GUARD_WARNING:-}" ] && text="$text
• :warning: ${RA_GUARD_WARNING}"
  ra_slack_post "$text"
}

# 失敗通知 : 対象，失敗理由，作成済みなら Notion URL，実行ID，ログの場所
ra_notify_failure() {  # <対象の表示名>
  local target="$1" text
  text="$(printf '%s\n' \
    ":x: *登録失敗* — ${target}" \
    "• 理由: ${RA_ERROR:-（不明）}" \
    "• Notion: ${RA_NOTION_URL:-（ページ未作成）}" \
    "• エンジン: ${PAPER_ENGINE} / 所要 $(ra_elapsed) 秒 / run_id \`${RA_RUN_ID}\`" \
    "• ログ: ${RA_RECORD_DIR}")"
  [ -n "${RA_GUARD_WARNING:-}" ] && text="$text
• :warning: ${RA_GUARD_WARNING}"
  ra_slack_post "$text"
}
