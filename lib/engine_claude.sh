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
#   --settings（sandbox）   Bash を OS のサンドボックスで動かし，ホーム全体の読み取りを
#                           禁じて作業ディレクトリだけを許す（claude_sandbox_settings）．
#                           --restricted でも --settings は効く．
#
# 起動前に ENGINE_UNSET_VARS（lib/core.sh）を外し，トークンを AI のプロセスへ渡さない．
#
# python3 は意図的に許可しない．--restricted が制限するのはファイルツールだけであり，
# Bash 経由の python3 は作業ディレクトリ外を自由に読める（実測で確認済み）．
# curl も file:// や -d @<ファイル> でローカルのファイルを読めるが，サンドボックスが
# 読み取りそのものを止める．文字列の拒否ルールでは書き方を変えれば通るので使わない．

# ALLOWED_COMMANDS（lib/analyze.sh の単一の定義元）から --allowedTools を組み立てる
claude_allowed_tools() {
  local cmd
  printf '%s\n' Read Write Glob Grep WebSearch WebFetch
  for cmd in $ALLOWED_COMMANDS; do
    printf 'Bash(%s *)\n' "$cmd"
  done
}

# サンドボックスの設定（JSON）．実測で確認済み（2026-10-14, claude 2.1.296）:
#
#   denyRead のホーム配下は curl file:// で読めない（exit 37）．-d @ 等も同じく止まる
#   allowRead に挙げた作業ディレクトリは，denyRead の中にあっても読める
#   network.allowedDomains を "*" にしないと Web へ出られない（既定は全拒否）
#   allowUnsandboxedCommands=false で，AI がサンドボックスを外して再実行することを禁じる
#   書き込みは既定でカレント（作業ディレクトリ）に限られる
#
# ホーム全体を禁じるので，.env，~/.ssh，他の論文，過去の会話の記録（~/.claude）に届かない．
# リポジトリと PAPER_ROOT がホームの外にある場合に備え，これらも名前で挙げる．
claude_sandbox_settings() {  # <作業ディレクトリ>
  py -c '
import json, os, sys
work, *deny = (os.path.realpath(p) for p in sys.argv[1:])
print(json.dumps({"sandbox": {
    "enabled": True,
    "autoAllowBashIfSandboxed": False,
    "allowUnsandboxedCommands": False,
    "network": {"allowedDomains": ["*"]},
    "filesystem": {"denyRead": deny, "allowRead": [work]},
}}))
' "$1" "$HOME" "$REPO_ROOT" "$PAPER_ROOT"
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

  # 秘密情報を AI に渡さない．load_env は .env を export するので，外さないと
  # AI が実行するコマンドから見える（curl で外へ送れてしまう）．
  # unset ではなく env -u で外す．引数（--model 等）は外す前に展開されるので
  # PAPER_MODEL のように .env に書いた設定も使える
  local unset_args=() var
  for var in $ENGINE_UNSET_VARS; do
    unset_args[${#unset_args[@]}]="-u"
    unset_args[${#unset_args[@]}]="$var"
  done

  local sandbox
  sandbox="$(claude_sandbox_settings "$work")" || return 1

  (
    cd "$work" || exit 1
    env ${unset_args[@]+"${unset_args[@]}"} claude -p "$(cat "$prompt_file")" \
      --model "$PAPER_MODEL" \
      --effort "$PAPER_EFFORT" \
      --output-format json \
      --json-schema "$(cat "$REPO_ROOT/schema/result.schema.json")" \
      --permission-mode dontAsk \
      --restricted \
      --strict-mcp-config \
      --tools "Read,Write,Bash,WebSearch,WebFetch,Glob,Grep" \
      --allowedTools "${tools[@]}" \
      --settings "$sandbox" \
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

# 使用量を1行にまとめる（通知の usage: 行）．取れなければ空文字列を返す．
# 金額は API の定価で換算した値である．サブスクリプションでは実際の請求額ではない．
# in は入力の合計（キャッシュの読み書きを含む）．ターンごとに文脈全体を読み直すので，
# ターン数とほぼ比例して増える．
engine_usage_summary() {  # <生出力のパス>
  [ -s "$1" ] || return 0
  py -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    u = d["usage"]
    tin = sum(u.get(k) or 0 for k in
              ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    tout = u.get("output_tokens") or 0
    turns, cost = d["num_turns"], d["total_cost_usd"]
except Exception:
    sys.exit(0)
k = lambda n: f"{n / 1000:.1f}k" if n < 10000 else f"{n / 1000:.0f}k"
sys.stdout.write(f"{turns} turns, {k(tin)} in / {k(tout)} out tokens, ${cost:.2f} (list price)")
' "$1"
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

engine_save_transcript() {  # <記録ディレクトリ> <session_id>
  local record_dir="$1" src
  src="$(engine_transcript_path "$2")"
  [ -z "$src" ] && return 1
  cp "$src" "$record_dir/transcript.jsonl" || return 1
  return 0
}
