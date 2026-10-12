#!/usr/bin/env bash
# Claude Code（claude -p）によるエンジン実装
#
# フラグの構成は実測で確認済みである（2026-10-12, claude 2.1.296）:
#   --restricted            ファイルツールを作業ディレクトリに限定し，user/project/local の設定を無視する．
#                           これにより作業ディレクトリ外の Read が拒否される（混入防止の中核）．
#                           ただし Bash と WebFetch は --tools で明示しないと消える．
#   --strict-mcp-config     --mcp-config 以外の MCP 設定（claude.ai コネクタ等）を遮断する．
#                           Notion 以外のコネクタ経由で無関係な情報が入る経路を塞ぐ．
#   --mcp-config            notion サーバーを明示する．OAuth 認証は引き継がれる（確認済み）．
#   --permission-mode dontAsk  許可リスト外の操作は確認待ちにならず拒否される．
#   --json-schema           構造化出力．結果は engine_raw.json の structured_output に入る．
#   --model / --effort      明示的に固定する（PAPER_MODEL / PAPER_EFFORT）．
#                           --restricted は user/project/local の設定ファイルを無視するため，
#                           指定しないと CLI の組み込み既定に依存し，更新で静かに変わる．
#   --bare は使用しない（OAuth・キーチェーンを読まず ANTHROPIC_API_KEY を要求するため）．
#
# python3 は意図的に許可しない．--restricted が制限するのはファイルツールだけであり，
# Bash 経由の python3 は作業ディレクトリ外のファイルを自由に読める（実測で確認済み）．
# 混入防止の境界を保つため外している．残る迂回路は curl（file:// 等）であり，
# Notion へのアップロードに必須のため現状は残している．

ra_engine_run() {  # <work_dir> <prompt_file> <raw_out> <stderr_out>
  local work="$1" prompt_file="$2" raw="$3" errout="$4"

  if ! command -v claude >/dev/null 2>&1; then
    echo "claude コマンドが PATH に無い" >"$errout"
    return 127
  fi

  (
    cd "$work" || exit 1
    claude -p "$(cat "$prompt_file")" \
      --model "$PAPER_MODEL" \
      --effort "$PAPER_EFFORT" \
      --output-format json \
      --json-schema "$(cat "$RA_REPO_ROOT/schema/result.schema.json")" \
      --permission-mode dontAsk \
      --restricted \
      --strict-mcp-config \
      --mcp-config "$RA_REPO_ROOT/config/mcp.json" \
      --tools "Read,Write,Bash,WebSearch,WebFetch,Glob,Grep" \
      --allowedTools \
        Read Write Glob Grep WebSearch WebFetch \
        "Bash(curl *)" \
        "Bash(pdftotext *)" "Bash(pdfimages *)" "Bash(pdftoppm *)" "Bash(pdfinfo *)" \
        mcp__notion \
      </dev/null >"$raw" 2>"$errout"
  )
}

ra_engine_session_id() {  # <raw_out>
  ra_json_get "$1" session_id
}

# Claude Code 自身が保存するセッションファイルを複製する．
# 置き場所は ~/.claude/projects/<cwd のスラッグ>/<session_id>.jsonl である．
# スラッグの規則に依存しないよう，session_id でファイル名を検索する．
ra_engine_save_transcript() {  # <work_dir> <record_dir> <session_id>
  local record_dir="$2" sid="$3" src
  [ -z "$sid" ] && return 1
  src="$(find "$HOME/.claude/projects" -type f -name "$sid.jsonl" 2>/dev/null | head -1)"
  [ -z "$src" ] && return 1
  cp "$src" "$record_dir/transcript.jsonl" || return 1
  return 0
}
