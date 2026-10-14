#!/usr/bin/env python3
"""PDF の決まった下調べを AI の起動前に済ませる．

使い方 : pdf_prep.py <PDF> <本文テキストの出力先>

pdfinfo と pdfimages -list の結果，本文テキストのファイル名を，プロンプトの
「今回の対象」に足す記述（markdown）として標準出力へ書く．

AI は毎回この3つを最初に実行していた．1回の呼び出しが1ターンであり，
ターンごとに文脈全体を読み直すので，先に済ませるだけで費用が減る（2026-10-14 実測で，
14 ターン中 4 ターンがこの下調べだった）．

本文テキストは全文をプロンプトに入れず，ファイルとして置く．プロンプトに入れると
以降の全ターンで全文を読み直すことになり，かえって高くつく．

いずれかのコマンドが失敗しても止めない．その項目を記述から省くだけで，AI は自分で
実行し直せる．
"""
import subprocess
import sys

LIST_MAX_LINES = 40  # pdfimages -list の行数の上限（ヘッダ2行を含む）


def run(args):
    try:
        out = subprocess.run(args, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "replace")


def fence(text):
    return "```\n" + text.rstrip("\n") + "\n```"


def main():
    pdf, text_path = sys.argv[1:3]
    name = text_path.rsplit("/", 1)[-1]
    parts = ["", "### 下調べの結果（スクリプトが実行済み．同じコマンドを再実行しない）"]

    text = run(["pdftotext", "-layout", pdf, "-"])
    if text is not None:
        # pdftotext はページを \f で区切る．末尾の \f の後は空なので捨てる
        pages = text.split("\f")
        if pages and not pages[-1].strip():
            pages.pop()
        with open(text_path, "w", encoding="utf-8") as fh:
            for i, page in enumerate(pages, 1):
                fh.write(f"--- p.{i} ---\n{page.rstrip()}\n\n")
        parts += ["",
                  f"- 本文テキスト: `./{name}`（`pdftotext -layout` の出力，{len(pages)} ページ，"
                  f"{len(text)} 文字）",
                  "  - 各ページの先頭に `--- p.<頁> ---` の行がある．図の頁はキャプション"
                  "（Figure / Fig. / 図）を Grep ツールで探して特定する．",
                  "  - 長い場合は Read の offset / limit で必要な範囲だけを読む．"]

    info = run(["pdfinfo", pdf])
    if info is not None:
        parts += ["", "`pdfinfo` の結果:", "", fence(info)]

    listing = run(["pdfimages", "-list", pdf])
    if listing is not None:
        lines = listing.rstrip("\n").split("\n")
        shown = "\n".join(lines[:LIST_MAX_LINES])
        if len(lines) > LIST_MAX_LINES:
            shown += f"\n（以下 {len(lines) - LIST_MAX_LINES} 行を省略）"
        parts += ["", "`pdfimages -list` の結果:", "", fence(shown)]

    if len(parts) > 2:
        sys.stdout.write("\n".join(parts) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
