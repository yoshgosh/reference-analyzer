#!/usr/bin/env bash
# launchd エージェントの導入・解除
#
#   launchd/install.sh install     テンプレートを展開して登録する
#   launchd/install.sh uninstall   登録を解除する
#   launchd/install.sh status      状態を表示する
#
# launchd は対話シェルの環境を引き継がないため，PATH を明示して埋め込む．
# claude の実パスから PATH を組み立てるので，nvm 等でパスが変わる環境でも導入時点の
# 場所が記録される．Node を入れ替えた場合は再導入が必要である（status で検出できる）．
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/lib/core.sh"

LABEL="com.user.reference-analyzer"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$REPO_ROOT/launchd/com.user.reference-analyzer.plist.template"

load_env || exit 1

preflight() {
  local ok=0

  if command -v claude >/dev/null 2>&1; then
    echo "  claude            : $(command -v claude)"
  else
    echo "  claude            : 見つからない（PATH を確認せよ）" >&2
    ok=1
  fi

  if command -v pdfimages >/dev/null 2>&1; then
    echo "  poppler           : $(command -v pdfimages)"
  else
    echo "  poppler           : 見つからない（brew install poppler）" >&2
    ok=1
  fi

  if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL:-}" ]; then
    echo "  Slack             : 設定あり（channel=${SLACK_CHANNEL}）"
  else
    echo "  Slack             : 未設定（通知は送られない）"
  fi

  echo "  NOTION_DATA_SOURCE_ID : $NOTION_DATA_SOURCE_ID"
  echo "  inbox             : $PAPER_INBOX_DIR"
  echo "  in_progress       : $PAPER_IN_PROGRESS_DIR"
  echo "  PAPER_PARALLEL    : $PAPER_PARALLEL"
  echo "  engine / model    : $PAPER_ENGINE / $PAPER_MODEL / effort=$PAPER_EFFORT"

  return "$ok"
}

do_install() {
  echo "事前確認:"
  preflight || { echo "事前確認に失敗した．導入を中止する" >&2; exit 1; }

  mkdir -p "$PAPER_INBOX_DIR" "$PAPER_IN_PROGRESS_DIR" "$PAPER_LOG_DIR" "$HOME/Library/LaunchAgents"

  # claude の所在を PATH の先頭に置く．nvm 配下でも確実に見つかるようにする．
  local claude_dir path_value
  claude_dir="$(dirname "$(command -v claude)")"
  path_value="$claude_dir:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  py - "$TEMPLATE" "$PLIST_DEST" \
    "$LABEL" "$REPO_ROOT" "$PAPER_INBOX_DIR" "$PAPER_LOG_DIR" "$path_value" "$HOME" <<'PYEOF'
import sys
tpl, dest, label, repo, inbox, logdir, pathv, home = sys.argv[1:9]
s = open(tpl, encoding="utf-8").read()
for k, v in (("{{LABEL}}", label), ("{{REPO_ROOT}}", repo), ("{{INBOX_DIR}}", inbox),
             ("{{LOG_DIR}}", logdir), ("{{PATH_VALUE}}", pathv), ("{{HOME_DIR}}", home)):
    s = s.replace(k, v)
assert "{{" not in s, "未置換のプレースホルダーが残っている"
open(dest, "w", encoding="utf-8").write(s)
print(f"  生成: {dest}")
PYEOF

  plutil -lint "$PLIST_DEST" >/dev/null || { echo "plist の検証に失敗した" >&2; exit 1; }

  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
  echo "登録した: $LABEL"
  echo
  echo "確認方法:"
  echo "  launchd/install.sh status"
  echo "  PDF を $PAPER_INBOX_DIR に置くと処理が始まる"
}

do_uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "解除した: $LABEL" || echo "登録されていない"
  if [ -f "$PLIST_DEST" ]; then
    rm -f "$PLIST_DEST"
    echo "削除した: $PLIST_DEST"
  fi
}

do_status() {
  echo "設定:"
  preflight || true
  echo
  echo "登録状態:"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|program|last exit|path =" | sed 's/^/  /' || true
  else
    echo "  未登録"
  fi

  # 導入時に埋め込んだ claude のパスが今も有効かを確認する
  if [ -f "$PLIST_DEST" ]; then
    local embedded
    embedded="$(py -c '
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
sys.stdout.write(d.get("EnvironmentVariables", {}).get("PATH", ""))
' "$PLIST_DEST")"
    local first="${embedded%%:*}"
    if [ -x "$first/claude" ]; then
      echo "  埋め込んだ claude : $first/claude（有効）"
    else
      echo "  埋め込んだ claude : $first/claude（**見つからない．再導入が必要**）"
    fi
  fi

  echo
  echo "最近のログ:"
  for f in "$PAPER_LOG_DIR/launchd.err.log" "$PAPER_LOG_DIR/launchd.out.log"; do
    [ -f "$f" ] && { echo "  --- $(basename "$f") ---"; tail -5 "$f" | sed 's/^/    /'; }
  done
}

case "${1:-}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) echo "使い方: install.sh {install|uninstall|status}" >&2; exit 2 ;;
esac
