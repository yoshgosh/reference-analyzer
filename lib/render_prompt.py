#!/usr/bin/env python3
"""指示文を組み立てて標準出力へ書く．

使い方 : render_prompt.py <追加ルールのファイル名> <今回の対象の記述> [名前=値 ...]

prompts/registration.md（共通：何を作るか）の後に，追加ルール（headless_addendum.md または
chat_addendum.md：どう登録・出力するか）と「今回の対象」をつなげ，{{名前}} を値で置き換える．

既存タグ（{{EXISTING_TAGS}}）は Notion から取得し，登録先（{{NOTION_DATA_SOURCE_ID}}）は
環境変数から埋める．それ以外は引数で渡す．置き換えられずに残った {{…}} があれば失敗する
（渡し忘れを AI に見せないため）．

Notion を確認できなければ終了コード 1 を返す．AI を起動する前に止めるためである．
"""
import os
import re
import sys

# python3 -I はスクリプトのディレクトリを import の検索先に入れないので，明示的に足す
LIB = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB)
import notion  # noqa: E402

PROMPTS = os.path.join(LIB, "..", "prompts")


def main():
    addendum, target, *pairs = sys.argv[1:]

    try:
        tags = notion.tag_names()
    except (notion.NotionError, KeyError) as exc:
        print(f"Notion のデータベースを確認できなかった: {exc}", file=sys.stderr)
        return 1

    values = {"EXISTING_TAGS": "\n".join(tags) or "（まだ無い）",
              "NOTION_DATA_SOURCE_ID": os.environ["NOTION_DATA_SOURCE_ID"]}
    for pair in pairs:
        name, value = pair.split("=", 1)
        values[name] = value

    parts = [open(os.path.join(PROMPTS, name), encoding="utf-8").read()
             for name in ("registration.md", addendum)]
    text = "\n\n---\n\n".join(parts) + f"\n\n---\n\n# 今回の対象\n\n{target}\n"
    for name, value in values.items():
        text = text.replace("{{" + name + "}}", value)

    left = sorted(set(re.findall(r"\{\{[A-Z_]+\}\}", text)))
    if left:
        print(f"置き換えられていないプレースホルダーがある: {', '.join(left)}", file=sys.stderr)
        return 1
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
