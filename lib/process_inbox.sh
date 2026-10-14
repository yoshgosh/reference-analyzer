#!/usr/bin/env bash
# inbox の1件を処理する
#
#   process_inbox.sh <inbox 内のPDFのパス>
#
# lib/scan_inbox.sh から1件ごとに別プロセスとして起動される．
# 別プロセスであることが run_id の一意性（末尾が $$）と枠の PID 追跡の前提になっている．
#
# 自動は「手動と同じ処理」の前後に移動を1回ずつ足したものである．
#
#   ① inbox → in_progress へ取り込む（mv の原子性が自動どうしの排他になる．ステップ fetch）
#   ② in_progress のファイルに対して手動と同じ処理を行う
#      （コピーだけを AI に見せ，最後にその場で改名する）
#   ③ in_progress → PAPER_ROOT へ出す
#
# 失敗したものは in_progress に残る．inbox へ戻すと次の変化で再処理され，
# 失敗を繰り返すか重複登録になる．再実行するときは inbox へ戻す．
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/lib/core.sh"

INBOX_PATH="${1:-}"
if [ -z "$INBOX_PATH" ]; then
  echo "使い方: process_inbox.sh <inbox 内のPDFのパス>" >&2
  exit 2
fi

load_env || exit 1

LOCK_PATH=""
cleanup_on_exit() {
  release_slot 2>/dev/null || true
  [ -n "$LOCK_PATH" ] && release_lock "$LOCK_PATH"
  # set -e の下では，終了時の処理の最後の終了コードが exit の値を上書きする
  return 0
}
trap cleanup_on_exit EXIT

ORIG_NAME="$(basename "$INBOX_PATH")"
RUN_MODE=auto
TARGET_KIND=file
TARGET_LABEL="$ORIG_NAME"
AUX_DESC=""
STEP_LIST="fetch analyze create rename move"
# 開始の通知より前に確定している必要がある（取り込みはそのあとで走る）
CURRENT_PATH="$INBOX_PATH"

# ① 取り込む．place_file は配置ロックの中で空き名を決めてから mv するので，
# 同名が既に in_progress にあれば _2 に逃がし，同じファイルを2プロセスが
# 取り合った場合は負けた側の mv が失敗する．
prepare_target() {
  local dest
  if ! dest="$(place_file "$INBOX_PATH" "$PAPER_IN_PROGRESS_DIR")"; then
    step_failed fetch
    ERROR_MESSAGE="inbox から取り込めなかった（他のプロセスが先に取ったか，ファイルが無くなった）"
    return 1
  fi
  TARGET_PATH="$dest"
  TARGET_LABEL="$(basename "$dest")"
  CURRENT_PATH="$dest"
  step_completed fetch

  # in_progress はパスが安定しているため，処理中のファイルに人が ref をかけうる．
  # 手動と同じ札を立てて，同じ資料への二重処理を防ぐ．
  LOCK_PATH="$(target_lock_path file "$TARGET_PATH")"
  if ! acquire_lock "$LOCK_PATH" 1; then
    LOCK_PATH=""
    ERROR_MESSAGE="この資料は既に処理中である"
    return 1
  fi
  # ここから先の失敗は inbox へ戻せばやり直せる（解析が済んでいれば ref --resume）
  REDO_COMMAND="mv $(shell_path "$TARGET_PATH") $(shell_path "$PAPER_INBOX_DIR")/"
  return 0
}

# ②の改名（手動と共有）に続けて，③ PAPER_ROOT へ出す．
# 改名できなかった場合も in_progress に残すだけで，どこへも動かさない．
place_result() {  # <解析と登録が成功なら1>
  rename_step "$1" || return 0
  move_step || true
  return 0
}

cleanup_old_records || true
run_one
