#!/usr/bin/env python3
"""指示文を組み立てて標準出力へ書く．

使い方 : render_prompt.py <追加ルールのファイル名> [名前=値 ...]

prompts/registration.md（共通：何を作るか）の後に，追加ルール（headless_addendum.md または
chat_addendum.md：どう登録・出力するか）をつなげ，{{名前}} を値で置き換える．
置き換えられずに残った {{…}} があれば失敗する（渡し忘れを AI に見せないため）．
「今回の対象」は呼び出し側が末尾に足す．
"""
import os
import re
import sys


def main():
    addendum, *pairs = sys.argv[1:]
    prompts = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prompts")
    parts = [open(os.path.join(prompts, name), encoding="utf-8").read()
             for name in ("registration.md", addendum)]
    text = "\n\n---\n\n".join(parts)

    for pair in pairs:
        name, value = pair.split("=", 1)
        text = text.replace("{{" + name + "}}", value)

    left = sorted(set(re.findall(r"\{\{[A-Z_]+\}\}", text)))
    if left:
        print(f"置き換えられていないプレースホルダーがある: {', '.join(left)}", file=sys.stderr)
        return 1
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
