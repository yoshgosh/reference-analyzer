#!/usr/bin/env bash
# 自動経路（inbox）：資料1本の処理
#
#   auto_one.sh <inbox 内のPDFのパス>
#
# 確定事項 : inbox から取り出し，成功すれば PAPER_ROOT 直下へ改名して移動，
#            失敗すれば failed/ へ移す．inbox にファイルを残さない
#            （残すと inbox の次の変化で再処理され，失敗を繰り返す）．
#
# 手動経路（manual_one.sh）との違いはこのファイルに閉じている．
# 共有部分は lib/core.sh にあり，対象の確保と最終的な配置のみを本ファイルが行う．
set -euo pipefail

RA_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$RA_REPO_ROOT/lib/core.sh"

RA_TARGET="${1:-}"
if [ -z "$RA_TARGET" ]; then
  echo "使い方: auto_one.sh <inbox 内のPDFのパス>" >&2
  exit 2
fi

ra_load_env || exit 1

RA_MODE=auto
ORIG_BASE="$(basename "$RA_TARGET")"

# 異常終了しても同時実行の枠を残さない（残っても PID 検査で回収されるが，即時に返す）
trap 'ra_slot_release 2>/dev/null || true' EXIT

ra_begin_run
ra_log "mode=auto target=$RA_TARGET"

# ---- 対象の確保 ----------------------------------------------------------
# アトミックな mv で確保する．他のプロセスに先を越されていれば mv が失敗するので，
# 何もせず正常終了する（二重処理の防止．§8.2）．
WORK_PDF="$RA_WORK_DIR/$ORIG_BASE"
if ! mv "$RA_TARGET" "$WORK_PDF" 2>/dev/null; then
  ra_log "確保できなかった（他のプロセスが処理中か，既に処理済み）．何もせず終了する"
  rm -rf "$RA_WORK_DIR"
  rm -rf "$RA_RECORD_DIR"
  exit 0
fi
ra_log "作業ディレクトリへ確保した: $ORIG_BASE"

# 失敗時に inbox へ戻さず failed/ へ退避する
move_to_failed() {
  local dest
  mkdir -p "$PAPER_FAILED_DIR"
  dest="$(ra_unique_path "$PAPER_FAILED_DIR" "${RA_RUN_ID}_${ORIG_BASE%.*}" ".${ORIG_BASE##*.}")"
  if mv "$WORK_PDF" "$dest" 2>/dev/null; then
    ra_log "failed/ へ移した: $(basename "$dest")"
    printf '%s' "$dest"
  else
    ra_log "警告: failed/ への移動に失敗した．作業ディレクトリに残す: $WORK_PDF"
    printf '%s' "$WORK_PDF"
  fi
}

# ---- 処理 ----------------------------------------------------------------
TARGET_DESC="$(printf '%s\n' \
  "- 種別: PDFファイル" \
  "- ファイル: ./$ORIG_BASE" \
  "" \
  "この1本のみを処理せよ．作業ディレクトリ内の他のファイルは対象ではない．")"

if ra_process "$TARGET_DESC"; then
  # 成功 : PAPER_ROOT 直下へ改名して移動する
  RENAME_LOCK="$PAPER_WORK_DIR/.locks/rename.lock"
  mkdir -p "$PAPER_WORK_DIR/.locks"
  ra_lock_acquire "$RENAME_LOCK" 150 || ra_log "警告: 改名ロックを取得できなかった．そのまま続行する"
  DEST="$(ra_unique_path "$PAPER_ROOT" "$RA_CITATION_KEY" ".pdf")"
  if mv "$WORK_PDF" "$DEST" 2>/dev/null; then
    ra_lock_release "$RENAME_LOCK"
    ra_log "配置した: $ORIG_BASE -> $(basename "$DEST")"
    ra_save_records
    ra_notify_success "$(basename "$DEST")"
    ra_cleanup_work_dir
    exit 0
  fi
  ra_lock_release "$RENAME_LOCK"

  # Notion 登録は済んでいるが配置に失敗した場合．
  # inbox に戻すと再処理で重複登録になるため failed/ へ退避し，Notion URL を通知に残す．
  FAILED_AT="$(move_to_failed)"
  RA_ERROR="Notion 登録は成功したが，$PAPER_ROOT への配置に失敗した（現在地: ${FAILED_AT}）"
  ra_log "$RA_ERROR"
  ra_save_records
  ra_notify_failure "$ORIG_BASE"
  exit 1
fi

# ---- 失敗 ----------------------------------------------------------------
ra_log "失敗: $RA_ERROR"
move_to_failed >/dev/null
ra_save_records
ra_notify_failure "$ORIG_BASE"
exit 1
