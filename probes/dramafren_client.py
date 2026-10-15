#!/usr/bin/env python3
"""Reference client for the dramafren PHP "player" mirrors (shared template):
stardusttv / dramawave / reelshort / idrama  (.dramafren.org).

See probes/template_dramafren_php.md and probes/<site>.md for the spec.

Transport:
  * dramawave, idrama -> CF-free twin host  cdn-<site>.dramafren.org  (plain HTTP, stdlib urllib)
  * stardusttv, reelshort -> ONLY the Cloudflare-protected host exists, so requests are
    executed *inside a browser page on that origin* (same thing a Flutter WebView does with
    evaluateJavascript(fetch(...))). Here: Playwright over CDP to a Chrome on localhost:9222.
  * Stream URLs (m3u8 + segments) are CF-free on every site -> plain HTTP / any HLS player.

usage:  python dramafren_client.py [site ...]       (default: all four)
"""
import base64, html, json, os, re, ssl, subprocess, sys, time, urllib.parse, urllib.request

# python.org macOS builds ship without a CA bundle; fall back to the system one
_SSL = ssl.create_default_context(cafile="/etc/ssl/cert.pem") if os.path.exists("/etc/ssl/cert.pem") else None

UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36")

SITES = {
    "stardusttv": dict(base="https://stardusttv.dramafren.org/index.php", cf=True,
                       lang="en_US", home="hp", search_page="search_result", search_pager="p"),
    "dramawave":  dict(base="https://cdn-dramawave.dramafren.org/index.php", cf=False,
                       lang="en-US", home="hp", search_page=None, search_pager=None),
    "reelshort":  dict(base="https://reelshort.dramafren.org/index.php", cf=True,
                       lang="en", home="p_hist", search_page="search_result", search_pager=None),
    "idrama":     dict(base="https://cdn-idrama.dramafren.org/index.php", cf=False,
                       lang="en", home="p_hist", search_page="search", search_pager=None),
}


# ----------------------------------------------------------------------------- transport
def http_get(url, headers=None, binary=False, limit=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=30, context=_SSL) as r:
        data = r.read(limit) if limit else r.read()
    return data if binary else data.decode("utf-8", "replace")


class BrowserFetcher:
    """Runs fetch() inside a tab on the CF-protected origin (cf_clearance applies there).
    Flutter equivalent: hidden WebView on https://<site>.dramafren.org/ + evaluateJavascript."""
    def __init__(self, cdp="http://localhost:9222"):
        self.cdp, self._pw, self._pages = cdp, None, {}

    def _page(self, origin):
        if origin not in self._pages:
            if self._pw is None:
                from playwright.sync_api import sync_playwright
                self._pw = sync_playwright().start()
                self._ctx = self._pw.chromium.connect_over_cdp(self.cdp).contexts[0]
            pg = self._ctx.new_page()
            pg.goto(origin + "/index.php", wait_until="domcontentloaded", timeout=60000)
            for _ in range(40):                      # wait out the CF interstitial
                if "Just a moment" not in pg.title():
                    break
                pg.wait_for_timeout(1000)
            self._pages[origin] = pg
        return self._pages[origin]

    def get(self, url):
        o = urllib.parse.urlsplit(url)
        pg = self._page(f"{o.scheme}://{o.netloc}")
        return pg.evaluate("async u => { const r = await fetch(u, {credentials:'same-origin'});"
                           " return await r.text(); }", url)

    def close(self):
        for pg in self._pages.values():
            pg.close()
        if self._pw:
            self._pw.stop()


# ----------------------------------------------------------------------------- parsing
def _cards(h):
    """Cards = <a href="index.php?page=detail&id=..."> ... <img src> ... <h3>title</h3> ... </a>."""
    out, seen = [], set()
    for m in re.finditer(r'<a href="([^"]*page=detail[^"]*)"[^>]*>(.*?)</a>', h, re.S):
        href = html.unescape(m.group(1))
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(href).query))
        if q.get("id") in seen:
            continue
        seen.add(q.get("id"))
        body = m.group(2)
        img = re.search(r'<img[^>]*src="([^"]+)"', body)
        t = re.search(r"<h3[^>]*>(.*?)</h3>", body, re.S)
        eps = re.search(r"(\d+)\s*Eps", body)
        out.append(dict(id=q.get("id"), slug=q.get("slug"), lang=q.get("lang"),
                        title=html.unescape(re.sub(r"<[^>]+>", "", t.group(1))).strip() if t else None,
                        cover=html.unescape(img.group(1)) if img else None,
                        episodes=int(eps.group(1)) if eps else None))
    return out


class Dramafren:
    def __init__(self, site, browser=None):
        self.site, self.cfg = site, SITES[site]
        self.base = self.cfg["base"]
        self.browser = browser

    def _get(self, **params):
        url = self.base + "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        if self.cfg["cf"]:
            self.browser = self.browser or BrowserFetcher()
            return self.browser.get(url)
        return http_get(url)

    # -- feed: global "Recently Watched" list, paginated
    def feed(self, page=1):
        c = self.cfg
        if c["home"] == "hp":
            h = self._get(hp=page, lang=c["lang"] if self.site == "dramawave" else None)
        else:
            h = self._get(page="home", p_hist=page, lang=c["lang"] if self.site == "idrama" else None)
        # restrict to the Recently Watched block (header links/other blocks excluded)
        i = h.find("Recently Watched")
        block = h[i:] if i >= 0 else h
        nxt = re.search(r'href="([^"]*(?:hp|p_hist)=%d[^"]*)"[^>]*>\s*Next' % (page + 1), block)
        return dict(items=_cards(block), has_more=bool(nxt))

    def search(self, q, page=1):
        c = self.cfg
        h = self._get(page=c["search_page"], q=q, lang=c["lang"],
                      **({c["search_pager"]: page} if c["search_pager"] and page > 1 else {}))
        i = h.find(">Search") if self.site != "idrama" else h.find(">Results:")
        block = h[i:] if i >= 0 else h
        m = re.search(r"Page (\d+) of (\d+)", block)
        has_more = bool(m and int(m.group(1)) < int(m.group(2)))
        return dict(items=_cards(block), has_more=has_more)

    def detail(self, id, slug=None):
        h = self._get(page="detail", id=id, slug=slug,
                      lang=None if self.site == "reelshort" else self.cfg["lang"])
        t = re.search(r"<h1[^>]*>(.*?)</h1>", h, re.S)
        i = h.find("<h1")
        cover = re.findall(r'<img[^>]*src="([^"]+)"', h[:i])
        n = re.search(r"Total:\s*(\d+)\s*Eps|(\d+)\s*Episodes", h)
        syn = re.search(r"</h1>.*?<p[^>]*>(.*?)</p>", h, re.S)
        eps = sorted({int(e) for e in re.findall(r"page=watch&amp;id=[^&]+(?:&amp;slug=[^&]+)?&amp;ep=(\d+)", h)})
        return dict(id=id, slug=slug,
                    title=html.unescape(t.group(1)).strip() if t else None,
                    cover=html.unescape(cover[-1]) if cover else None,
                    synopsis=html.unescape(re.sub(r"<[^>]+>", "", syn.group(1))).strip() if syn else "",
                    total_eps=int(n.group(1) or n.group(2)) if n else (max(eps) if eps else 0),
                    episodes=eps)

    def stream(self, id, ep, slug=None, server=1):
        """Returns dict(url=<m3u8>, qualities=[...], subtitles=[...], headers={})."""
        s = self.site
        if s == "idrama":
            # server-side cached; cache-buster gives a fresh ts/secret (ts = expiry, ~2h)
            j = json.loads(self._get(action="watch_stream", id=id, ep=ep, server=server,
                                     lang=self.cfg["lang"], _=int(time.time() * 1000)))
            if not j.get("ok"):
                raise RuntimeError(j)
            proxied = j["video_url"]
            direct = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(proxied).query)).get("url")
            return dict(url=direct or proxied, proxy_url=proxied, subtitles=j.get("subs", []),
                        total_eps=j.get("total_eps"), qualities=[], headers={})
        if s == "stardusttv":
            h = self._get(page="watch", id=id, slug=slug, ep=ep, sv=server, lang=self.cfg["lang"])
            m = re.search(r'const encryptedSrc = "([^"]*)"', h)
            if not m or not m.group(1):
                raise RuntimeError("no encryptedSrc")
            url = base64.b64decode(m.group(1)).decode()
            return dict(url=url, qualities=[], subtitles=[], headers={})
        if s == "reelshort":
            h = self._get(page="watch", id=id, ep=ep, server=server)
            q = re.search(r"const availableQualities = (\[.*?\]);", h)
            quals = [dict(quality=x["quality"], url=base64.b64decode(x["hash64"]).decode())
                     for x in (json.loads(q.group(1)) if q else [])]
            m = re.search(r'const videoSrc = atob\("([^"]*)"\)', h)
            url = base64.b64decode(m.group(1)).decode() if m else (quals[0]["url"] if quals else None)
            if not url:
                raise RuntimeError("no videoSrc")
            return dict(url=url, qualities=quals, subtitles=[], headers={})
        if s == "dramawave":
            h = self._get(page="watch", id=id, ep=ep, server=server, lang=self.cfg["lang"])
            m = re.search(r'var src = "([^"]*)"', h)
            px = re.search(r'const proxyRescueSrc = "([^"]*)"', h)
            subs = re.search(r"const subtitleOptions = (\[.*?\]);", h)
            host = urllib.parse.urlsplit(self.base)
            subs = [dict(lang=x.get("lang_code"), label=x.get("label"),
                         url=f"{host.scheme}://{host.netloc}/index.php{x['url']}&ext=.vtt")
                    for x in (json.loads(subs.group(1)) if subs else [])]
            if not m or not m.group(1):
                raise RuntimeError("no src")
            return dict(url=json.loads('"%s"' % m.group(1)), proxy_url=px.group(1) if px else None,
                        subtitles=subs, qualities=[], headers={})
        raise ValueError(s)


# ----------------------------------------------------------------------------- verification
def verify_hls(url):
    """Fetch playlist (follow first variant), fetch first segment; decrypt if AES-128. Returns str."""
    pl = http_get(url)
    assert pl.startswith("#EXTM3U"), pl[:100]
    if "#EXT-X-STREAM-INF" in pl:
        var = [l for l in pl.splitlines() if l and not l.startswith("#")][-1]   # lowest variant
        url = urllib.parse.urljoin(url, var)
        pl = http_get(url)
    key = re.search(r'#EXT-X-KEY:METHOD=([^,]+)(?:,URI="([^"]+)")?(?:,IV=0x([0-9a-fA-F]+))?', pl)
    seg = urllib.parse.urljoin(url, [l for l in pl.splitlines() if l and not l.startswith("#")][0])
    data = http_get(seg, binary=True)
    note = f"playlist ok, seg {len(data)}B"
    if key and key.group(1) == "AES-128":
        k = http_get(urllib.parse.urljoin(url, key.group(2)), binary=True)
        iv = key.group(3) or "0" * 32
        data = subprocess.run(["openssl", "enc", "-d", "-aes-128-cbc", "-K", k.hex(), "-iv", iv],
                              input=data, capture_output=True).stdout
        note += f", AES-128 key {len(k)}B -> decrypted {len(data)}B"
    note += f", first byte 0x{data[0]:02x} ({'MPEG-TS' if data[:1] == b'G' else 'fMP4/other'})"
    return note


DEMO = {  # (search query, fallback id, slug)
    "stardusttv": "love", "dramawave": "love", "reelshort": "love", "idrama": "love",
}

if __name__ == "__main__":
    browser = None
    for site in (sys.argv[1:] or list(SITES)):
        c = Dramafren(site, browser)
        print(f"===== {site}  ({c.base}, CF={'yes -> in-page fetch' if c.cfg['cf'] else 'no -> plain HTTP'})")
        f = c.feed(1)
        print(f"feed p1: {len(f['items'])} items, has_more={f['has_more']}; first={f['items'][0]['title']!r}")
        s = c.search(DEMO[site])
        print(f"search: {len(s['items'])} items, has_more={s['has_more']}; first={s['items'][0]}")
        it = s["items"][0]
        d = c.detail(it["id"], it["slug"])
        print(f"detail: {d['title']!r} eps={d['total_eps']} cover={d['cover'][:70]} synopsis={d['synopsis'][:60]!r}")
        st = c.stream(it["id"], 1, it["slug"])
        print(f"stream ep1: {st['url'][:110]}")
        print("  verify:", verify_hls(st["url"]))
        browser = c.browser or browser
    if browser:
        browser.close()
