#!/usr/bin/env python3
"""microdrama.dramafren.org reference client (see microdrama.md).

All JSON lives on the CF-protected origin (`?api_route=`), so we attach cf_clearance+UA
(see _cf_session.py). Video URLs are direct signed MP4s on reeltv.janzhoutec.com
(CF-free, no headers needed, valid ~2 days).
"""
import sys
from _cf_session import http, q

HOST = "microdrama.dramafren.org"
BASE = f"https://{HOST}/"
LANGS = ["en", "id", "th", "es", "pt", "ja", "ko"]


def _api(route, lang="en", **params):
    return http(BASE + "?" + q({"api_route": route, "lang": lang, **params}), cf_host=HOST)


def feed(page=1, lang="en"):
    """Server IGNORES `page`: every page returns the same newest 50. Only page 1 is real."""
    if page > 1:
        return {"items": [], "has_more": False, "total": None}
    d = _api("list", lang, page=1)
    return {"items": d.get("dramas", []), "has_more": False, "total": d.get("total")}


def catalog(lang="en"):
    """Whole catalogue (e.g. 286 en titles) in one call: search with q=' ' matches everything."""
    return _api("search", lang, q=" ", page=1).get("dramas", [])


def search(query, page=1, lang="en"):
    """Returns ALL matches in one response; `page` ignored (page 2 == page 1)."""
    if page > 1:
        return []
    return _api("search", lang, q=query, page=1).get("dramas", [])


def detail(drama_id, lang="en"):
    """ids are per-language: use the same lang the id came from."""
    return _api("detail", lang, id=drama_id)


def stream(drama_id, ep, lang="en", quality="720P"):
    d = detail(drama_id, lang)
    e = next(x for x in d["episodes"] if x["index"] == ep)
    vids = e["videos"]
    v = next((x for x in vids if x["quality"] == quality), vids[0])
    return {"url": v["url"], "format": "mp4", "quality": v["quality"],
            "all": {x["quality"]: x["url"] for x in vids}}


if __name__ == "__main__":
    f = feed(1)
    print("feed p1:", len(f["items"]), "of total", f["total"], "| p2:", len(feed(2)["items"]))
    print("catalog:", len(catalog()))
    s = search(sys.argv[1] if len(sys.argv) > 1 else "ceo")
    print("search:", len(s), [x["title"] for x in s[:3]])
    d = detail(f["items"][0]["id"])
    n = len(d["episodes"])
    print("detail:", d["drama"]["title"], "| eps:", n)
    for ep in (1, n):
        st = stream(d["drama"]["id"], ep)
        status, ctype, b = http(st["url"], raw=True, rng="bytes=0-65535")
        print(f"ep{ep}", st["quality"], status, ctype, len(b), "bytes, ftyp" if b[4:8] == b"ftyp" else b[:16])
