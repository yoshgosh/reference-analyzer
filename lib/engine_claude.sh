#!/usr/bin/env bash
# Claude Code（claude -p）によるエンジン実装
#
# フラグの構成は実測で確認済みである（2026-10-12, claude 2.1.296）:
#
#   --restricted            ファイルツール（Read/Write/Glob/Grep）を作業ディレクトリに限定し，
#                           user/project/local の設定ファイルを無視する．
#                           これにより作業ディレクトリ外の Read が拒否される．
#                           プロセスを分けただけでは防げない経路を塞ぐための要である．
#                           ただし Bash と WebFetch は --tools で明示しないと消える．
#   --strict-mcp-config     --mcp-config を渡さないので，MCP を1つも読み込まない．
#                           Obsidian や Google Drive 経由で無関係な情報が入る経路を塞ぐ．
#                           Notion への登録はスクリプトが行う（lib/notion.py）．
#                           Notion MCP はツール定義だけで約 85k トークンあり，
#                           それが毎ターン読み直されていた（2026-10-14 実測）．
#   --permission-mode dontAsk  許可リスト外の操作は確認待ちにならず拒否される．
#   --json-schema           構造化出力．結果は engine_raw.json の structured_output に入る．
#   --model / --effort      明示的に固定する．--restricted が設定ファイルを無視するため，
#                           指定しないと CLI の既定に依存し，更新で静かに変わる．
#
#   --bare は使用しない（OAuth・キーチェーンを読まず ANTHROPIC_API_KEY を要求するため）．
#
# python3 は意図的に許可しない．--restricted が制限するのはファイルツールだけであり，
# Bash 経由の python3 は作業ディレクトリ外を自由に読める（実測で確認済み）．
# 残る迂回路は curl の file:// であり，Web から代表画像を取るために残している．

# ALLOWED_COMMANDS（lib/analyze.sh の単一の定義元）から --allowedTools を組み立てる
claude_allowed_tools() {
  local cmd
  printf '%s\n' Read Write Glob Grep WebSearch WebFetch
  for cmd in $ALLOWED_COMMANDS; do
    printf 'Bash(%s *)\n' "$cmd"
  done
}

run_engine() {  # <作業ディレクトリ> <プロンプトのパス> <生出力のパス> <標準エラーのパス>
  local work="$1" prompt_file="$2" raw="$3" errout="$4"

  if ! command -v claude >/dev/null 2>&1; then
    echo "claude コマンドが PATH に無い" >"$errout"
    return 127
  fi

  # 許可リストを配列に展開する（bash 3.2 でも動く形）
  local tools=()
  local line
  while IFS= read -r line; do
    tools[${#tools[@]}]="$line"
  done <<EOF
$(claude_allowed_tools)
EOF

  (
    cd "$work" || exit 1
    claude -p "$(cat "$prompt_file")" \
      --model "$PAPER_MODEL" \
      --effort "$PAPER_EFFORT" \
      --output-format json \
      --json-schema "$(cat "$REPO_ROOT/schema/result.schema.json")" \
      --permission-mode dontAsk \
      --restricted \
      --strict-mcp-config \
      --tools "Read,Write,Bash,WebSearch,WebFetch,Glob,Grep" \
      --allowedTools "${tools[@]}" \
      </dev/null >"$raw" 2>"$errout"
  )
}

# エンジン自身の失敗（認証・利用上限・ネットワーク等）を人が読める形にまとめる．
# AI が資料を読んで failed と判断した場合とは区別が必要で，こちらは資料の問題ではない．
# 失敗していなければ空文字列を返す．
engine_error_summary() {  # <生出力のパス>
  local raw="$1" is_err status terminal result

  if [ ! -s "$raw" ]; then
    printf 'エンジンが出力を返さなかった'
    return 0
  fi

  is_err="$(json_get "$raw" is_error)"
  [ "$is_err" != "True" ] && return 0

  status="$(json_get "$raw" api_error_status)"
  terminal="$(json_get "$raw" terminal_reason)"
  result="$(json_get "$raw" result)"

  case "$status" in
    429)
      printf '利用上限またはレート制限に達した（429）'
      ;;
    4*|5*)
      printf 'APIエラー（%s）' "$status"
      ;;
    *)
      printf 'エンジンが異常終了した（terminal_reason=%s）' "${terminal:-不明}"
      ;;
  esac
  # claude -p は result に人が読める説明を入れる（例: セッション上限の回復時刻）
  [ -n "$result" ] && printf ' — %s' "$result"
  return 0
}

engine_session_id() {  # <生出力のパス>
  json_get "$1" session_id
}

# Claude Code 自身が保存するセッションファイルの場所を返す．
# 置き場所は ~/.claude/projects/<cwd のスラッグ>/<session_id>.jsonl である．
# スラッグの規則に依存しないよう，session_id でファイル名を検索する．
engine_transcript_path() {  # <session_id>
  [ -n "$1" ] || return 0
  find "$HOME/.claude/projects" -type f -name "$1.jsonl" 2>/dev/null | head -1
}

engine_save_transcript() {  # <作業ディレクトリ> <記録ディレクトリ> <session_id>
  local record_dir="$2" src
  src="$(engine_transcript_path "$3")"
  [ -z "$src" ] && return 1
  cp "$src" "$record_dir/transcript.jsonl" || return 1
  return 0
}
