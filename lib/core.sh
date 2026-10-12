#!/usr/bin/env bash
# reference-analyzer 共有ライブラリ
#
# auto_one.sh（自動／inbox 経路）と manual_one.sh（手動経路）の両方から source する。
# 共有部分の実装はこのファイルにのみ置く（複製してはならない）。
#
# 責務 : 環境読み込み・混入ガード・プロンプト組立・AI起動・出力検証・実行記録
# 禁止 : 作業ディレクトリ外のファイルの移動・改名・削除
#        （対象ファイルの確保と最終的な配置は呼び出し側の責務）

RA_REPO_ROOT="${RA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------- 環境

ra_load_env() {
  if [ -f "$RA_REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$RA_REPO_ROOT/.env"
    set +a
  fi

  # TCC（macOS のプライバシー保護）のため ~/Documents 配下には置かない．
  # launchd から起動したスクリプトは ~/Documents の列挙・読取ができず，inbox を走査できない
  # （書き込みのみ可という非対称な制約．実測で確認済み）．
  PAPER_ROOT="${PAPER_ROOT:-$HOME/Research/Papers}"
  PAPER_INBOX_DIR="${PAPER_INBOX_DIR:-$PAPER_ROOT/inbox}"
  PAPER_FAILED_DIR="${PAPER_FAILED_DIR:-$PAPER_ROOT/failed}"
  PAPER_WORK_DIR="${PAPER_WORK_DIR:-$PAPER_ROOT/.work}"
  PAPER_LOG_DIR="${PAPER_LOG_DIR:-$PAPER_ROOT/.logs}"
  PAPER_ENGINE="${PAPER_ENGINE:-claude}"
  # モデルと effort は明示的に固定する．CLI の既定に任せると，更新で静かに変わる．
  PAPER_MODEL="${PAPER_MODEL:-opus}"
  PAPER_EFFORT="${PAPER_EFFORT:-medium}"
  PAPER_PARALLEL="${PAPER_PARALLEL:-2}"
  PAPER_LOG_RETENTION_DAYS="${PAPER_LOG_RETENTION_DAYS:-7}"

  if [ -z "${NOTION_DATA_SOURCE_ID:-}" ]; then
    echo "reference-analyzer: NOTION_DATA_SOURCE_ID が未設定である（.env を確認せよ）" >&2
    return 1
  fi

  local engine_lib="$RA_REPO_ROOT/lib/engine_${PAPER_ENGINE}.sh"
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

  . "$RA_REPO_ROOT/lib/notify_slack.sh"

  mkdir -p "$PAPER_WORK_DIR" "$PAPER_LOG_DIR"
}

# ---------------------------------------------------------------- 小道具

ra_py() { python3 -I "$@"; }   # -I : カレントディレクトリと環境変数を無視（作業ディレクトリ内の同名モジュール混入を防ぐ）

ra_now() { date '+%Y-%m-%d %H:%M:%S'; }

ra_log() {
  local msg="$*"
  printf '%s  %s\n' "$(ra_now)" "$msg" >>"$RA_RUN_LOG"
  printf '%s\n' "$msg" >&2
}

ra_json_get() {  # <file> <key>
  ra_py -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2], "")
sys.stdout.write("" if v is None else str(v))
' "$1" "$2"
}

# ASCII 英数字・. _ - のみを残す．
# 先に NFKD 分解して結合文字を落とすため，Müller は Muller になる（Mller にはならない）．
ra_normalize_key() {
  printf '%s' "$1" | ra_py -c '
import sys, unicodedata
s = unicodedata.normalize("NFKD", sys.stdin.read())
s = "".join(c for c in s if not unicodedata.combining(c))
sys.stdout.write("".join(c for c in s if c.isascii() and (c.isalnum() or c in "._-")))
'
}

# 正規化後の Citation Key が使い物になるか検査する．
# 非ASCII の著者名がローマ字化されずに落ちると数字だけのキーが残るため，英字を必須とする．
ra_key_is_sane() {  # <正規化済みキー>
  local k="$1"
  [ -n "$k" ] || return 1
  [ "${#k}" -ge 3 ] || return 1
  printf '%s' "$k" | LC_ALL=C grep -q '[A-Za-z]' || return 1
  return 0
}


# 空いているパスを返す（同名があれば _2, _3 …）
ra_unique_path() {  # <dir> <base> <ext>
  local dir="$1" base="$2" ext="$3" n=2 cand
  cand="$dir/$base$ext"
  while [ -e "$cand" ]; do
    cand="$dir/${base}_${n}${ext}"
    n=$((n + 1))
  done
  printf '%s' "$cand"
}

# mkdir によるアトミックなロック
ra_lock_acquire() {  # <lockdir> [待機する最大の 0.2 秒単位数（既定 150 = 30秒）]
  local d="$1" tries="${2:-150}" i=0
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge "$tries" ] && return 1
    sleep 0.2
  done
  return 0
}

ra_lock_release() { rmdir "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- 同時実行数の制御

# システム全体で同時に走る AI プロセスを PAPER_PARALLEL 個に抑える．
#
# キューの数を1つに制限するのではなく，枠（slot）の総数を抑える方式である．
# launchd は同じジョブを二重に起動しないが，自動キューと手動 bin/ref は別プロセスなので
# 重なりうる．枠を共有すれば，経路や起動回数に関わらず総量が一定になる．
#
# 枠は .locks/slots/slot-N ディレクトリで表す（mkdir がアトミックであることを利用）．
# 異常終了で枠が残った場合は，枠に書いた PID の生存を見て回収する．

RA_SLOT_DIR=""

ra_slot_reclaim_stale() {  # <枠の親ディレクトリ>
  local base="$1" d pid
  for d in "$base"/slot-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/pid" ]; then
      pid="$(cat "$d/pid" 2>/dev/null)"
      # 生きているプロセスが使用中の枠は触らない
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        continue
      fi
      rm -rf "$d" && ra_log "枠を回収した（プロセス ${pid:-不明} は終了済み）: $(basename "$d")"
    else
      # PID 書き込み前の枠を奪わないよう，1分以上古いものだけ回収する
      if [ -z "$(find "$d" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
        rm -rf "$d" && ra_log "枠を回収した（PID 不明・1分以上経過）: $(basename "$d")"
      fi
    fi
  done
}

# 枠を1つ取得する．取得できるまで待つ（既定で最大1時間）．
ra_slot_acquire() {  # [最大待機秒数]
  local limit="${1:-3600}" base n waited=0
  base="$PAPER_WORK_DIR/.locks/slots"
  mkdir -p "$base"
  while :; do
    n=1
    while [ "$n" -le "$PAPER_PARALLEL" ]; do
      if mkdir "$base/slot-$n" 2>/dev/null; then
        printf '%s' "$$" >"$base/slot-$n/pid"
        RA_SLOT_DIR="$base/slot-$n"
        ra_log "同時実行の枠を取得した: slot-${n}（全 ${PAPER_PARALLEL} 枠）"
        return 0
      fi
      n=$((n + 1))
    done
    ra_slot_reclaim_stale "$base"
    if [ "$waited" -ge "$limit" ]; then
      ra_log "警告: ${limit} 秒待っても枠が空かなかった．枠なしで続行する"
      RA_SLOT_DIR=""
      return 1
    fi
    [ "$waited" = "0" ] && ra_log "全 ${PAPER_PARALLEL} 枠が使用中．空くまで待つ"
    sleep 1
    waited=$((waited + 1))
  done
}

ra_slot_release() {
  [ -n "${RA_SLOT_DIR:-}" ] || return 0
  local name; name="$(basename "$RA_SLOT_DIR")"
  rm -rf "$RA_SLOT_DIR"
  RA_SLOT_DIR=""
  ra_log "同時実行の枠を解放した: ${name}"
}

# ---------------------------------------------------------------- 混入ガード

# 作業ディレクトリの祖先に CLAUDE.md があれば，そのパスを列挙して返す．
# 見つかった場合，開発用などの無関係な指示が論文処理に混入するおそれがある．
ra_find_ancestor_claude_md() {  # <dir>
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

ra_begin_run() {
  RA_RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
  RA_WORK_DIR="$PAPER_WORK_DIR/$RA_RUN_ID"
  RA_RECORD_DIR="$PAPER_LOG_DIR/$RA_RUN_ID"
  mkdir -p "$RA_WORK_DIR" "$RA_RECORD_DIR"
  RA_RUN_LOG="$RA_RECORD_DIR/run.log"
  : >"$RA_RUN_LOG"
  RA_STARTED_AT="$(date '+%s')"
  ra_log "run_id=$RA_RUN_ID engine=$PAPER_ENGINE model=$PAPER_MODEL effort=$PAPER_EFFORT mode=${RA_MODE:-unknown}"
  ra_log "work_dir=$RA_WORK_DIR"

  local stray
  stray="$(ra_find_ancestor_claude_md "$RA_WORK_DIR")"
  if [ -n "$stray" ]; then
    ra_log "警告: 作業ディレクトリの祖先に CLAUDE.md がある（混入のおそれ）: $stray"
    RA_GUARD_WARNING="祖先に CLAUDE.md: $stray"
  else
    RA_GUARD_WARNING=""
  fi
}

# ---------------------------------------------------------------- プロンプト

ra_build_prompt() {  # <対象の記述（複数行可）>
  local target="$1" sedexpr
  sedexpr="s|{{NOTION_DATA_SOURCE_ID}}|$NOTION_DATA_SOURCE_ID|g"
  {
    sed "$sedexpr" "$RA_REPO_ROOT/prompts/registration.md"
    printf '\n\n---\n\n'
    sed "$sedexpr" "$RA_REPO_ROOT/prompts/headless_addendum.md"
    printf '\n\n---\n\n# 今回の対象\n\n%s\n' "$target"
  } >"$RA_RECORD_DIR/prompt.md"
  ra_log "prompt.md を作成した（$(wc -c <"$RA_RECORD_DIR/prompt.md" | tr -d ' ') バイト）"
}

# ---------------------------------------------------------------- AI 実行と検証

# 成功時に RA_STATUS 等のグローバルを設定する．
# 返り値 : 0 = status が success，1 = それ以外（エンジン異常・検証失敗・AI が failed を返した）
ra_process() {  # <対象の記述>
  ra_build_prompt "$1"

  # 足場のファイルは AI のカレントディレクトリ（作業ディレクトリ）に置かない．
  # 置くと AI が「対象以外のファイルがある」と報告してしまう．
  local raw="$RA_RECORD_DIR/engine_raw.json"
  local errout="$RA_RECORD_DIR/engine.stderr"
  local rc=0
  # 同時に走る AI プロセスの総数を抑える．ここが唯一の制御点である．
  ra_slot_acquire || true
  ra_log "エンジンを起動する"
  ra_engine_run "$RA_WORK_DIR" "$RA_RECORD_DIR/prompt.md" "$raw" "$errout" || rc=$?
  ra_slot_release
  RA_ENGINE_RC="$rc"
  ra_log "エンジン終了コード=$rc"

  RA_SESSION_ID="$(ra_engine_session_id "$raw")"
  [ -n "$RA_SESSION_ID" ] && ra_log "session_id=$RA_SESSION_ID"

  # 出力の検証
  RA_RESULT_JSON="$RA_RECORD_DIR/result.json"
  if ra_py "$RA_REPO_ROOT/lib/validate_result.py" \
      "$raw" "$RA_REPO_ROOT/schema/result.schema.json" "$RA_RESULT_JSON" \
      2>>"$RA_RUN_LOG"; then
    RA_VALID=1
  else
    RA_VALID=0
    ra_log "出力JSONの検証に失敗した"
  fi

  if [ "$RA_VALID" = "1" ]; then
    RA_STATUS="$(ra_json_get "$RA_RESULT_JSON" status)"
    RA_CITATION_KEY="$(ra_normalize_key "$(ra_json_get "$RA_RESULT_JSON" citation_key)")"
    RA_TITLE="$(ra_json_get "$RA_RESULT_JSON" title)"
    RA_NOTION_URL="$(ra_json_get "$RA_RESULT_JSON" notion_url)"
    RA_RATING="$(ra_json_get "$RA_RESULT_JSON" rating)"
    RA_RATING_REASON="$(ra_json_get "$RA_RESULT_JSON" rating_reason)"
    RA_IMAGE_STATUS="$(ra_json_get "$RA_RESULT_JSON" image_status)"
    RA_ERROR="$(ra_json_get "$RA_RESULT_JSON" error)"
  else
    RA_STATUS="failed"; RA_CITATION_KEY=""; RA_TITLE=""; RA_NOTION_URL=""
    RA_RATING=""; RA_RATING_REASON=""; RA_IMAGE_STATUS=""
    RA_ERROR="AIの出力JSONを検証できなかった（記録: ${RA_RECORD_DIR}）"
  fi

  # 成功の定義 : 終了コード0，status=success，正規化後の citation_key が妥当
  if [ "$RA_ENGINE_RC" = "0" ] && [ "$RA_STATUS" = "success" ] && ra_key_is_sane "$RA_CITATION_KEY"; then
    if [ -n "$RA_GUARD_WARNING" ]; then
      ra_log "注意: 成功したが混入ガードの警告がある: $RA_GUARD_WARNING"
    fi
    return 0
  fi

  if [ "$RA_STATUS" = "success" ] && ! ra_key_is_sane "$RA_CITATION_KEY"; then
    RA_ERROR="citation_key が妥当でない（正規化後: \"$RA_CITATION_KEY\" / 正規化前: \"$(ra_json_get "$RA_RESULT_JSON" citation_key)\"）．非ASCII名のローマ字化に失敗した可能性がある"
  fi
  [ -z "$RA_ERROR" ] && RA_ERROR="原因不明（終了コード=$RA_ENGINE_RC status=${RA_STATUS}）"
  return 1
}

# ---------------------------------------------------------------- 実行記録

ra_save_records() {
  # prompt.md・engine_raw.json・engine.stderr は初めから記録ディレクトリへ書いている
  if ra_engine_save_transcript "$RA_WORK_DIR" "$RA_RECORD_DIR" "${RA_SESSION_ID:-}"; then
    ra_log "実行記録（transcript）を保存した"
  else
    ra_log "警告: 実行記録（transcript）を取得できなかった"
  fi
  ra_log "記録先=$RA_RECORD_DIR"
}

ra_elapsed() {
  local now; now="$(date '+%s')"
  printf '%s' "$((now - RA_STARTED_AT))"
}

ra_cleanup_work_dir() {  # 成功時のみ呼ぶ
  [ -n "${RA_WORK_DIR:-}" ] && [ -d "$RA_WORK_DIR" ] && rm -rf "$RA_WORK_DIR"
}
