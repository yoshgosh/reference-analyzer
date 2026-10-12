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
#   --strict-mcp-config     --mcp-config 以外の MCP 設定（claude.ai コネクタ等）を遮断する．
#                           Obsidian や Google Drive 経由で無関係な情報が入る経路を塞ぐ．
#   --mcp-config            notion サーバーを明示する．OAuth 認証は引き継がれる．
#   --permission-mode dontAsk  許可リスト外の操作は確認待ちにならず拒否される．
#   --json-schema           構造化出力．結果は engine_raw.json の structured_output に入る．
#   --model / --effort      明示的に固定する．--restricted が設定ファイルを無視するため，
#                           指定しないと CLI の既定に依存し，更新で静かに変わる．
#
#   --bare は使用しない（OAuth・キーチェーンを読まず ANTHROPIC_API_KEY を要求するため）．
#
# python3 は意図的に許可しない．--restricted が制限するのはファイルツールだけであり，
# Bash 経由の python3 は作業ディレクトリ外を自由に読める（実測で確認済み）．
# 残る迂回路は curl の file:// であり，Notion へのアップロードに必須のため残している．

# ALLOWED_COMMANDS（lib/analyze.sh の単一の定義元）から --allowedTools を組み立てる
claude_allowed_tools() {
  local cmd
  printf '%s\n' Read Write Glob Grep WebSearch WebFetch
  for cmd in $ALLOWED_COMMANDS; do
    printf 'Bash(%s *)\n' "$cmd"
  done
  printf '%s\n' mcp__notion
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
      --mcp-config "$REPO_ROOT/config/mcp.json" \
      --tools "Read,Write,Bash,WebSearch,WebFetch,Glob,Grep" \
      --allowedTools "${tools[@]}" \
      </dev/null >"$raw" 2>"$errout"
  )
}

engine_session_id() {  # <生出力のパス>
  json_get "$1" session_id
}

# Claude Code 自身が保存するセッションファイルを複製する．
# 置き場所は ~/.claude/projects/<cwd のスラッグ>/<session_id>.jsonl である．
# スラッグの規則に依存しないよう，session_id でファイル名を検索する．
engine_save_transcript() {  # <作業ディレクトリ> <記録ディレクトリ> <session_id>
  local record_dir="$2" sid="$3" src
  [ -z "$sid" ] && return 1
  src="$(find "$HOME/.claude/projects" -type f -name "$sid.jsonl" 2>/dev/null | head -1)"
  [ -z "$src" ] && return 1
  cp "$src" "$record_dir/transcript.jsonl" || return 1
  return 0
}
