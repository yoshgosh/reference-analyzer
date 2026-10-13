#!/usr/bin/env bash
# Slack 通知（Web API）
#
# 1資料につき1メッセージ．枠を取得した直後に「処理中」を投稿し，
# 終了時に chat.update で同じメッセージを書き換える．
#
# Incoming Webhook は使わない．応答が "ok" という文字列だけで，
# 書き換えに必要な ts を返さないためである（実測で確認済み）．
#
# 終端は4状態あり，必要な作業が異なるため見た目で区別する．
#   ✅ 完了      status=success ＋ 配置成功        → 作業なし
#   ❌ 失敗      status=failed  ＋ notion_url 空   → 直して再実行できる
#   ⚠️ 要補修    status=failed  ＋ notion_url あり → 手で補修（再実行は重複登録になる）
#   ⚠️ 要配置    status=success ＋ 配置失敗        → ファイルを手で移動するだけ
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

# 空のときに非ゼロを返すと，コマンド置換が set -e で処理を止めてしまう
guard_line() {
  [ -n "${GUARD_WARNING:-}" ] && printf '\n• :warning: %s' "$GUARD_WARNING"
  return 0
}

# ✅ 完了
notify_done() {  # <配置結果の説明>
  local placement="$1" text
  text="$(printf '%s\n' \
    ":white_check_mark: *完了*（$(mode_label)） — ${TITLE:-（タイトル不明）}" \
    "• Citation Key: \`${CITATION_KEY}\`" \
    "• Notion: ${NOTION_URL:-（URLなし）}" \
    "• ファイル: ${placement:-（なし）}" \
    "$(run_footer)")$(guard_line)"
  slack_finish "$text"
}

# ❌ 失敗（ページ未作成）— 直して再実行できる
notify_failed() {  # <対象の表示名>
  local target="$1" text
  text="$(printf '%s\n' \
    ":x: *失敗*（$(mode_label)） — ${target}" \
    "• 理由: ${ERROR_MESSAGE:-（不明）}" \
    "• Notion: ページ未作成 — 直して再実行できます" \
    "$(run_footer)" \
    "• ログ: ${RECORD_DIR}")$(guard_line)"
  slack_finish "$text"
}

# ⚠️ 要補修（ページは作成済みだが不完全）— 再実行すると重複する
notify_needs_repair() {  # <対象の表示名> <ファイルの現在地>
  local target="$1" where="$2" text
  text="$(printf '%s\n' \
    ":warning: *要補修*（$(mode_label)） — ${TITLE:-$target}" \
    "• 理由: ${ERROR_MESSAGE:-（不明）}" \
    "• Notion: ${NOTION_URL}  ← ページは作成済み．再実行すると重複します" \
    "• ファイル: ${where:-（なし）}" \
    "$(run_footer)" \
    "• ログ: ${RECORD_DIR}")$(guard_line)"
  slack_finish "$text"
}

# ⚠️ 要配置（登録は完了したがファイルの配置に失敗）— 手で移動するだけ
notify_needs_placement() {  # <ファイルの現在地>
  local where="$1" text
  text="$(printf '%s\n' \
    ":warning: *要配置*（$(mode_label)） — ${TITLE:-（タイトル不明）}" \
    "• Citation Key: \`${CITATION_KEY}\`" \
    "• Notion: ${NOTION_URL}（登録は完了）" \
    "• ファイル: 配置に失敗しました．現在地: ${where}" \
    "$(run_footer)" \
    "• ログ: ${RECORD_DIR}")$(guard_line)"
  slack_finish "$text"
}
