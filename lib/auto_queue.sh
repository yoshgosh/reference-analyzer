#!/usr/bin/env bash
# 自動経路の入口：inbox を走査し，資料を並列で配る
#
#   auto_queue.sh
#
# launchd（WatchPaths）から起動される．発火が重なってもよい．
# 同じPDFの二重処理は auto_one.sh のアトミックな mv で防ぐ（§8.2）．
#
# macOS 標準の bash 3.2 で動くように書いている．
set -euo pipefail

RA_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$RA_REPO_ROOT/lib/core.sh"
. "$RA_REPO_ROOT/lib/cleanup.sh"

ra_load_env || exit 1
ra_cleanup_old_records || true

# 書き込み完了を判定する待ち時間（秒）．§8.1
RA_SETTLE_SECONDS="${PAPER_SETTLE_SECONDS:-2}"
# 処理中に追加された分を拾うための再走査の上限
RA_MAX_ROUNDS="${PAPER_MAX_ROUNDS:-20}"

log() { printf '%s  auto_queue: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# 取り込み対象かを判定する．
# 拡張子 .pdf のみ（大文字小文字を区別しない）．隠しファイル，iCloud のプレースホルダー，
# ダウンロード途中のファイルは除く．
is_eligible() {  # <パス>
  local base; base="$(basename "$1")"
  case "$base" in
    .*) return 1 ;;
    *.icloud|*.crdownload|*.download|*.part|*.partial|*.tmp) return 1 ;;
  esac
  case "$(printf '%s' "$base" | tr 'A-Z' 'a-z')" in
    *.pdf) ;;
    *) return 1 ;;
  esac
  [ -f "$1" ] || return 1
  return 0
}

file_size() { stat -f '%z' "$1" 2>/dev/null || echo "-1"; }

# inbox 内の，書き込みが完了した候補を NUL 区切りで出力する．
# サイズが RA_SETTLE_SECONDS 秒変化しないことを確認する．
collect_settled() {
  local snapshot f sz
  snapshot=""
  while IFS= read -r -d '' f; do
    is_eligible "$f" || continue
    snapshot="$snapshot$f=$(file_size "$f")"$'\n'
  done < <(find "$PAPER_INBOX_DIR" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null | sort -z)

  [ -z "$snapshot" ] && return 0

  sleep "$RA_SETTLE_SECONDS"

  printf '%s' "$snapshot" | while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    f="${entry%=*}"
    sz="${entry##*=}"
    [ -f "$f" ] || continue
    if [ "$(file_size "$f")" = "$sz" ]; then
      printf '%s\0' "$f"
    else
      log "書き込み中のため見送る: $(basename "$f")"
    fi
  done
}

running_count() { jobs -pr 2>/dev/null | wc -l | tr -d ' '; }

round=0
total=0
while [ "$round" -lt "$RA_MAX_ROUNDS" ]; do
  round=$((round + 1))

  candidates=""
  while IFS= read -r -d '' f; do
    candidates="$candidates$f"$'\n'
  done < <(collect_settled)

  if [ -z "$candidates" ]; then
    if [ "$round" -eq 1 ]; then
      # 無人で動くため，「対象なし」の理由を区別できるようにしておく
      if [ ! -d "$PAPER_INBOX_DIR" ]; then
        log "対象なし（inbox が存在しない: ${PAPER_INBOX_DIR}）"
      else
        log "対象なし（inbox=$PAPER_INBOX_DIR 全 $(find "$PAPER_INBOX_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') ファイル）"
      fi
    fi
    break
  fi

  n=0
  pids=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    while [ "$(running_count)" -ge "$PAPER_PARALLEL" ]; do
      sleep 0.3
    done
    log "投入: $(basename "$f")"
    "$RA_REPO_ROOT/lib/auto_one.sh" "$f" &
    pids="$pids $!"
    n=$((n + 1))
  done <<EOF
$candidates
EOF

  for pid in $pids; do
    wait "$pid" || true
  done
  total=$((total + n))
  log "第${round}巡: ${n} 件を処理した"
done

if [ "$round" -ge "$RA_MAX_ROUNDS" ]; then
  log "警告: 再走査の上限（$RA_MAX_ROUNDS 巡）に達した．inbox を確認せよ"
fi
[ "$total" -gt 0 ] && log "合計 ${total} 件を処理した"
exit 0
