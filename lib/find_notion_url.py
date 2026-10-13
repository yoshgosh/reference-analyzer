#!/usr/bin/env python3
"""transcript から，作成された Notion ページのURLを探す．

使い方 : find_notion_url.py <transcript.jsonl>

AI の構造化出力は最後にまとめて生まれるため，利用上限（429）などで途中切断されると
得られない．しかしその時点でページが作成済みであることはありうる．

ページが存在するのに「ページ未作成・再実行可」と通知すると，再実行で重複登録になる．
それを防ぐため，transcript に残る notion-create-pages の結果からURLを拾う．

成功したページ作成が見つかればURLを出力し，見つからなければ何も出力しない．
"""
import json
import re
import sys

URL_RE = re.compile(r"https://[a-z.]*notion\.(?:so|com)/[^\s\"'\\]+")


def iter_blocks(path):
    """transcript の各行から content ブロックを取り出す．"""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            message = rec.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        yield block


def result_text(block):
    """tool_result の中身を文字列にする．"""
    content = block.get("content")
    if isinstance(content, str):
        return content
    try:
        return json.dumps(content, ensure_ascii=False)
    except Exception:
        return ""


def main():
    path = sys.argv[1]

    # ページ作成を呼んだ tool_use の id を集め，対応する結果を照合する
    create_ids = set()
    urls = []

    for block in iter_blocks(path):
        kind = block.get("type")

        if kind == "tool_use" and "create-pages" in str(block.get("name", "")):
            if block.get("id"):
                create_ids.add(block["id"])

        elif kind == "tool_result" and block.get("tool_use_id") in create_ids:
            if block.get("is_error"):
                continue  # 400 などで拒否された呼び出しは無視する
            text = result_text(block)
            # {"pages":[{"id":…,"url":"https://app.notion.com/p/…"}]} の形を想定し，
            # 形が変わっても拾えるよう正規表現でも探す
            found = URL_RE.search(text)
            if found:
                urls.append(found.group(0).rstrip(",}\"'"))

    if urls:
        # 複数あれば最後のものを採る（最後の試行が実際のページ）
        sys.stdout.write(urls[-1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
