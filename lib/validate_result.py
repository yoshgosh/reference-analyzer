#!/usr/bin/env python3
"""AI の最終出力を検証し，正規化した result.json を書き出す．

使い方 : validate_result.py <engine_raw.json> <schema.json> <out.json>

engine_raw.json は claude -p --output-format json の出力である．
構造化出力は structured_output に入るが，取れない場合は result フィールドの
本文から JSON を取り出すことを試みる（取りこぼしを調査可能にするため）．
検証に通らなければ終了コード 1 を返す．
"""
import json
import re
import sys


def extract(raw):
    """engine_raw.json から結果オブジェクトを取り出す．"""
    if isinstance(raw.get("structured_output"), dict):
        return raw["structured_output"], "structured_output"

    text = raw.get("result")
    if isinstance(text, str) and text.strip():
        # 素の JSON，あるいはコードフェンス内の JSON を試す
        for candidate in (text, *re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)):
            try:
                obj = json.loads(candidate.strip())
            except Exception:
                continue
            if isinstance(obj, dict):
                return obj, "result 本文からの抽出"
    return None, None


def main():
    raw_path, schema_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        raw = json.load(open(raw_path, encoding="utf-8"))
    except Exception as exc:
        print(f"検証失敗: {raw_path} を読めない: {exc}", file=sys.stderr)
        return 1

    schema = json.load(open(schema_path, encoding="utf-8"))
    required = schema["required"]
    allowed = set(schema["properties"])

    obj, source = extract(raw)
    if obj is None:
        print("検証失敗: 結果オブジェクトを取り出せなかった", file=sys.stderr)
        return 1

    missing = [k for k in required if k not in obj]
    if missing:
        print(f"検証失敗: 必須キーが欠けている: {', '.join(missing)}", file=sys.stderr)
        return 1

    extra = [k for k in obj if k not in allowed]
    if extra:
        print(f"検証失敗: 未定義のキーがある: {', '.join(extra)}", file=sys.stderr)
        return 1

    status = obj.get("status")
    if status not in schema["properties"]["status"]["enum"]:
        print(f"検証失敗: status が不正である: {status!r}", file=sys.stderr)
        return 1

    # 該当しない項目は空文字列に揃える
    out = {k: ("" if obj.get(k) is None else str(obj.get(k))) for k in required}
    json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    if source != "structured_output":
        print(f"注意: 構造化出力ではなく「{source}」から結果を取得した", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
