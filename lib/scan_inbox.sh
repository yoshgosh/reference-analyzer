#!/usr/bin/env bash
# inbox を走査し，1件ごとにワーカー（lib/process_inbox.sh）を起動する
#
# launchd（WatchPaths）から起動される．
#
# launchd が通知するのは「inbox の中身が変化した」ことだけで，どのファイルかは渡ってこない．
# そのため改めて走査し，見つかった全件を処理する．1回の検知で複数件になりうる．
# launchd は同じジョブを二重に起動しないが，実行中に起きた変化は終了後に再実行される．
#
# 同時実行数の制御はここでは行わない．ワーカーが共有の枠を取るため，
# 何件起動しても実際に処理されるのは PAPER_PARALLEL 件までである．
#
# macOS 標準の bash 3.2 で動くように書いている．
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/lib/core.sh"

load_env || exit 1
cleanup_old_records || true

say() { printf '%s  scan_inbox: %s\n' "$(now)" "$*" >&2; }

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

# 書き込みが完了した候補を NUL 区切りで出力する．
# サイズが PAPER_SETTLE_SECONDS 秒変化しないことを確認する．
collect_settled() {
  local snapshot f sz
  snapshot=""
  while IFS= read -r -d '' f; do
    is_eligible "$f" || continue
    snapshot="$snapshot$f=$(file_size "$f")"$'\n'
  done < <(find "$PAPER_INBOX_DIR" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null | sort -z)

  [ -z "$snapshot" ] && return 0

  sleep "$PAPER_SETTLE_SECONDS"

  printf '%s' "$snapshot" | while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    f="${entry%=*}"
    sz="${entry##*=}"
    [ -f "$f" ] || continue
    if [ "$(file_size "$f")" = "$sz" ]; then
      printf '%s\0' "$f"
    else
      say "書き込み中のため見送る: $(basename "$f")"
    fi
  done
}

round=0
total=0
while [ "$round" -lt "$PAPER_MAX_ROUNDS" ]; do
  round=$((round + 1))

  candidates=""
  while IFS= read -r -d '' f; do
    candidates="$candidates$f"$'\n'
  done < <(collect_settled)

  if [ -z "$candidates" ]; then
    if [ "$round" -eq 1 ]; then
      # 無人で動くため「対象なし」の理由を区別できるようにしておく．
      # TCC で列挙できない場合もここを通り，ファイル数が 0 と出る．
      if [ ! -d "$PAPER_INBOX_DIR" ]; then
        say "対象なし（inbox が存在しない: ${PAPER_INBOX_DIR}）"
      else
        say "対象なし（inbox=$PAPER_INBOX_DIR 全 $(find "$PAPER_INBOX_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') ファイル）"
      fi
    fi
    break
  fi

  n=0
  pids=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    say "投入: $(basename "$f")"
    "$REPO_ROOT/lib/process_inbox.sh" "$f" &
    pids="$pids $!"
    n=$((n + 1))
  done <<EOF
$candidates
EOF

  for pid in $pids; do
    wait "$pid" || true
  done
  total=$((total + n))
  say "第${round}巡: ${n} 件を処理した"
done

if [ "$round" -ge "$PAPER_MAX_ROUNDS" ]; then
  say "警告: 再走査の上限（${PAPER_MAX_ROUNDS} 巡）に達した．inbox を確認せよ"
fi
[ "$total" -gt 0 ] && say "合計 ${total} 件を処理した"
exit 0
