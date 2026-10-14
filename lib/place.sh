#!/usr/bin/env bash
# 配置：改名と移動
#
# ユーザーのファイルに触る処理はこのファイルだけに閉じている．
# 一意な名前の決定は place_file が行い，配置ロックを取って
# 「空き名の確認」と「実際の移動」の間に別プロセスが割り込まないようにする．
#
#   手動 … 原本をその場で改名して終わり（rename_step）
#   自動 … inbox から in_progress へ取り込み（place_file），その場で改名し（rename_step），
#          PAPER_ROOT へ出す（move_step）
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

# ファイルを <ディレクトリ>/<基本名>.<拡張子> へ動かし，新しいパスを出力する．
# 基本名を省くと元の名前を保つ．拡張子は常に元のものを保つ．
# 同名があれば _2, _3 … を付ける．同じファイルを2プロセスが取り合った場合は，
# 負けた側の mv が失敗する（自動どうしの排他はこれに頼っている）．
place_file() {  # <パス> <移動先ディレクトリ> [基本名]
  local src="$1" dir="$2" name base ext lock dest
  name="$(basename "$src")"
  case "$name" in
    *.*) base="${name%.*}"; ext=".${name##*.}" ;;
    *)   base="$name"; ext="" ;;
  esac
  base="${3:-$base}"

  mkdir -p "$dir"
  lock="$(locks_dir)/place.lock"
  acquire_lock "$lock" 150 || log_msg "警告: 配置ロックを取得できなかった．そのまま続行する"
  dest="$(unique_path "$dir" "$base" "$ext")"
  if mv -n "$src" "$dest" 2>/dev/null; then
    release_lock "$lock"
    log_msg "配置した: $src -> $dest"
    printf '%s' "$dest"
    return 0
  fi
  release_lock "$lock"
  log_msg "配置に失敗した: $src -> $dest"
  return 1
}

# 対象（TARGET_PATH）をその場で <CitationKey>.<拡張子> に改名する．移動はしない．
# 両経路が共有する．自動では取り込み後の in_progress のファイルが対象になる．
#
# 通知は「いまどこにあるか」だけを出すので，作文はせず CURRENT_PATH を更新する．
#
# 返り値 0 … 改名した（URL のときも 0．改名する対象が無い）
#        1 … 改名していない
rename_step() {  # <解析と登録が成功なら1>
  local ok="$1" dest

  [ "$TARGET_KIND" = url ] && return 0
  # 解析か登録が失敗したときは原本に触らない．ステップは skipped のままにする．
  [ "$ok" != "1" ] && return 1

  if dest="$(place_file "$TARGET_PATH" "$(dirname "$TARGET_PATH")" "$CITATION_KEY")"; then
    step_completed rename
    CURRENT_PATH="$dest"
    return 0
  fi
  step_failed rename
  ERROR_MESSAGE="改名に失敗した（元: ${TARGET_PATH}）"
  return 1
}

# 自動の最後の段：改名済みの対象（CURRENT_PATH）を PAPER_ROOT へ出す．
# 自動の place_result と，自動の実行を再開する ref --resume が共有する．
move_step() {
  local dest
  if dest="$(place_file "$CURRENT_PATH" "$PAPER_ROOT")"; then
    step_completed move
    CURRENT_PATH="$dest"
    return 0
  fi
  step_failed move
  ERROR_MESSAGE="${PAPER_ROOT} への移動に失敗した"
  return 1
}
