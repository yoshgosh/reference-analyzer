#!/usr/bin/env bash
# 配置：改名と移動
#
# ユーザーのファイルに触る処理はこのファイルだけに閉じている．
# 一意な名前の決定は「最終的な置き場所に着地させる関数」が行う．
#   手動 … rename_to_key が原本のディレクトリ内で解決する（最終形はここで決まる）
#   自動 … 作業ディレクトリ内で rename_to_key（衝突しない）→ move_into が PAPER_ROOT で解決する
#
# どちらも配置ロックを取り，「空き名の確認」と「実際の移動」の間に
# 別プロセスが割り込まないようにする．

# 空いているパスを返す（同名があれば _2, _3 …）
unique_path() {  # <ディレクトリ> <基本名> <拡張子>
  local dir="$1" base="$2" ext="$3" n=2 cand
  cand="$dir/$base$ext"
  while [ -e "$cand" ]; do
    cand="$dir/${base}_${n}${ext}"
    n=$((n + 1))
  done
  printf '%s' "$cand"
}

# そのファイルがあるディレクトリ内で <Key>.<拡張子> に改名し，新しいパスを出力する
rename_to_key() {  # <パス> <CitationKey>
  local src="$1" key="$2" dir ext lock dest
  dir="$(cd "$(dirname "$src")" && pwd)"
  case "$src" in
    *.*) ext=".${src##*.}" ;;
    *)   ext="" ;;
  esac

  lock="$(locks_dir)/place.lock"
  acquire_lock "$lock" 150 || log_msg "警告: 配置ロックを取得できなかった．そのまま続行する"
  dest="$(unique_path "$dir" "$key" "$ext")"
  if mv -n "$src" "$dest" 2>/dev/null; then
    release_lock "$lock"
    log_msg "改名した: $(basename "$src") -> $(basename "$dest")"
    printf '%s' "$dest"
    return 0
  fi
  release_lock "$lock"
  log_msg "改名に失敗した: $src"
  return 1
}

# 指定ディレクトリへ移動し，新しいパスを出力する．名前は維持する（同名があれば _2, _3）
move_into() {  # <パス> <移動先ディレクトリ> [基本名を差し替える場合の名前]
  local src="$1" dir="$2" base="${3:-}" ext lock dest name
  name="$(basename "$src")"
  if [ -z "$base" ]; then
    case "$name" in
      *.*) base="${name%.*}"; ext=".${name##*.}" ;;
      *)   base="$name"; ext="" ;;
    esac
  else
    case "$name" in
      *.*) ext=".${name##*.}" ;;
      *)   ext="" ;;
    esac
  fi

  mkdir -p "$dir"
  lock="$(locks_dir)/place.lock"
  acquire_lock "$lock" 150 || log_msg "警告: 配置ロックを取得できなかった．そのまま続行する"
  dest="$(unique_path "$dir" "$base" "$ext")"
  if mv -n "$src" "$dest" 2>/dev/null; then
    release_lock "$lock"
    log_msg "移動した: $name -> $dest"
    printf '%s' "$dest"
    return 0
  fi
  release_lock "$lock"
  log_msg "移動に失敗した: $src -> $dir"
  return 1
}
