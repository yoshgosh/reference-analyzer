#!/usr/bin/env bash
# inbox の1件を処理する
#
#   process_inbox.sh <inbox 内のPDFのパス>
#
# lib/scan_inbox.sh から1件ごとに別プロセスとして起動される．
# 別プロセスであることが run_id の一意性（末尾が $$）と枠の PID 追跡の前提になっている．
#
# 手動経路との違いはこのファイルの prepare_target と place_result だけである．
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/lib/core.sh"

INBOX_PATH="${1:-}"
if [ -z "$INBOX_PATH" ]; then
  echo "使い方: process_inbox.sh <inbox 内のPDFのパス>" >&2
  exit 2
fi

load_env || exit 1

trap 'release_slot 2>/dev/null || true' EXIT

ORIG_NAME="$(basename "$INBOX_PATH")"
TARGET_KIND=file
TARGET_LABEL="$ORIG_NAME"
TARGET_DESC="$(printf '%s\n' \
  "- 種別: PDFファイル" \
  "- ファイル: ./$ORIG_NAME" \
  "" \
  "この1本のみを処理せよ．")"
AUX_DESC=""
WORK_PDF=""

# アトミックな mv で確保する．他のプロセスに先を越されていれば mv が失敗するので，
# 何もせず終了する（二重処理の防止）．
prepare_target() {
  WORK_PDF="$WORK_DIR/$ORIG_NAME"
  if ! mv "$INBOX_PATH" "$WORK_PDF" 2>/dev/null; then
    log_msg "確保できなかった（他のプロセスが処理中か，既に処理済み）"
    return 1
  fi
  log_msg "作業ディレクトリへ確保した: $ORIG_NAME"
  return 0
}

# 成功: 作業ディレクトリ内で改名してから PAPER_ROOT へ移動する（着地時に一意化される）
# 失敗: failed/ へ退避する．inbox に残すと次の変化で再処理され，失敗を繰り返す．
place_result() {  # <成功なら1>
  local ok="$1" renamed dest

  if [ "$ok" = "1" ]; then
    if renamed="$(rename_to_key "$WORK_PDF" "$CITATION_KEY")" \
       && dest="$(move_into "$renamed" "$PAPER_ROOT")"; then
      PLACEMENT="$(basename "$dest")"
      return 0
    fi
    # Notion 登録は済んでいる．inbox へ戻すと重複登録になるため failed/ へ退避する．
    dest="$(move_into "$WORK_PDF" "$PAPER_FAILED_DIR" "${RUN_ID}_${ORIG_NAME%.*}" || true)"
    ERROR_MESSAGE="Notion 登録は成功したが，${PAPER_ROOT} への配置に失敗した（現在地: ${dest:-$WORK_PDF}）"
    return 1
  fi

  move_into "$WORK_PDF" "$PAPER_FAILED_DIR" "${RUN_ID}_${ORIG_NAME%.*}" >/dev/null || true
  PLACEMENT=""
  return 0
}

cleanup_old_records || true
run_one
