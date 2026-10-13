#!/usr/bin/env bash
# 配置：改名と移動
#
# ユーザーのファイルに触る処理はこのファイルだけに閉じている．
# 一意な名前の決定は「着地させる関数」が行い，配置ロックを取って
# 「空き名の確認」と「実際の移動」の間に別プロセスが割り込まないようにする．
#
# 対象を改名する処理（place_in_place）は両経路で共有する．
#   手動 … 原本をその場で改名して終わり（移動しない）
#   自動 … in_progress のファイルを改名し，続けて move_into で PAPER_ROOT へ出す
#
# ユーザーのファイルは作業ディレクトリに入らない．入るのはコピーだけである．

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

# 対象（TARGET_PATH）をその場で <CitationKey>.<拡張子> に改名する．移動はしない．
# 両経路が共有する．自動では確保後の in_progress のファイルが対象になる．
#
# 返り値 0 … 改名した（URL のときも 0．改名する対象が無い）
#        1 … 改名していない
# 改名後のパスは RENAMED_PATH に入れる．
place_in_place() {  # <解析が成功なら1>
  local ok="$1" dest
  RENAMED_PATH=""

  if [ "$TARGET_KIND" = url ]; then
    PLACEMENT=""
    return 0
  fi
  if [ "$ok" != "1" ]; then
    PLACEMENT="${TARGET_PATH}（改名していない）"
    return 1
  fi
  if dest="$(rename_to_key "$TARGET_PATH" "$CITATION_KEY")"; then
    step_ok rename
    RENAMED_PATH="$dest"
    PLACEMENT="${TARGET_LABEL} → $(basename "$dest")"
    return 0
  fi
  PLACEMENT="${TARGET_PATH}（改名できなかった）"
  ERROR_MESSAGE="改名に失敗した（元: ${TARGET_PATH}）"
  return 1
}
