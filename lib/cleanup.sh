#!/usr/bin/env bash
# 保存期間を過ぎた実行記録・作業ディレクトリを削除する．
#
# 削除する   : PAPER_LOG_DIR 配下，PAPER_WORK_DIR 配下の run_id ディレクトリ
# 削除しない : in_progress/ のPDF（未完了のまま残す．再実行の対象である）
#              先頭がドットのディレクトリ（.locks 等．保持中のロックを壊さないため）

cleanup_old_records() {
  local days="${PAPER_LOG_RETENTION_DAYS:-7}" d victim

  case "$days" in
    ''|*[!0-9]*) echo "cleanup: PAPER_LOG_RETENTION_DAYS が不正である: $days" >&2; return 1 ;;
  esac

  for d in "$PAPER_LOG_DIR" "$PAPER_WORK_DIR"; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -mtime "+$days" -print0 2>/dev/null |
      while IFS= read -r -d '' victim; do
        rm -rf "$victim" && echo "cleanup: 削除した $victim" >&2
      done
  done
  return 0
}
