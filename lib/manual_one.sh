#!/usr/bin/env bash
# 手動経路：資料1本の処理
#
#   manual_one.sh file <PDFのパス>
#   manual_one.sh url  <URL>
#
# 確定事項 : 手動で指定した資料は移動しない．成功時にその場で改名するだけである．
#            失敗時は元のファイルに一切触らない（failed/ へも移さない）．
#
# 自動経路（auto_one.sh）との違いはこのファイルに閉じている．
# 共有部分は lib/core.sh にあり，対象の確保と最終的な配置のみを本ファイルが行う．
set -euo pipefail

RA_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$RA_REPO_ROOT/lib/core.sh"
. "$RA_REPO_ROOT/lib/cleanup.sh"

RA_MODE="${1:-}"
RA_TARGET="${2:-}"

if [ -z "$RA_MODE" ] || [ -z "$RA_TARGET" ]; then
  echo "使い方: manual_one.sh {file|url} <対象>" >&2
  exit 2
fi

ra_load_env || exit 1
ra_cleanup_old_records || true

RA_LOCK=""
cleanup_on_exit() {
  ra_slot_release 2>/dev/null || true
  [ -n "$RA_LOCK" ] && ra_lock_release "$RA_LOCK"
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------- file モード

run_file_mode() {
  local src="$src_abs" dir base ext work_copy lock_key

  dir="$(cd "$(dirname "$src")" && pwd)"
  base="$(basename "$src")"
  ext=".pdf"

  # 同じファイルに対する ref の同時実行を弾く（移動しないため mv による確保ができない）
  mkdir -p "$PAPER_WORK_DIR/.locks"
  lock_key="$(printf '%s' "$dir/$base" | shasum -a 256 | cut -c1-16)"
  RA_LOCK="$PAPER_WORK_DIR/.locks/file-$lock_key.lock"
  if ! ra_lock_acquire "$RA_LOCK" 5; then
    echo "このファイルは既に処理中である: $dir/$base" >&2
    RA_LOCK=""
    exit 1
  fi

  ra_begin_run
  ra_log "mode=file target=$dir/$base"

  # AI には作業ディレクトリ内のコピーのみを見せる（元ファイルには触れさせない）
  work_copy="$RA_WORK_DIR/$base"
  cp "$src" "$work_copy"
  ra_log "作業ディレクトリへコピーした: $base"

  local target_desc
  target_desc="$(printf '%s\n' \
    "- 種別: PDFファイル" \
    "- ファイル: ./$base" \
    "- このファイルは作業ディレクトリ内のコピーである．" \
    "" \
    "この1本のみを処理せよ．作業ディレクトリ内の他のファイルは対象ではない．")"

  if ra_process "$target_desc"; then
    # 成功 : 元の場所で改名する（移動はしない）
    local rename_lock dest
    rename_lock="$PAPER_WORK_DIR/.locks/rename.lock"
    ra_lock_acquire "$rename_lock" 150 || ra_log "警告: 改名ロックを取得できなかった．そのまま続行する"
    dest="$(ra_unique_path "$dir" "$RA_CITATION_KEY" "$ext")"
    if mv -n "$src" "$dest"; then
      ra_log "改名した: $base -> $(basename "$dest")"
      ra_lock_release "$rename_lock"
      ra_save_records
      ra_notify_success "$(basename "$dest")（$dir に据え置き）"
      ra_cleanup_work_dir
      echo "成功: $RA_TITLE"
      echo "  Citation Key : $RA_CITATION_KEY"
      echo "  Notion       : $RA_NOTION_URL"
      echo "  ファイル     : $dest"
      exit 0
    fi
    ra_lock_release "$rename_lock"
    # Notion 登録は済んでいるので，改名の失敗だけを報告する
    RA_ERROR="Notion 登録は成功したが，改名に失敗した（元: ${src}）"
    ra_log "$RA_ERROR"
    ra_save_records
    ra_notify_failure "$base"
    echo "一部失敗: Notion 登録は成功，改名に失敗した（${RA_NOTION_URL}）" >&2
    exit 1
  fi

  # 失敗 : 元のファイルには触らない
  ra_log "失敗: $RA_ERROR"
  ra_save_records
  ra_notify_failure "$base"
  echo "失敗: $RA_ERROR" >&2
  echo "  元ファイルは変更していない: $src" >&2
  echo "  ログ: $RA_RECORD_DIR" >&2
  exit 1
}

# ---------------------------------------------------------------- url モード

run_url_mode() {
  local url="$RA_TARGET" lock_key

  mkdir -p "$PAPER_WORK_DIR/.locks"
  lock_key="$(printf '%s' "$url" | shasum -a 256 | cut -c1-16)"
  RA_LOCK="$PAPER_WORK_DIR/.locks/url-$lock_key.lock"
  if ! ra_lock_acquire "$RA_LOCK" 5; then
    echo "このURLは既に処理中である: $url" >&2
    RA_LOCK=""
    exit 1
  fi

  ra_begin_run
  ra_log "mode=url target=$url"

  local target_desc
  target_desc="$(printf '%s\n' \
    "- 種別: URL（Webページ・GitHubリポジトリ等）" \
    "- URL: $url" \
    "" \
    "このURLの資料のみを処理せよ．改名・保存するファイルは無い．")"

  if ra_process "$target_desc"; then
    ra_save_records
    ra_notify_success "（URLのためファイルなし）"
    ra_cleanup_work_dir
    echo "成功: $RA_TITLE"
    echo "  Citation Key : $RA_CITATION_KEY"
    echo "  Notion       : $RA_NOTION_URL"
    exit 0
  fi

  ra_log "失敗: $RA_ERROR"
  ra_save_records
  ra_notify_failure "$url"
  echo "失敗: $RA_ERROR" >&2
  echo "  ログ: $RA_RECORD_DIR" >&2
  exit 1
}

# ---------------------------------------------------------------- 振り分け

case "$RA_MODE" in
  file)
    if [ ! -f "$RA_TARGET" ]; then
      echo "ファイルが見つからない: $RA_TARGET" >&2
      exit 2
    fi
    case "$(printf '%s' "$RA_TARGET" | tr 'A-Z' 'a-z')" in
      *.pdf) ;;
      *) echo "PDF ではない: $RA_TARGET" >&2; exit 2 ;;
    esac
    src_abs="$(cd "$(dirname "$RA_TARGET")" && pwd)/$(basename "$RA_TARGET")"
    run_file_mode
    ;;
  url)
    run_url_mode
    ;;
  *)
    echo "不正なモード: ${RA_MODE}（file または url）" >&2
    exit 2
    ;;
esac
