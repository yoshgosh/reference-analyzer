#!/usr/bin/env python3
"""Notion への登録（REST API）．

使い方 :
  notion.py tags                          現在のタグの選択肢を1行に1つ出力する
  notion.py register <result.json> <dir>  ページを作成し，URL を出力する
  notion.py discard <dir>                 作りかけのページをゴミ箱へ移す（ref --resume が使う）

register は検証済みの result.json（lib/validate_result.py の出力）を受け取る．
画像は <dir>/<image_file> にある．作成したページは <dir>/notion_page.json に記録する．

環境変数 NOTION_TOKEN と NOTION_DATA_SOURCE_ID を使う．標準ライブラリだけで書いている．

手順と順序の理由（実測で確認済み，2026-10-14，Notion-Version 2026-03-11）:

  1. 画像をアップロードする     ページより先に行う．失敗してもページが残らない
  2. 新しいタグを追加する       色を指定するため．未登録の値をページ作成で送ると
                                 選択肢は自動で追加されるが，色が無作為になる
  3. ページを作成する           本文は markdown で渡す．入れ子の箇条書きと数式も通る
  4. 画像ブロックを先頭に置く   markdown 内の file-upload:// は空の外部画像になるため，
                                 position=start で後から差し込む

4 で失敗したらページをゴミ箱へ移す．「ページはあるが未完成」の状態を残さないためで，
こうしておけば失敗は常に「ページ未作成」となり，そこから続けられる（ref --resume）．
"""
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

API = "https://api.notion.com/v1"
VERSION = "2026-03-11"

# プロパティ名と型．データベースがこれと一致しなければ登録しない
SCHEMA = {
    "Citation Key": "title",
    "Title": "rich_text",
    "DOI": "url",
    "Summary": "rich_text",
    "Tag": "multi_select",
    "Author": "rich_text",
    "Year": "number",
    "Publication": "rich_text",
    "Citation": "rich_text",
    "Rating": "select",
}

TEXT_LIMIT = 2000  # rich_text の1要素あたりの上限（文字数）

IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
               ".gif": "image/gif", ".webp": "image/webp"}


class NotionError(Exception):
    pass


def call(method, path, body=None, raw=None, content_type="application/json"):
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
    headers = {"Authorization": "Bearer " + os.environ["NOTION_TOKEN"],
               "Notion-Version": VERSION}
    if data is not None:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read()).get("message", "")
        except Exception:
            detail = ""
        raise NotionError(f"{method} {path.split('?')[0]} が {exc.code} で拒否された: {detail}")
    except urllib.error.URLError as exc:
        raise NotionError(f"{method} {path.split('?')[0]} に接続できなかった: {exc.reason}")


def data_source():
    """データソースを取得し，スキーマが想定どおりかを確かめる．"""
    ds = call("GET", f"/data_sources/{os.environ['NOTION_DATA_SOURCE_ID']}")
    props = ds.get("properties", {})
    wrong = [f"{name}（{kind}）" for name, kind in SCHEMA.items()
             if props.get(name, {}).get("type") != kind]
    if wrong:
        raise NotionError("データベースのプロパティが想定と違う: " + ", ".join(wrong))
    return ds


def options(ds, name):
    prop = ds["properties"][name]
    return prop[prop["type"]]["options"]


def tag_names():
    """現在のタグの選択肢の名前（指示文に埋め込む）．"""
    return [o["name"] for o in options(data_source(), "Tag")]


def text(value):
    """rich_text の配列．長い値（BibTeX 等）は上限ごとに分ける．"""
    return [{"type": "text", "text": {"content": value[i:i + TEXT_LIMIT]}}
            for i in range(0, len(value), TEXT_LIMIT)]


def properties(r):
    return {
        "Citation Key": {"title": text(r["citation_key"])},
        "Title": {"rich_text": text(r["title"])},
        "DOI": {"url": r["doi"] or None},
        "Summary": {"rich_text": text(r["summary"])},
        "Tag": {"multi_select": [{"name": t} for t in r["tags"]]},
        "Author": {"rich_text": text(r["author"])},
        "Year": {"number": int(r["year"]) if r["year"] else None},
        "Publication": {"rich_text": text(r["publication"])},
        "Citation": {"rich_text": text(r["citation"])},
        "Rating": {"select": {"name": r["rating"]} if r["rating"] else None},
    }


def upload(path):
    """画像をアップロードし，file_upload の id を返す．"""
    name = os.path.basename(path)
    ctype = IMAGE_TYPES[os.path.splitext(name)[1].lower()]
    fu = call("POST", "/file_uploads", {"filename": name, "content_type": ctype})
    boundary = uuid.uuid4().hex
    with open(path, "rb") as fh:
        payload = fh.read()
    body = (f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
            f"Content-Type: {ctype}\r\n\r\n").encode() + payload + f"\r\n--{boundary}--\r\n".encode()
    sent = call("POST", f"/file_uploads/{fu['id']}/send", raw=body,
                content_type=f"multipart/form-data; boundary={boundary}")
    if sent.get("status") != "uploaded":
        raise NotionError(f"画像のアップロードが完了しなかった（status={sent.get('status')}）")
    return fu["id"]


def add_tags(ds, new_tags):
    """新しいタグを色付きで追加する．既存の選択肢は id ごと全部送る（省くと削除される）．"""
    current = options(ds, "Tag")
    known = {o["name"] for o in current}
    added = [t for t in new_tags if t["name"] not in known]
    if not added:
        return []
    keep = [{"id": o["id"], "name": o["name"], "color": o["color"]} for o in current]
    call("PATCH", f"/data_sources/{os.environ['NOTION_DATA_SOURCE_ID']}",
         {"properties": {"Tag": {"multi_select": {"options": keep + added}}}})
    return [t["name"] for t in added]


def register(result_path, record_dir):
    with open(result_path, encoding="utf-8") as fh:
        r = json.load(fh)

    ds = data_source()
    ratings = {o["name"] for o in options(ds, "Rating")}
    if r["rating"] and r["rating"] not in ratings:
        raise NotionError(f"Rating の値が選択肢に無い: {r['rating']!r}")

    upload_id = upload(os.path.join(record_dir, r["image_file"])) if r["image_file"] else None

    added = add_tags(ds, r["new_tags"])
    if added:
        print("タグを追加した: " + ", ".join(added), file=sys.stderr)

    page = call("POST", "/pages", {
        "parent": {"type": "data_source_id", "data_source_id": os.environ["NOTION_DATA_SOURCE_ID"]},
        "properties": properties(r),
        "markdown": r["body"],
    })

    if upload_id:
        image = {"type": "image", "image": {
            "type": "file_upload", "file_upload": {"id": upload_id},
            "caption": text(r["image_caption"]),
        }}
        try:
            call("PATCH", f"/blocks/{page['id']}/children",
                 {"children": [image], "position": {"type": "start"}})
        except NotionError as exc:
            try:
                call("PATCH", f"/pages/{page['id']}", {"in_trash": True})
            except NotionError:
                # ゴミ箱へ移せなければページが残る．URL を記録して人に削除を委ねる
                record(record_dir, page, complete=False)
                print(page["url"])
                raise NotionError(f"画像を挿入できず，ページも削除できなかった: {exc}")
            raise NotionError(f"画像を挿入できなかった（作成したページはゴミ箱へ移した）: {exc}")

    record(record_dir, page, complete=True)
    print(page["url"])


def discard(record_dir):
    """作りかけ（complete: false）のページをゴミ箱へ移し，notion_page.json を消す．
    register がゴミ箱へ移すことにも失敗した場合の後始末である．"""
    path = os.path.join(record_dir, "notion_page.json")
    with open(path, encoding="utf-8") as fh:
        page = json.load(fh)
    if page.get("complete"):
        raise NotionError(f"完成したページは捨てない: {page['url']}")
    call("PATCH", f"/pages/{page['id']}", {"in_trash": True})
    os.remove(path)
    print(f"作りかけのページをゴミ箱へ移した: {page['url']}", file=sys.stderr)


def record(record_dir, page, complete):
    with open(os.path.join(record_dir, "notion_page.json"), "w", encoding="utf-8") as fh:
        json.dump({"id": page["id"], "url": page["url"], "complete": complete}, fh, indent=2)


def main():
    try:
        if sys.argv[1:2] == ["tags"]:
            for name in tag_names():
                print(name)
        elif sys.argv[1:2] == ["register"] and len(sys.argv) == 4:
            register(sys.argv[2], sys.argv[3])
        elif sys.argv[1:2] == ["discard"] and len(sys.argv) == 3:
            discard(sys.argv[2])
        else:
            print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
            return 2
    except (NotionError, OSError) as exc:
        print(exc, file=sys.stderr)
        return 1
    except KeyError as exc:
        print(f"環境変数または結果の項目が無い: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
