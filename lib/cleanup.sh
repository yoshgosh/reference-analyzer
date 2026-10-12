#!/usr/bin/env bash
# 保存期間を過ぎた実行記録・作業ディレクトリを削除する．
#
# - 削除対象 : PAPER_LOG_DIR 配下，PAPER_WORK_DIR 配下
# - 削除しない : failed/ の PDF 自体（調査・手動処理のため残す）
# - 処理の開始時に呼ばれる．失敗しても処理全体は止めない．
set -u

RA_REPO_ROOT="${RA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"

ra_cleanup_old_records() {
  local days="${PAPER_LOG_RETENTION_DAYS:-7}" d

  case "$days" in
    ''|*[!0-9]*) echo "cleanup: PAPER_LOG_RETENTION_DAYS が不正である: $days" >&2; return 1 ;;
  esac

  for d in "$PAPER_LOG_DIR" "$PAPER_WORK_DIR"; do
    [ -d "$d" ] || continue
    # 直下の実行ディレクトリ（run_id 単位）のみを対象とする．
    # 先頭がドットのディレクトリ（.locks 等）は除く．ロック保持中に消すと排他が壊れる．
    find "$d" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -mtime "+$days" -print0 2>/dev/null |
      while IFS= read -r -d '' victim; do
        rm -rf "$victim" && echo "cleanup: 削除した $victim" >&2
      done
  done
  return 0
}

# 直接実行された場合（launchd や cron から単体で呼ぶ用）
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  . "$RA_REPO_ROOT/lib/core.sh"
  ra_load_env || exit 1
  ra_cleanup_old_records
fi
