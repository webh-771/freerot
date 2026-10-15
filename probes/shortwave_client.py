#!/usr/bin/env python3
"""shortwave.dramafren.org reference client (see shortwave.md).

JSON on the CF-protected origin (`?api_route=`) -> cf_clearance+UA required.
`unlock` returns base64(play URL) = https://api.shortswave.com/v1/play/<chapter_id>/v.m3u8?auth_key=...
which is CF-free (plain HTTP, no headers), plain HLS, HEVC 720p .ts segments on v.shortswave.com
(GCS signed, 6h). Locked (is_free=0) episodes unlock too.
"""
import base64, sys
from _cf_session import http, q

HOST = "shortwave.dramafren.org"
BASE = f"https://{HOST}/"
LANGS = ["en", "in", "id", "ms", "th", "es", "fr", "de", "ar", "tr", "ru", "pt", "ja", "ko"]


def _api(route, lang="en", **params):
    return http(BASE + "?" + q({"api_route": route, "lang": lang, **params}), cf_host=HOST)


def feed(page=1, lang="en"):
    """24 per page, newest first; ~100 pages for en. has_more = page returned 24 items."""
    items = _api("list", lang, page=page).get("dramas", [])
    return {"items": items, "has_more": len(items) >= 24}


def search(query, page=1, lang="en"):
    """Max 20 results, paging ignored (page 2 == page 1)."""
    if page > 1:
        return []
    return _api("search", lang, q=query, page=1).get("dramas", [])


def detail(drama_id, lang="en"):
    return _api("detail", lang, id=drama_id)


def unlock(drama_id, chapter_id, lang="en"):
    return _api("unlock", lang, drama_id=drama_id, chapter_id=chapter_id)


def stream(drama_id, ep, lang="en"):
    d = detail(drama_id, lang)
    e = next(x for x in d["episodes"] if x["index"] == ep)
    u = unlock(drama_id, e["chapter_id"], lang)["data"]
    url = base64.b64decode(u["play_url_encoded"]).decode()
    subs = [{"lang": s.get("language"), "url": s.get("url")} for s in (u.get("sublist") or [])]
    return {"url": url, "format": "hls", "is_free": e["is_free"], "subtitles": subs,
            "duration": u.get("chapter_duration")}


if __name__ == "__main__":
    f = feed(1)
    print("feed p1:", len(f["items"]), "| p100:", len(feed(100)["items"]), "| p101:", len(feed(101)["items"]))
    s = search(sys.argv[1] if len(sys.argv) > 1 else "love")
    print("search:", len(s), [x["title"] for x in s[:3]])
    d = detail(f["items"][0]["id"])
    eps = d["episodes"]
    print("detail:", d["drama"]["title"], "| eps:", len(eps), "| free:", sum(e["is_free"] for e in eps))
    for ep in (1, len(eps)):
        st = stream(d["drama"]["id"], ep)
        status, ctype, m3u8 = http(st["url"], raw=True)
        seg = next(l for l in m3u8.decode().splitlines() if l.startswith("http"))
        s2, c2, b = http(seg, raw=True, rng="bytes=0-65535")
        print(f"ep{ep} free={st['is_free']} m3u8 {status} {ctype} | seg {s2} {len(b)}B sync=0x{b[0]:02x}")
