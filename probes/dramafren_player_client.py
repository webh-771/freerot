#!/usr/bin/env python3
"""Reference client for the dramafren "player" mirrors: dramabox, goodshort, netshort, flickreels.

All four share one PHP template (see probes/template_dramafren_unlocked.md). Only stdlib is used.

    c = DramafrenClient("netshort")
    c.feed(1)            -> {"items":[Card...], "page":1, "pages":9, "has_more":True}
    c.search("love")     -> [Card...]                 (single page, no paging)
    c.detail(id)         -> {"id","title","cover","synopsis","tags","total","episodes":[{"ep","label"}]}
    c.stream(id, ep)     -> {"url","kind":"mp4"|"hls","qualities":[...],"subtitles":[...],"headers":{}}

`ep` is always the site's own ep value from detail()["episodes"][i]["ep"]
(GoodShort is 0-based, the others 1-based).

CF: dramabox HTML pages are Cloudflare-challenged. Pass cf_clearance + the EXACT User-Agent of the
browser/WebView that solved the challenge (cookie is bound to UA+IP; domain .dramafren.org covers all
subdomains). Everything else here is CF-free.
"""
import html as _html
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request

# python.org macOS builds ship without a CA bundle; fall back to the system one
_SSL = ssl.create_default_context(cafile="/etc/ssl/cert.pem") if os.path.exists("/etc/ssl/cert.pem") else None

DEFAULT_UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36")

SITES = {
    # html: base for home/search/detail/watch pages. html_extra: query suffix needed to pass the
    # cdn host's CF rule (netshort only lets whitelisted ?action= values through; an unknown-to-PHP
    # action falls through to normal page rendering).
    "dramabox":   dict(html="https://dramabox.dramafren.org", html_extra="", html_cf=True,
                       video=["https://cdn-dramabox.dramafren.org", "https://cdn-dramaboxv2.dramafren.org"]),
    "goodshort":  dict(html="https://cdn-goodshort.dramafren.org", html_extra="", html_cf=False,
                       video=["https://cdn-goodshort.dramafren.org"]),
    "netshort":   dict(html="https://cdn-netshort.dramafren.org", html_extra="&action=proxy_video", html_cf=False,
                       video=["https://cdn-netshort.dramafren.org", "https://cdn-netshortv2.dramafren.org"]),
    "flickreels": dict(html="https://cdn-flickreels.dramafren.org", html_extra="", html_cf=False,
                       video=["https://cdn-flickreels.dramafren.org"]),
}


class DramafrenError(Exception):
    pass


class DramafrenClient:
    def __init__(self, site, lang="en", cf_clearance=None, user_agent=None, timeout=45):
        if site not in SITES:
            raise ValueError(site)
        self.site, self.cfg, self.lang, self.timeout = site, SITES[site], lang, timeout
        self.cf_clearance = cf_clearance
        self.ua = user_agent or DEFAULT_UA

    # ---------------- http ----------------
    def _get_raw(self, url, accept, cf):
        h = {"User-Agent": self.ua, "Accept": accept}
        if cf and self.cf_clearance:
            h["Cookie"] = "cf_clearance=" + self.cf_clearance
        req = urllib.request.Request(url, headers=h)
        for attempt in range(3):  # backend is slow/flaky (goodshort watch page can take ~30 s)
            try:
                with urllib.request.urlopen(req, timeout=self.timeout, context=_SSL) as r:
                    return r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError:
                raise
            except (TimeoutError, OSError) as e:
                if attempt == 2:
                    raise DramafrenError(f"network error on {url}: {e}")

    def _get(self, url, accept="text/html", cf=False):
        try:
            return self._get_raw(url, accept, cf)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            if e.headers.get("cf-mitigated") == "challenge":
                raise DramafrenError(f"CF challenge on {url} (need cf_clearance + matching UA)")
            return body  # JSON error bodies (404/400) are still useful

    def _page(self, query, front=False):
        if front:  # CF-protected public host; needs cf_clearance + matching UA
            url = f"https://{self.site}.dramafren.org/index.php?{query}"
        else:
            url = f"{self.cfg['html']}/index.php?{query}{self.cfg['html_extra']}"
        t = self._get(url, cf=front or self.cfg["html_cf"])
        if "<title>Just a moment" in t:
            raise DramafrenError("CF challenge page returned")
        return t

    def _json(self, url):
        t = self._get(url, accept="application/json")
        try:
            return json.loads(t)
        except ValueError:
            raise DramafrenError(f"non-JSON from {url}: {t[:120]!r}")

    # ---------------- parsing ----------------
    @staticmethod
    def _txt(s):
        return _html.unescape(re.sub(r"<[^>]+>", " ", s or "")).strip()

    @classmethod
    def _cards(cls, t):
        out, seen = [], set()
        for href, inner in re.findall(r'<a href="(index\.php\?page=detail[^"]*)"[^>]*>(.*?)</a>', t, re.S):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(_html.unescape(href)).query)
            did = q.get("id", [""])[0]
            if not did or did in seen:
                continue
            seen.add(did)
            img = re.search(r'<img[^>]+src="([^"]+)"', inner)
            h3 = re.search(r"<h3[^>]*>(.*?)</h3>", inner, re.S)
            badge = re.search(r'<div class="absolute top-2 right-2[^"]*">(.*?)</div>', inner, re.S)
            tags = [cls._txt(x) for x in re.findall(r'<span class="text-\[10px\] bg-slate-700[^"]*">(.*?)</span>', inner)]
            b = cls._txt(badge.group(1)) if badge else ""
            m = re.search(r"(\d+)\s*EPS", b, re.I)
            out.append(dict(id=did, lang=q.get("lang", [None])[0], slug=q.get("slug", [None])[0],
                            title=cls._txt(h3.group(1)) if h3 else "",
                            cover=_html.unescape(img.group(1)) if img else None,
                            episodes=int(m.group(1)) if m else None, badge=b or None, tags=tags))
        return out

    # ---------------- public API ----------------
    def feed(self, page=1, front=None):
        """Global 'Recently Watched' list: 12 items/page, ~9-10 pages max.
        The list is stored PER HOST: the cdn-* twins show a shorter list (netshort 1 page, goodshort 3)
        than the public front host. front=None -> use the front host whenever cf_clearance is set."""
        if front is None:
            front = bool(self.cf_clearance)
        q = f"page=home&p_hist={page}" + (f"&lang={self.lang}" if self.site == "flickreels" else "")
        t = self._page(q, front=front)
        m = re.search(r"Page (\d+) of (\d+)", t)
        cur, pages = (int(m.group(1)), int(m.group(2))) if m else (page, page)
        has_more = bool(re.search(rf'p_hist={page + 1}\b[^>]*>\s*Next', t)) or cur < pages
        return dict(items=self._cards(t), page=cur, pages=pages, has_more=has_more)

    def search(self, q):
        t = self._page("page=search_result&q=" + urllib.parse.quote(q) + f"&lang={self.lang}")
        return self._cards(t)

    def detail(self, did, lang=None):
        lang = lang or self.lang
        q = f"page=detail&id={did}" + ("" if self.site == "netshort" else f"&lang={lang}")
        if self.site == "goodshort":
            q += "&sv=1"
        t = self._page(q)
        h1 = re.search(r"<h1[^>]*>(.*?)</h1>", t, re.S)
        if not h1:
            raise DramafrenError(f"detail {did}: no <h1> (bad id?)")
        cover = re.search(r'<img src="([^"]+)" class="w-full rounded-lg poster-shadow"', t)
        og = re.search(r'property="og:image" content="([^"]+)"', t)
        syn = re.search(r'<p class="text-slate-300 text-sm leading-relaxed mb-6">(.*?)</p>', t, re.S)
        tot = re.search(r"Total:\s*(\d+)\s*Eps", t)
        tags = re.search(r'<span class="bg-slate-700 text-slate-300 text-xs px-2 py-1 rounded">(.*?)</span>', t, re.S)
        eps, seen = [], set()
        for href, label in re.findall(r'<a href="(index\.php\?page=watch[^"]*)"[^>]*>\s*([^<]*?)\s*</a>', t):
            ep = urllib.parse.parse_qs(urllib.parse.urlparse(_html.unescape(href)).query).get("ep", [None])[0]
            if ep is None or ep in seen or label.lower().startswith("start"):
                continue
            seen.add(ep)
            eps.append(dict(ep=int(ep), label=label.strip()))
        return dict(id=str(did), title=self._txt(h1.group(1)),
                    cover=_html.unescape((cover or og).group(1)) if (cover or og) else None,
                    synopsis=self._txt(syn.group(1)) if syn else "",
                    tags=[s.strip() for s in self._txt(tags.group(1)).split(",")] if tags else [],
                    total=int(tot.group(1)) if tot else len(eps), episodes=eps)

    def stream(self, did, ep, server=None, lang=None):
        lang = lang or self.lang
        return getattr(self, "_stream_" + self.site)(str(did), int(ep), server, lang)

    # --- dramabox: GET cdn-dramabox/index.php?action=get_video&id&ep&lang&sv  (CF-free JSON)
    def _stream_dramabox(self, did, ep, server, lang):
        err = None
        for sv in ([server] if server else [1, 3, 2]):
            for base in self.cfg["video"]:
                j = self._json(f"{base}/index.php?action=get_video&id={did}&ep={ep}&lang={lang}&sv={sv}")
                if j.get("ok") and j.get("videoUrl"):
                    u = j["videoUrl"]
                    return dict(url=u, kind="hls" if j.get("isHls") else "mp4", server=j.get("activeVideoServer"),
                                qualities=j.get("qualities", []), subtitles=j.get("subtitles", []), headers={})
                err = j.get("error")
        raise DramafrenError(f"dramabox {did} ep{ep}: {err}")

    # --- goodshort: chapterIds from watch page (ep=-1 = fast, no server-side resolve), then
    #     GET cdn-goodshort/index.php?action=get_video_url&id&chap_id&sv&lang -> proxy m3u8 (plain TS)
    _gs_chapters = {}

    def goodshort_chapters(self, did, lang=None):
        key = (did, lang or self.lang)
        if key not in self._gs_chapters:
            t = self._page(f"page=watch&id={did}&ep=-1&lang={key[1]}&sv=1")
            m = re.search(r"var chapterIds = \[(.*?)\]", t, re.S)
            if not m:
                raise DramafrenError("goodshort: chapterIds not found")
            self._gs_chapters[key] = re.findall(r"'(\d+)'", m.group(1))
        return self._gs_chapters[key]

    def _stream_goodshort(self, did, ep, server, lang):
        chap = self.goodshort_chapters(did, lang)
        if not 0 <= ep < len(chap):
            raise DramafrenError(f"goodshort ep index {ep} out of range 0..{len(chap) - 1}")
        err = None
        for sv in ([server] if server else [1, 2]):
            j = self._json(f"{self.cfg['video'][0]}/index.php?action=get_video_url&id={did}"
                           f"&chap_id={chap[ep]}&sv={sv}&lang={lang}")
            if j.get("status") == "success" and j.get("video_url"):
                return dict(url=j["video_url"], kind="hls", server=sv, chap_id=chap[ep],
                            qualities=j.get("qualities", []), subtitles=[], headers={})
            err = j
        raise DramafrenError(f"goodshort {did} ep{ep}: {err}")

    # --- netshort: GET cdn-netshort/index.php?action=resolve_watch&id&ep&server  (CF-free JSON)
    def _stream_netshort(self, did, ep, server, lang):
        err = None
        for sv in ([server] if server else [1, 2]):
            for base in self.cfg["video"]:
                j = self._json(f"{base}/index.php?action=resolve_watch&id={did}&ep={ep}&server={sv}")
                if j.get("ok") and j.get("videoUrl"):
                    return dict(url=j["videoUrl"], kind="mp4", server=j.get("server"),
                                qualities=j.get("qualities", []), subtitles=j.get("subtitles", []), headers={})
                err = j.get("message")
        raise DramafrenError(f"netshort {did} ep{ep}: {err}")

    # --- flickreels: m3u8 is baked into the watch page (<video src> / var initialVideoUrl)
    def _stream_flickreels(self, did, ep, server, lang):
        q = f"page=watch&id={did}&ep={ep}&lang={lang}" + (f"&server={server}" if server else "")
        t = self._page(q)
        m = re.search(r'var initialVideoUrl = "([^"]*)"', t)
        url = json.loads('"' + m.group(1) + '"') if m else ""
        fb = re.search(r'corsFallbackUrl: "([^"]+)"', t)
        if not url:
            raise DramafrenError(f"flickreels {did} ep{ep}: no initialVideoUrl")
        return dict(url=url, kind="hls", server=server or 1,
                    fallback=json.loads('"' + fb.group(1) + '"') if fb else None,
                    qualities=[], subtitles=[], headers={})


def probe_bytes(url, n=1024, ua=DEFAULT_UA, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Range": f"bytes=0-{n - 1}"})
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL) as r:
        return r.status, r.headers.get("Content-Type"), r.read(n)


def check_stream(s, ua=DEFAULT_UA):
    """Fetch the stream and assert real video bytes (mp4 'ftyp' or TS sync 0x47)."""
    st, ct, b = probe_bytes(s["url"], 4096, ua)
    if s["kind"] == "mp4":
        assert b[4:8] == b"ftyp", (ct, b[:16])
        return f"mp4 {st} {ct} ftyp ok"
    text = b.decode("utf-8", "replace")
    assert text.startswith("#EXTM3U"), text[:80]
    seg = next(l for l in text.splitlines() if l and not l.startswith("#"))
    seg = urllib.parse.urljoin(s["url"], seg)
    st2, ct2, b2 = probe_bytes(seg, 376, ua)
    assert b2[0] == 0x47 and b2[188] == 0x47, b2[:8]
    return f"m3u8 {st} {ct} -> segment {st2} {ct2} TS sync ok"


def _cf_from_local_chrome():
    """Dev convenience: read cf_clearance + UA from the Chrome on :9222 (the app uses its WebView instead)."""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return None, None
    try:
        with sync_playwright() as p:
            ctx = p.chromium.connect_over_cdp("http://localhost:9222").contexts[0]
            ck = next((c["value"] for c in ctx.cookies() if c["name"] == "cf_clearance"
                       and c["domain"].endswith("dramafren.org")), None)
            pg = ctx.new_page()
            try:
                ua = pg.evaluate("navigator.userAgent")
            finally:
                pg.close()
            return ck, ua
    except Exception as e:  # noqa
        print("  (no local chrome:", e, ")")
        return None, None


if __name__ == "__main__":
    sites = sys.argv[1:] or list(SITES)
    ck = ua = None
    ck, ua = _cf_from_local_chrome()  # optional: only dramabox HTML + front-host feeds need it
    for site in sites:
        print(f"===== {site}")
        c = DramafrenClient(site, cf_clearance=ck, user_agent=ua)
        try:
            f = c.feed(1)
            print(f"feed p1: {len(f['items'])} items, page {f['page']}/{f['pages']} has_more={f['has_more']}")
            print("  first:", {k: f["items"][0][k] for k in ("id", "title", "cover")})
            r = c.search("love")
            print(f"search 'love': {len(r)} results; first: {r[0]['id']} {r[0]['title']!r} eps={r[0]['episodes']}")
            did = f["items"][0]["id"]
            d = c.detail(did)
            print(f"detail {did}: {d['title']!r} total={d['total']} eps={len(d['episodes'])} "
                  f"first={d['episodes'][0]} last={d['episodes'][-1]} tags={d['tags'][:3]}")
        except Exception as e:  # noqa
            print("  HTML step failed:", e)
            d = None
        demo_id = {"dramabox": "42000027929", "goodshort": "31001769950",
                   "netshort": "2101848053751341058", "flickreels": "12153"}[site]
        if d is None or not d["episodes"]:
            d = {"id": demo_id, "episodes": [{"ep": 0 if site == "goodshort" else 1}]}
        eps = d["episodes"]
        for e in (eps[0], eps[-1]):
            try:
                s = c.stream(d["id"], e["ep"])
                print(f"stream ep={e['ep']}: {s['kind']} srv={s.get('server')} {s['url'][:100]}")
                print("   ", check_stream(s))
            except Exception as ex:  # noqa
                print(f"stream ep={e['ep']} FAILED: {ex}")
