#!/usr/bin/env python3
"""AI の最終出力を検証し，正規化した result.json と代表画像を記録ディレクトリへ書き出す．

使い方 : validate_result.py <engine_raw.json> <schema.json> <作業ディレクトリ> <記録ディレクトリ>

engine_raw.json は claude -p --output-format json の出力である．
構造化出力は structured_output に入るが，取れない場合は result フィールドの
本文から JSON を取り出すことを試みる（取りこぼしを調査可能にするため）．

citation_key は正規化して書き出す（改名と Notion の Citation Key にそのまま使う）．

代表画像は記録ディレクトリへ image.<拡張子> としてコピーし，image_file をその名前に
書き換える．作業ディレクトリは成功時に消えるが，記録は残るので，登録だけを
やり直せる（ref --register）．
検証に通らなければ，理由を標準エラーの最後の行に書いて終了コード 1 を返す．
"""
import json
import os
import re
import shutil
import sys
import unicodedata

IMAGE_MAX_BYTES = 20 * 1024 * 1024  # Notion の1回のアップロードの上限

# 先頭のバイト列 → 拡張子．拡張子ではなく中身で判定する
MAGIC = [(b"\x89PNG\r\n\x1a\n", ".png"), (b"\xff\xd8\xff", ".jpg"),
         (b"GIF87a", ".gif"), (b"GIF89a", ".gif")]


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


def normalize(obj, schema):
    """型を揃える．文字列項目の null は空文字列に，配列項目の null は空配列にする．"""
    out = {}
    for key, spec in schema["properties"].items():
        value = obj.get(key)
        if spec["type"] == "array":
            out[key] = value if isinstance(value, list) else []
        else:
            out[key] = "" if value is None else str(value).strip()
    out["tags"] = [str(t).strip() for t in out["tags"] if str(t).strip()]
    out["new_tags"] = [t for t in out["new_tags"] if isinstance(t, dict)]
    return out


def normalize_key(key):
    """ASCII 英数字と . _ - だけを残す．
    先に NFKD 分解して結合文字を落とすので，Müller は Muller になる（Mller にはならない）．"""
    s = unicodedata.normalize("NFKD", key)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return "".join(c for c in s if c.isascii() and (c.isalnum() or c in "._-"))


def key_is_sane(key):
    """非ASCII の著者名がローマ字化されずに落ちると数字だけのキーが残るため，英字を必須とする．"""
    return len(key) >= 3 and any(c.isascii() and c.isalpha() for c in key)


def image_ext(path):
    with open(path, "rb") as fh:
        head = fh.read(12)
    for magic, ext in MAGIC:
        if head.startswith(magic):
            return ext
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return ".webp"
    return None


def check_content(r, raw_key, schema, work_dir, record_dir):
    """登録に使う内容を確かめる．問題があれば理由を返す．"""
    if not key_is_sane(r["citation_key"]):
        return (f"citation_key が妥当でない（正規化後: {r['citation_key']!r} / "
                f"正規化前: {raw_key!r}）．非ASCII名のローマ字化に失敗した可能性がある")
    if r["year"] and not re.fullmatch(r"\d{4}", r["year"]):
        return f"year が西暦4桁でない: {r['year']!r}"
    if r["rating"] not in schema["properties"]["rating"]["enum"]:
        return f"rating が不正である: {r['rating']!r}"
    if not r["body"]:
        return "body（要約本文）が空である"

    bad = [t for t in r["tags"] if "," in t]
    if bad:
        return f"タグにカンマを含められない: {bad}"
    colors = schema["properties"]["new_tags"]["items"]["properties"]["color"]["enum"]
    for t in r["new_tags"]:
        if t.get("name") not in r["tags"]:
            return f"new_tags の {t.get('name')!r} が tags に無い"
        if t.get("color") not in colors:
            return f"new_tags の色が不正である: {t.get('color')!r}"

    if r["image_file"]:
        work = os.path.realpath(work_dir)
        src = os.path.realpath(os.path.join(work, r["image_file"]))
        if not src.startswith(work + os.sep):
            return f"image_file が作業ディレクトリの外を指している: {r['image_file']!r}"
        if not os.path.isfile(src):
            return f"image_file が見つからない: {r['image_file']!r}"
        if os.path.getsize(src) > IMAGE_MAX_BYTES:
            return f"画像が大きすぎる（{os.path.getsize(src) // 1048576}MB）: {r['image_file']!r}"
        ext = image_ext(src)
        if ext is None:
            return f"image_file が PNG・JPEG・GIF・WebP の画像でない: {r['image_file']!r}"
        shutil.copyfile(src, os.path.join(record_dir, "image" + ext))
        r["image_file"] = "image" + ext
    return None


def main():
    raw_path, schema_path, work_dir, record_dir = sys.argv[1:5]
    out_path = os.path.join(record_dir, "result.json")

    try:
        raw = json.load(open(raw_path, encoding="utf-8"))
    except Exception as exc:
        print(f"検証失敗: {raw_path} を読めない: {exc}", file=sys.stderr)
        return 1

    schema = json.load(open(schema_path, encoding="utf-8"))
    allowed = set(schema["properties"])

    obj, source = extract(raw)
    if obj is None:
        print("検証失敗: 結果オブジェクトを取り出せなかった", file=sys.stderr)
        return 1

    missing = [k for k in schema["required"] if k not in obj]
    if missing:
        print(f"検証失敗: 必須キーが欠けている: {', '.join(missing)}", file=sys.stderr)
        return 1

    extra = [k for k in obj if k not in allowed]
    if extra:
        print(f"検証失敗: 未定義のキーがある: {', '.join(extra)}", file=sys.stderr)
        return 1

    if obj.get("status") not in schema["properties"]["status"]["enum"]:
        print(f"検証失敗: status が不正である: {obj.get('status')!r}", file=sys.stderr)
        return 1

    r = normalize(obj, schema)
    raw_key = r["citation_key"]
    r["citation_key"] = normalize_key(raw_key)

    # failed のときは登録しないので，内容は確かめずにそのまま記録する
    if r["status"] == "success":
        problem = check_content(r, raw_key, schema, work_dir, record_dir)
        if problem:
            print(f"検証失敗: {problem}", file=sys.stderr)
            return 1

    json.dump(r, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    if source != "structured_output":
        print(f"注意: 構造化出力ではなく「{source}」から結果を取得した", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
