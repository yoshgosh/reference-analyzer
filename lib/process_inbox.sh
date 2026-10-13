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
#   ① inbox → in_progress へ確保する（mv の原子性が自動どうしの排他になる）
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
}
trap cleanup_on_exit EXIT

ORIG_NAME="$(basename "$INBOX_PATH")"
RUN_MODE=auto
TARGET_KIND=file
TARGET_LABEL="$ORIG_NAME"
AUX_DESC=""
STEP_LIST="page complete rename move"

# ① 確保する．move_into は配置ロックの中で空き名を決めてから mv するので，
# 同名が既に in_progress にあれば _2 に逃がし，同じファイルを2プロセスが
# 取り合った場合は負けた側の mv が失敗する．
prepare_target() {
  local dest
  if ! dest="$(move_into "$INBOX_PATH" "$PAPER_IN_PROGRESS_DIR")"; then
    log_msg "確保できなかった（他のプロセスが処理中か，既に処理済み）"
    return 1
  fi
  TARGET_PATH="$dest"
  TARGET_LABEL="$(basename "$dest")"

  # in_progress はパスが安定しているため，処理中のファイルに人が ref をかけうる．
  # 手動と同じ札を立てて，同じ資料への二重処理を防ぐ．
  LOCK_PATH="$(target_lock_path file "$TARGET_PATH")"
  if ! acquire_lock "$LOCK_PATH" 1; then
    log_msg "この資料は既に処理中である: $TARGET_LABEL"
    LOCK_PATH=""
    return 1
  fi

  TARGET_DESC="$(printf '%s\n' \
    "- 種別: PDFファイル" \
    "- ファイル: ./$TARGET_LABEL" \
    "- このファイルは作業ディレクトリ内のコピーである．" \
    "" \
    "この1本のみを処理せよ．")"

  # ② 以降は手動と同じ．コピーだけを AI に見せ，原本には触れさせない．
  cp "$TARGET_PATH" "$WORK_DIR/$TARGET_LABEL" || return 1
  log_msg "作業ディレクトリへコピーした: $TARGET_LABEL"
  return 0
}

# ②の改名（手動と共有）に続けて，③ PAPER_ROOT へ出す．
# 改名できなかった場合も in_progress に残すだけで，どこへも動かさない．
place_result() {  # <解析が成功なら1>
  local dest
  place_in_place "$1" || return 0

  if dest="$(move_into "$RENAMED_PATH" "$PAPER_ROOT")"; then
    step_ok move
    PLACEMENT="${ORIG_NAME} → $(basename "$dest")"
    return 0
  fi
  PLACEMENT="${RENAMED_PATH} → ${PAPER_ROOT}/ へ移してください"
  ERROR_MESSAGE="${PAPER_ROOT} への移動に失敗した"
  return 0
}

cleanup_old_records || true
run_one
