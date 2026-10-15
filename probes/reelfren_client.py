#!/usr/bin/env python3
"""ReelFren (reelfren.com) reference client.

KEY FINDING: only the website (reelfren.com HTML/JS) is behind the Cloudflare
challenge. The JSON backend https://api.reelfren.com is NOT challenged: plain
HTTP GET with any (or no) User-Agent returns JSON. No tokens, signatures,
cookies or encryption. The media hosts are also plain (no Referer needed).

Endpoints (all GET, all on https://api.reelfren.com):
  /api/home    ?offset=N&lang=en[&provider=P][&category=C][&feed=F]  -> {"offset":N,"data":[Drama]}
  /api/search  ?q=Q&lang=en&offset=N[&provider=P]                     -> {"query","count","hasMore","data":[Drama]}
  /api/detail  ?provider=P&id=ID&lang=en                              -> Drama + "videos":[{episode,duration,vid,available}]
  /api/video   ?provider=P&id=ID&ep=N&lang=en&server=1&cv=v21         -> {videoUrl,qualityList,subtitles,locked,...}
Relative URLs in responses: "/api/proxy/..." -> https://proxy.dramafren.org, other "/api/..." -> https://api.reelfren.com

usage: python3 reelfren_client.py [query]
"""
import sys, time, re
from urllib.parse import urljoin
import requests

API = "https://api.reelfren.com"
PROXY = "https://proxy.dramafren.org"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"

_s = requests.Session()
_s.headers.update({"User-Agent": UA, "Accept": "application/json"})


class Locked(Exception):
    """Episode not resolvable (backend 502 / locked=true / no URL)."""


def abs_url(u):
    """Mirror of the site's backendApiAssetUrl(): resolve relative backend URLs."""
    if not u:
        return u
    if u.startswith("/api/proxy/"):
        return PROXY + u
    if u.startswith("/api/"):
        return API + u
    return u


def _get(path, params, retries=2, timeout=60):
    last = None
    for i in range(retries + 1):
        r = _s.get(API + path, params=params, timeout=timeout)
        if r.status_code == 200:
            return r.json()
        last = r
        if r.status_code in (502, 503, 504, 520, 522, 524) and i < retries:
            time.sleep(1.5 * (i + 1))
            continue
        break
    raise requests.HTTPError(f"{path} {params} -> HTTP {last.status_code}: {last.text[:120]}", response=last)


def feed(page=0, provider=None, category=None, feed_name=None, lang="en"):
    """Home/explore listing. page = 0,1,2... (the API calls it `offset`, it is a PAGE index).
    Without provider: ~1900 mixed items on page 0, ~400-450 per later page.
    With provider: usually 20 per page (wetv/filmbox/vibeshort/blinkdrama/storyreel return
    everything on page 0 and [] afterwards; dramabox ignores paging)."""
    p = {"offset": str(page), "lang": lang}
    if provider:
        p["provider"] = provider
    if feed_name:
        p["feed"] = feed_name
    if category:
        p["category"] = category
    return _get("/api/home", p)["data"]


def search(q, page=0, provider=None, lang="en"):
    """Unified search. Returns dict {query,count,hasMore,data}. page = 0,1,2..."""
    p = {"q": q, "lang": lang, "offset": str(page)}
    if provider:
        p["provider"] = provider
    return _get("/api/search", p, timeout=90)


def detail(provider, id, lang="en"):
    """Drama metadata + episode list. videos[i] = {episode, duration, vid, available}.
    Placeholder episodes (vid == str(episode) and duration == 0) are usually paywalled
    upstream and /api/video returns 502 for them."""
    return _get("/api/detail", {"provider": provider, "id": id, "lang": lang})


def stream(provider, id, ep, lang="en", server="1", refresh=False):
    """Resolve one episode. Returns {url, format, qualities:[{label,url,format}], subtitles:[{label,url,srclang}], raw}.
    Raises Locked if the backend cannot resolve it."""
    p = {"provider": provider, "id": id, "ep": str(ep), "lang": lang, "server": str(server), "cv": "v21"}
    if refresh:
        p["refresh"] = "1"
        p["rt"] = str(int(time.time() * 1000))
    try:
        j = _get("/api/video", p, retries=1)
    except requests.HTTPError as e:
        if e.response is not None and e.response.status_code == 502:
            raise Locked(f"{provider}/{id} ep{ep}: backend 502 (locked/unavailable upstream)")
        raise
    quals = [{**q, "url": abs_url(q.get("url")), "fallbackUrl": abs_url(q.get("fallbackUrl"))}
             for q in (j.get("qualityList") or []) if q.get("url")]
    url = abs_url(j.get("videoUrl")) or (quals[0]["url"] if quals else None)
    if not url:
        raise Locked(f"{provider}/{id} ep{ep}: locked={j.get('locked')} no url")
    fmt = next((q.get("format") for q in quals if q["url"] == url and q.get("format")), None) \
        or (quals[0].get("format") if quals else None)
    if not fmt:
        fmt = "hls" if ".m3u8" in url or "m3u8" in url.lower() else "mp4"
    subs = [{**s, "url": abs_url(s.get("url"))} for s in (j.get("subtitles") or [])]
    return {"url": url, "format": fmt, "qualities": quals, "subtitles": subs, "raw": j}


def verify(url, fmt=None):
    """Fetch the start of the media (following one HLS master->variant->segment hop) and
    return a short description proving real bytes come back. No special headers needed."""
    if fmt == "hls" or ".m3u8" in url:
        t = _s.get(url, timeout=40).text
        assert t.startswith("#EXTM3U"), f"not an m3u8: {t[:80]!r}"
        enc = re.findall(r"#EXT-X-KEY:[^\n]*", t)
        lines = [l.strip() for l in t.splitlines() if l.strip() and not l.startswith("#")]
        if "#EXT-X-STREAM-INF" in t:
            url = urljoin(url, lines[0])
            t = _s.get(url, timeout=40).text
            enc += re.findall(r"#EXT-X-KEY:[^\n]*", t)
            lines = [l.strip() for l in t.splitlines() if l.strip() and not l.startswith("#")]
        seg = urljoin(url, lines[0])
        r = _s.get(seg, headers={"Range": "bytes=0-4095"}, timeout=40)
        return f"HLS ok, {len(lines)} segs, key={'NONE' if not enc else enc[0][:60]}; seg0 HTTP {r.status_code} {len(r.content)}B head={r.content[:8]!r}"
    r = _s.get(url, headers={"Range": "bytes=0-4095"}, timeout=40)
    return f"FILE HTTP {r.status_code} {r.headers.get('content-type')} {r.headers.get('content-range')} head={r.content[:12]!r}"


if __name__ == "__main__":
    q = sys.argv[1] if len(sys.argv) > 1 else "revenge"
    items = feed(0, provider="netshort")
    print(f"feed(netshort) page0: {len(items)} items, first: {items[0]['provider']}/{items[0]['id']} {items[0]['title']!r}")
    mixed = feed(0)
    print(f"feed() page0 mixed: {len(mixed)} items from {len({i['provider'] for i in mixed})} providers")
    s = search(q, provider="dramabox")
    print(f"search({q!r}, dramabox): count={s['count']} hasMore={s['hasMore']} got={len(s['data'])}")

    for prov in ["netshort", "dramabox", "wetv", "vibeshort", "reelshort"]:
        it = feed(0, provider=prov)[0]
        d = detail(prov, it["id"])
        n = d["episodes"] or len(d["videos"])
        real = [v["episode"] for v in d["videos"] if not (v["vid"] == str(v["episode"]) and not v["duration"])]
        for ep in sorted({1, n}):
            try:
                st = stream(prov, it["id"], ep)
                print(f"[{prov}] {d['title'][:40]!r} ep{ep}/{n} {st['format']} subs={len(st['subtitles'])} -> {verify(st['url'], st['format'])}")
            except Locked as e:
                print(f"[{prov}] ep{ep}/{n} LOCKED: {e} (last non-placeholder ep = {max(real) if real else '?'})")
