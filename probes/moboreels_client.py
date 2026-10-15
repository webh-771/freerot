#!/usr/bin/env python3
"""moboreels.dramafren.org reference client (see moboreels.md).

JSON on the CF-protected origin (`?api_route=`) -> cf_clearance+UA required.
`video` returns a direct signed MP4 on cdnvideo.cdreader.com (Tencent EdgeOne, CF-free,
no headers, `t=` hex expiry ~1h). Locked episodes resolve too. Subtitles are separate SRT.
"""
import sys
from _cf_session import http, q

HOST = "moboreels.dramafren.org"
BASE = f"https://{HOST}/"
# channels/list (home feed) only work for these; search/detail/video work for all 19 UI langs
FEED_LANGS = ["en", "id", "pt", "th", "tr"]
ALL_LANGS = ["en", "id", "zh", "RTW", "es", "pt", "fr", "ru", "it", "ja", "ar", "th", "vi", "ko",
             "fil", "de", "hi", "ms", "tr"]


def _api(route, lang="en", **params):
    return http(BASE + "?" + q({"api_route": route, "lang": lang, **params}), cf_host=HOST)


def channels(lang="en"):
    return [c for c in _api("channels", lang)["data"]["channels"] if c["channelType"] == 2]


def feed(page=1, lang="en", channel_id=None):
    """Home feed = fixed sections of one channel; NO paging (page>1 -> empty)."""
    if page > 1:
        return {"sections": [], "has_more": False}
    channel_id = channel_id or channels(lang)[0]["channelId"]
    secs = _api("list", lang, channelId=channel_id).get("data", {}).get("sections", [])
    return {"sections": [{"title": s["title"], "items": s["series"]} for s in secs], "has_more": False}


def search(query, page=1, lang="en"):
    d = _api("search", lang, q=query, pageNo=page)["data"]
    return {"items": d["items"], "total": d["total"],
            "has_more": d["pageNo"] * d["pageSize"] < d["total"]}


def detail(series_id, lang="en"):
    info = _api("detail", lang, id=series_id)["data"]
    eps = _api("episodes", lang, id=series_id)["data"]["items"]
    return {"info": info, "episodes": eps}


def stream(series_id, ep, lang="en"):
    v = _api("video", lang, id=series_id, episNum=ep)
    v = v.get("data", v)
    url = v["mediaUrl"]
    h264 = [m for m in v.get("episMedia") or [] if m.get("codec") == "h264"]
    if h264:  # the site prefers highest-res h264 when the list is present
        url = sorted(h264, key=lambda m: -m["resolution"])[0]["mediaUrl"]
    return {"url": url, "format": "mp4"}


def subtitle(epis_id, lang="en"):
    """SRT text (preceded by a few [font-size=..] style lines the site strips)."""
    st, ct, b = http(BASE + "?" + q({"api_route": "subtitle", "lang": lang, "episId": epis_id}),
                     cf_host=HOST, raw=True)
    return b.decode("utf-8", "replace")


if __name__ == "__main__":
    print("channels:", [(c["channelId"], c["title"]) for c in channels()])
    f = feed(1)
    print("feed sections:", [(s["title"], len(s["items"])) for s in f["sections"]])
    s = search(sys.argv[1] if len(sys.argv) > 1 else "love")
    print("search:", s["total"], "has_more", s["has_more"], [x["seriesName"] for x in s["items"][:3]],
          "| p2:", len(search("love", 2)["items"]))
    sid = f["sections"][0]["items"][0]["seriesId"]
    d = detail(sid)
    eps = d["episodes"]
    print("detail:", d["info"]["seriesName"], "| eps:", len(eps), "| free:", d["info"]["freeEpisodes"])
    for e in (eps[0], eps[-1]):
        st = stream(sid, e["episNum"])
        status, ctype, b = http(st["url"], raw=True, rng="bytes=0-65535")
        print(f"ep{e['episNum']} lock={e['isLock']} {status} {ctype} {len(b)}B",
              "ftyp" if b[4:8] == b"ftyp" else b[:16])
    print("subtitle head:", subtitle(eps[-1]["episId"])[:120].replace("\n", " | "))
