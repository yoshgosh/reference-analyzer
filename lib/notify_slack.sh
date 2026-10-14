#!/usr/bin/env bash
# Slack 通知（Web API）
#
# 1資料につき1メッセージ．枠を取得した直後に「処理中」を投稿し，
# 終了時に chat.update で同じメッセージを書き換える．
#
# Incoming Webhook は使わない．応答が "ok" という文字列だけで，
# 書き換えに必要な ts を返さないためである（実測で確認済み）．
#
# メッセージは3種で，見出しがそのまま状態である．
#
#   🚀 Started     枠を取得して処理を始めた
#   ✅ Completed   全ステップが completed
#   🚨 Failed      completed でないステップがある
#
# 語彙は「作業単位のライフサイクルを過去分詞で言う」系統に揃えている．
# 見出しが開始と2つの終端，ステップ（lib/core.sh）が2つの終端と開始の否定を使う．
#
# warning: の行は見出しを変えない．どちらの見出しでも出る．
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
notify_start() {
  local resp text line

  if ! slack_enabled; then
    log_msg "Slack: SLACK_BOT_TOKEN または SLACK_CHANNEL が未設定のため通知しない"
    return 0
  fi

  text=":rocket: Started: $(subject)"
  line="$(with_line)"; [ -n "$line" ] && text="${text}
${line}"
  text="${text}
$(run_meta)"

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

# 実行の属性（全メッセージ共通の最終行）
run_meta() {  # [経過時間を出すなら 1]
  printf 'run_id: `%s`, trigger: %s, model: %s / %s / %s' \
    "$RUN_ID" "${RUN_MODE:-unknown}" "$PAPER_ENGINE" "$PAPER_MODEL" "$PAPER_EFFORT"
  [ "${1:-}" = "1" ] && printf ', duration: %ssec' "$(elapsed)"
  return 0
}

# ホーム配下のパスを ~ で短くする．文中に現れるものも含めて置き換える．
tilde() {  # <文字列>
  printf '%s' "${1//$HOME/~}"
}

# 見出しの資料名．
# タイトルが取れるまでは対象そのもの（いまのパス または URL）を出す．
# Notion ページがあればリンクにする．
subject() {
  local name
  if [ -n "${TITLE:-}" ]; then
    name="$TITLE"
  elif [ "$TARGET_KIND" = url ]; then
    name="$TARGET"
  else
    name="$(tilde "${CURRENT_PATH:-$TARGET_LABEL}")"
  fi
  if [ -n "${NOTION_URL:-}" ]; then
    printf '<%s|%s>' "$NOTION_URL" "$name"
  else
    printf '%s' "$name"
  fi
}

# 対象の行．いまファイルがある場所（または対象のURL）を示す．
# タイトルが無いときは見出しが同じ内容になるので出さない．
target_line() {
  [ -z "${TITLE:-}" ] && return 0
  if [ "$TARGET_KIND" = url ]; then
    printf 'url: `%s`' "$TARGET"
  elif [ -n "${CURRENT_PATH:-}" ]; then
    printf 'file: `%s`' "$(tilde "$CURRENT_PATH")"
  fi
  return 0
}

# 補助資料の行（手動のみ）．AUX_SUMMARY は bin/ref が組み立てる．
with_line() {
  [ -n "${AUX_SUMMARY:-}" ] && printf 'with: %s' "$AUX_SUMMARY"
  return 0
}

# ステップの行（🚨 Failed のみ）．
# 番号は経路ごとの並び順である（手動は ① から始まり，fetch file と move file を持たない）．
step_no() {  # <1 から始まる序数>
  case "$1" in
    1) printf '①' ;; 2) printf '②' ;; 3) printf '③' ;;
    4) printf '④' ;; 5) printf '⑤' ;; *) printf '%s.' "$1" ;;
  esac
}

step_label() {  # <ステップ名>
  case "$1" in
    fetch)  printf 'fetch file' ;;
    analyze) printf 'analyze source' ;;
    create)  printf 'create page' ;;
    rename) printf 'rename file' ;;
    move)   printf 'move file' ;;
    *)        printf '%s' "$1" ;;
  esac
}

step_lines() {
  local s out="" n=0
  for s in $STEP_LIST; do
    n=$((n + 1))
    out="${out}${out:+
}$(step_no "$n") $(step_label "$s"): $(step_state "$s")"
  done
  printf '%s' "$out"
}

# 結果の通知（開始通知を書き換える）
#
#   ✅ Completed   全ステップ completed
#   🚨 Failed      completed でないステップがある
#
# Completed はステップを出さない（全部 completed と分かっているため）．
# 混入ガードの警告は見出しにせず warning: の行で示す（どちらの見出しでも出る）．
notify_result() {
  local body line

  if steps_all_completed; then
    body=":white_check_mark: Completed: $(subject)"
  else
    body=":rotating_light: Failed: $(subject)
$(step_lines)"
    [ -n "${ERROR_MESSAGE:-}" ] && body="${body}
error: $(tilde "$ERROR_MESSAGE")"
    [ -n "${RETRY_HINT:-}" ] && body="${body}
retry: \`${RETRY_HINT}\`"
  fi

  [ -n "${GUARD_WARNING:-}" ] && body="${body}
warning: $(tilde "$GUARD_WARNING")"
  [ -n "${CITATION_KEY:-}" ] && body="${body}
citation_key: \`${CITATION_KEY}\`"
  line="$(target_line)"; [ -n "$line" ] && body="${body}
${line}"
  line="$(with_line)"; [ -n "$line" ] && body="${body}
${line}"
  # AI を動かしていない実行（ref --register，AI の起動前の失敗）では出ない
  [ -n "${USAGE_SUMMARY:-}" ] && body="${body}
usage: ${USAGE_SUMMARY}"
  body="${body}
$(run_meta 1)"

  slack_finish "$body"
  return 0
}
