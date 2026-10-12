#!/usr/bin/env bash
# 土台：環境・ログ・ロック・同時実行の枠・混入ガード・小道具
#
# すべての入口（bin/ref, lib/scan_inbox.sh, lib/process_inbox.sh）がこれを source する．
# このファイルはファイルの改名・移動を行わない（lib/place.sh の責務）．

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------- 環境

load_env() {
  if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
  fi

  # TCC（macOS のプライバシー保護）のため ~/Documents 配下には置かない．
  # launchd から起動したスクリプトは ~/Documents の列挙・読取ができず，
  # しかもエラーを出さず「対象なし」として終わる（実測で確認済み）．
  PAPER_ROOT="${PAPER_ROOT:-$HOME/Research/Papers}"
  PAPER_INBOX_DIR="${PAPER_INBOX_DIR:-$PAPER_ROOT/inbox}"
  PAPER_FAILED_DIR="${PAPER_FAILED_DIR:-$PAPER_ROOT/failed}"
  PAPER_WORK_DIR="${PAPER_WORK_DIR:-$PAPER_ROOT/.work}"
  PAPER_LOG_DIR="${PAPER_LOG_DIR:-$PAPER_ROOT/.logs}"
  PAPER_ENGINE="${PAPER_ENGINE:-claude}"
  # モデルと effort は明示的に固定する．--restricted は user/project/local の
  # 設定ファイルを無視するため，指定しないと CLI の既定に依存し，更新で静かに変わる．
  PAPER_MODEL="${PAPER_MODEL:-opus}"
  PAPER_EFFORT="${PAPER_EFFORT:-medium}"
  PAPER_PARALLEL="${PAPER_PARALLEL:-2}"
  PAPER_LOG_RETENTION_DAYS="${PAPER_LOG_RETENTION_DAYS:-7}"
  PAPER_SETTLE_SECONDS="${PAPER_SETTLE_SECONDS:-2}"
  PAPER_MAX_ROUNDS="${PAPER_MAX_ROUNDS:-20}"
  # 補助資料の総量の上限．超えたら AI を起動せず中止する．
  PAPER_AUX_MAX_BYTES="${PAPER_AUX_MAX_BYTES:-52428800}"   # 50MB
  PAPER_AUX_MAX_FILES="${PAPER_AUX_MAX_FILES:-100}"

  if [ -z "${NOTION_DATA_SOURCE_ID:-}" ]; then
    echo "reference-analyzer: NOTION_DATA_SOURCE_ID が未設定である（.env を確認せよ）" >&2
    return 1
  fi

  local engine_lib="$REPO_ROOT/lib/engine_${PAPER_ENGINE}.sh"
  case "$PAPER_ENGINE" in
    claude|codex) ;;
    *) echo "reference-analyzer: PAPER_ENGINE が不正である: ${PAPER_ENGINE}（claude または codex）" >&2; return 1 ;;
  esac
  if [ ! -f "$engine_lib" ]; then
    echo "reference-analyzer: エンジン $PAPER_ENGINE は未実装である（$engine_lib が無い）" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  . "$engine_lib"
  . "$REPO_ROOT/lib/analyze.sh"
  . "$REPO_ROOT/lib/place.sh"
  . "$REPO_ROOT/lib/notify_slack.sh"
  . "$REPO_ROOT/lib/cleanup.sh"
  . "$REPO_ROOT/lib/run_one.sh"

  mkdir -p "$PAPER_WORK_DIR" "$PAPER_LOG_DIR"
}

# ---------------------------------------------------------------- 小道具

# python3 -I : カレントディレクトリと環境変数を無視する．
# 作業ディレクトリに AI が json.py 等を作っても import が乗っ取られない．
py() { python3 -I "$@"; }

now() { date '+%Y-%m-%d %H:%M:%S'; }

# log という名の実コマンド（/usr/bin/log）を隠さないよう log_msg にしている
log_msg() {
  local msg="$*"
  [ -n "${RUN_LOG:-}" ] && printf '%s  %s\n' "$(now)" "$msg" >>"$RUN_LOG"
  printf '%s\n' "$msg" >&2
}

json_get() {  # <ファイル> <キー>
  py -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2], "")
sys.stdout.write("" if v is None else str(v))
' "$1" "$2"
}

elapsed() {
  local n; n="$(date '+%s')"
  printf '%s' "$((n - STARTED_AT))"
}

# ---------------------------------------------------------------- Citation Key

# ASCII 英数字・. _ - のみを残す．
# 先に NFKD 分解して結合文字を落とすため，Müller は Muller になる（Mller にはならない）．
normalize_key() {
  printf '%s' "$1" | py -c '
import sys, unicodedata
s = unicodedata.normalize("NFKD", sys.stdin.read())
s = "".join(c for c in s if not unicodedata.combining(c))
sys.stdout.write("".join(c for c in s if c.isascii() and (c.isalnum() or c in "._-")))
'
}

# 非ASCII の著者名がローマ字化されずに落ちると数字だけのキーが残るため，英字を必須とする
key_is_sane() {  # <正規化済みキー>
  local k="$1"
  [ -n "$k" ] || return 1
  [ "${#k}" -ge 3 ] || return 1
  printf '%s' "$k" | LC_ALL=C grep -q '[A-Za-z]' || return 1
  return 0
}

# ---------------------------------------------------------------- ロック

locks_dir() { printf '%s' "$PAPER_WORK_DIR/.locks"; }

# mkdir のアトミック性による排他
acquire_lock() {  # <ロックのパス> [試行回数（0.2秒間隔．既定150＝30秒）]
  local d="$1" tries="${2:-150}" i=0
  mkdir -p "$(dirname "$d")"
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge "$tries" ] && return 1
    sleep 0.2
  done
  return 0
}

release_lock() { rmdir "$1" 2>/dev/null || true; }

# 資料ごとのロックのパス（実パスを鍵にする）
target_lock_path() {  # <種別> <対象>
  local key; key="$(printf '%s' "$2" | shasum -a 256 | cut -c1-16)"
  printf '%s/%s-%s.lock' "$(locks_dir)" "$1" "$key"
}

# ---------------------------------------------------------------- 同時実行の枠

# システム全体で同時に処理する資料を PAPER_PARALLEL 件に抑える．
#
# 枠は「1資源を処理する許可」である．取得してから対象を確保するので，
# 待っているプロセスはファイルを掴まない．
# 枠の状態はディスク上にあるため，起動経路（手動・自動）やプロセス数に関わらず
# 合計が効く．これが唯一の同時実行の制御点である．

SLOT_DIR=""

reclaim_stale_slots() {  # <枠の親ディレクトリ>
  local base="$1" d pid
  for d in "$base"/slot-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/pid" ]; then
      pid="$(cat "$d/pid" 2>/dev/null)"
      # 生きているプロセスが使用中の枠は触らない
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        continue
      fi
      rm -rf "$d" && log_msg "枠を回収した（プロセス ${pid:-不明} は終了済み）: $(basename "$d")"
    else
      # PID 書き込み前の枠を奪わないよう，1分以上古いものだけ回収する
      if [ -z "$(find "$d" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
        rm -rf "$d" && log_msg "枠を回収した（PID 不明・1分以上経過）: $(basename "$d")"
      fi
    fi
  done
}

acquire_slot() {  # [最大待機秒数（既定3600）]
  local limit="${1:-3600}" base n waited=0
  base="$(locks_dir)/slots"
  mkdir -p "$base"
  while :; do
    n=1
    while [ "$n" -le "$PAPER_PARALLEL" ]; do
      if mkdir "$base/slot-$n" 2>/dev/null; then
        printf '%s' "$$" >"$base/slot-$n/pid"
        SLOT_DIR="$base/slot-$n"
        log_msg "同時実行の枠を取得した: slot-${n}（全 ${PAPER_PARALLEL} 枠）"
        return 0
      fi
      n=$((n + 1))
    done
    reclaim_stale_slots "$base"
    if [ "$waited" -ge "$limit" ]; then
      log_msg "警告: ${limit} 秒待っても枠が空かなかった．枠なしで続行する"
      SLOT_DIR=""
      return 1
    fi
    [ "$waited" = "0" ] && log_msg "全 ${PAPER_PARALLEL} 枠が使用中．空くまで待つ"
    sleep 1
    waited=$((waited + 1))
  done
}

release_slot() {
  [ -n "${SLOT_DIR:-}" ] || return 0
  local name; name="$(basename "$SLOT_DIR")"
  rm -rf "$SLOT_DIR"
  SLOT_DIR=""
  log_msg "同時実行の枠を解放した: ${name}"
}

# ---------------------------------------------------------------- 混入ガード

# 作業ディレクトリの祖先に CLAUDE.md があれば，そのパスを列挙する．
# あると開発用などの無関係な指示が論文処理に混入するおそれがある．
# プロセスを分けても自動読込は防げないため，ここで検知して通知する．
find_ancestor_claude_md() {  # <ディレクトリ>
  local d="$1" found="" f
  d="$(cd "$d" 2>/dev/null && pwd)" || return 0
  while :; do
    for f in CLAUDE.md CLAUDE.local.md; do
      [ -f "$d/$f" ] && found="$found$d/$f "
    done
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  printf '%s' "${found% }"
}

# ---------------------------------------------------------------- 実行の開始

new_run_id() {
  # 末尾は $$．サブシェルでは $$ が親のままなので，並列の各本は
  # 別プロセス（lib/process_inbox.sh）として起動する必要がある．
  printf '%s-%s' "$(date '+%Y%m%d-%H%M%S')" "$$"
}

begin_run() {  # <mode の表示名>
  RUN_ID="$(new_run_id)"
  WORK_DIR="$PAPER_WORK_DIR/$RUN_ID"
  RECORD_DIR="$PAPER_LOG_DIR/$RUN_ID"
  mkdir -p "$WORK_DIR" "$RECORD_DIR"
  RUN_LOG="$RECORD_DIR/run.log"
  : >"$RUN_LOG"
  STARTED_AT="$(date '+%s')"

  log_msg "run_id=$RUN_ID engine=$PAPER_ENGINE model=$PAPER_MODEL effort=$PAPER_EFFORT mode=${1:-unknown}"
  log_msg "work_dir=$WORK_DIR"

  local stray
  stray="$(find_ancestor_claude_md "$WORK_DIR")"
  if [ -n "$stray" ]; then
    log_msg "警告: 作業ディレクトリの祖先に CLAUDE.md がある（混入のおそれ）: $stray"
    GUARD_WARNING="祖先に CLAUDE.md: $stray"
  else
    GUARD_WARNING=""
  fi
}

discard_run_dirs() {
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  [ -n "${RECORD_DIR:-}" ] && [ -d "$RECORD_DIR" ] && rm -rf "$RECORD_DIR"
  return 0
}

cleanup_work_dir() {  # 成功時のみ呼ぶ
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  return 0
}
