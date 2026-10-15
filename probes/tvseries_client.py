#!/usr/bin/env python3
"""tvseries.dramafren.org reference client (see tvseries.md).

CF-FREE: plain HTTP works for every `?api_route=` call. Content = MovieBox (aoneroom)
movies / TV series, NOT short dramas. As of 2026-09-23 the site's upstream is failing: only
server-cached responses come back (uncached -> {"error":"Failed to fetch data and no cache
available"}), paging (tabfeed) always errors, and the video proxy api.filmdramaid.xyz returns
403 for every episode (also inside a real browser). This client documents the API; the
demo reports the playback failure explicitly.
"""
import base64, json, sys
from _cf_session import http, q

BASE = "https://tvseries.dramafren.org/"
LANGS = ["en", "id", "ar", "fr", "hi", "ur", "fil"]


def _get(route, lang="en", **params):
    return http(BASE + "?" + q({"api_route": route, "lang": lang, **params}))


def _post(route, body, lang="en"):
    return http(BASE + "?" + q({"api_route": route, "lang": lang}), method="POST", body=body)


def tabs(lang="en"):
    return _get("tablist", lang).get("data", [])


def feed(page=1, lang="en", key="Latest", type_="SORT BY", position=2):
    if page == 1:
        d = _post("tabdata", {"key": key, "type": type_, "position": position}, lang)
    else:  # what the site does; currently always returns the "no cache" error
        d = _post("tabfeed", {"page_info": {"type": type_, "key": key, "positionIndex": position,
                                            "page": str(page - 1), "nextPage": str(page), "perPage": 18}}, lang)
    if "data" not in d:
        return {"items": [], "has_more": False, "error": d.get("error")}
    b = d["data"]["book"]
    items = b["list"] if isinstance(b, dict) else b
    return {"items": items, "has_more": d["data"]["page_info"].get("has_more", False),
            "page_info": d["data"]["page_info"]}


def search(query, page=1, lang="en"):
    if page > 1:
        return {"items": [], "has_more": False, "error": "paging broken upstream"}
    d = _post("search", {"keyword": query}, lang)
    if "data" not in d:
        return {"items": [], "has_more": False, "error": d.get("error")}
    return {"items": d["data"]["book"], "total": d["data"]["page_info"].get("totalCount")}


def decode_id(i):
    """id = base64(JSON {"sid": MovieBox subjectId, "pid": MovieBox detailPath})."""
    return json.loads(base64.b64decode(i + "=" * (-len(i) % 4)))


def detail(item_id, lang="en"):
    d = _get("detail", lang, id=item_id)
    return d.get("data") or {"error": d.get("error")}


def stream(item_id, ep, lang="en"):
    """ep is 1-based. Returns the proxied mp4 + the decoded MovieBox CDN URL."""
    ch = detail(item_id, lang)["chapters"][ep - 1]
    p = ch["videoPath"]
    raw = None
    if "/video/" in p:
        b = p.split("/video/", 1)[1]
        raw = base64.urlsafe_b64decode(b + "=" * (-len(b) % 4)).decode()
    return {"url": p, "upstream_url": raw, "format": "mp4",
            "subtitles": [{"lang": s["language"], "name": s["display_name"],
                           "url": BASE + "?" + q({"api_route": "subtitle", "url": s["subtitle"]})}
                          for s in ch.get("subtitle", [])]}


if __name__ == "__main__":
    print("tabs:", len(tabs()), "types:", sorted({t["type"] for t in tabs()}))
    f = feed(1)
    print("feed p1:", len(f["items"]), f.get("page_info", {}).get("totalCount"), "| p2:", feed(2).get("error"))
    s = search(sys.argv[1] if len(sys.argv) > 1 else "love")
    print("search:", s.get("total"), [x["name"] for x in s["items"][:3]])
    for it in f["items"][:6]:
        d = detail(it["id"])
        if "chapters" not in d:
            print("detail", it["name"], "->", d); continue
        print("detail:", d["book"]["name"], decode_id(it["id"]), "| chapters:", len(d["chapters"]))
        st = stream(it["id"], 1)
        status, ctype, b = http(st["url"], raw=True, rng="bytes=0-65535",
                                headers={"Referer": BASE})
        print("  ep1 proxy:", status, ctype, b[:40])
        print("  upstream url sign time t=", st["upstream_url"].rsplit("t=", 1)[-1])
        break
