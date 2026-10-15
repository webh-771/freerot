#!/usr/bin/env python3
"""Reference client for starshort / kalostv / dramabite (+ flextv feed) .dramafren.org mirrors.

Spec: probes/starshort.md, kalostv.md, dramabite.md, flextv.md (and template_dramafren_php.md).
Reuses transport/parsing helpers from probes/dramafren_client.py (same PHP template family).

Transport:
  * HTML pages (home/search/detail/watch) of starshort, kalostv, dramabite: Cloudflare-challenged
    -> fetched *inside a page on that origin* (BrowserFetcher = Flutter hidden WebView + evaluateJavascript).
  * kalostv playback JSON: cdn-kalostv.dramafren.org/index.php?action=resolve_watch  -> CF-free, plain HTTP.
  * flextv.dramafren.org: no CF challenge (plain HTTP) -- only the home feed is implemented/verified.
  * Stream URLs (m3u8 + .ts) are CF-free and need no headers.

usage:
  python dramafren_more_client.py --offline          # parse saved fixtures only (no network)
  python dramafren_more_client.py [site ...]         # live demo (needs Chrome on :9222 for CF sites)
"""
import base64, html, json, os, re, sys, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dramafren_client import BrowserFetcher, _cards, http_get, verify_hls  # noqa: E402

SITES = {
    # lang: starshort uses NUMERIC language ids (3 = English); others use ISO-ish codes
    "starshort": dict(base="https://starshort.dramafren.org/index.php", cf=True, lang="3"),
    "kalostv":   dict(base="https://kalostv.dramafren.org/index.php", cf=True, lang="en",
                      resolve="https://cdn-kalostv.dramafren.org/index.php"),
    "dramabite": dict(base="https://dramabite.dramafren.org/index.php", cf=True, lang="en"),
    "flextv":    dict(base="https://flextv.dramafren.org/index.php", cf=False, lang="en"),
}


# ----------------------------------------------------------------------------- pure parsers
def parse_feed(h, page):
    i = h.find("Recently Watched")
    block = h[i:] if i >= 0 else h
    nxt = re.search(r'href="[^"]*p_hist=%d"[^>]*>\s*Next' % (page + 1), block)
    return dict(items=_cards(block), has_more=bool(nxt))


def parse_search(h):
    i = h.find(">Search:")
    block = h[i:] if i >= 0 else h
    m = re.search(r"Page (\d+) of (\d+)", block)
    return dict(items=_cards(block), has_more=bool(m and int(m.group(1)) < int(m.group(2))))


def parse_detail(h, id):
    t = re.search(r"<h1[^>]*>(.*?)</h1>", h, re.S)
    i = h.find("<h1")
    cover = re.findall(r'<img[^>]*src="([^"]+)"', h[:i])
    n = re.search(r"Total:\s*(\d+)\s*Eps", h)
    syn = re.search(r"</h1>.*?<p[^>]*>(.*?)</p>", h, re.S)
    eps = sorted({int(e) for e in re.findall(r"page=watch&(?:amp;)?id=[^&\"]+&(?:amp;)?ep=(\d+)", h)})
    return dict(id=id, title=html.unescape(t.group(1)).strip() if t else None,
                cover=html.unescape(cover[-1]) if cover else None,
                synopsis=html.unescape(re.sub(r"<[^>]+>", "", syn.group(1))).strip() if syn else "",
                total_eps=int(n.group(1)) if n else (max(eps) if eps else 0), episodes=eps)


def parse_watch_starshort(h):
    """const encryptedSrc = "<b64 m3u8>";  const availableQualities = [{quality,url}];"""
    m = re.search(r'const encryptedSrc = "([^"]*)"', h)
    q = re.search(r"const availableQualities = (\[.*?\]);", h)
    url = base64.b64decode(m.group(1)).decode() if m and m.group(1) else None
    quals = json.loads(q.group(1)) if q else []
    exp = re.search(r"auth_key=(\d+)-", url or "")
    return dict(url=url, qualities=quals, subtitles=[], headers={},
                expires=int(exp.group(1)) if exp else None)


def parse_watch_dramabite(h):
    """const videoSrc = atob("<b64 m3u8>");  const availableServers = [...]"""
    m = re.search(r'const videoSrc = atob\("([^"]*)"\)', h)
    s = re.search(r"const availableServers = (\[.*?\]);", h)
    url = base64.b64decode(m.group(1)).decode() if m and m.group(1) else None
    return dict(url=url, qualities=[], subtitles=[], headers={},
                servers=json.loads(s.group(1)) if s else [])


def parse_flextv_feed(h):
    out, seen = [], set()
    for m in re.finditer(r'<a href="index\.php\?page=detail&(?:amp;)?id=(\d+)"[^>]*>(.*?)</a>', h, re.S):
        id, body = m.group(1), m.group(2)
        if id in seen:
            continue
        seen.add(id)
        img = re.search(r'<img src="([^"]+)" alt="([^"]*)"', body)
        g = re.search(r"<p[^>]*>([^<]*)</p>", body)
        v = re.search(r"&#9654;|▶\s*([\d.]+[KM]?)", body)
        out.append(dict(id=id, title=html.unescape(img.group(2)) if img else None,
                        cover=html.unescape(img.group(1)) if img else None,
                        genre=g.group(1).strip() if g else None, views=v.group(1) if v else None))
    return out


# ----------------------------------------------------------------------------- client
class Client:
    def __init__(self, site, browser=None):
        self.site, self.cfg, self.browser = site, SITES[site], browser
        self.base = self.cfg["base"]

    def _get(self, **params):
        url = self.base + "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        if self.cfg["cf"]:
            self.browser = self.browser or BrowserFetcher()
            return self.browser.get(url)
        return http_get(url)

    def feed(self, page=1, tab=1):
        if self.site == "flextv":  # tabs: 1 Popular, 2 New, 6 Original+, 7 For Her, 8 For Him, 11 Anime
            h = self._get(page="home", tab=tab, p=page if page > 1 else None)
            return dict(items=parse_flextv_feed(h),
                        has_more=bool(re.search(r"tab=%d&(?:amp;)?p=%d\"" % (tab, page + 1), h)))
        return parse_feed(self._get(page="home", p_hist=page), page)

    def search(self, q, page=1):
        # no pager observed on starshort (10 results max); s_page is the shortmax-template pager
        return parse_search(self._get(page="search_result", q=q, lang=self.cfg["lang"],
                                      s_page=page if page > 1 else None))

    def detail(self, id):
        lang = None if self.site == "starshort" else self.cfg["lang"]
        return parse_detail(self._get(page="detail", id=id, lang=lang), id)

    def stream(self, id, ep, server=1):
        s = self.site
        if s == "kalostv":   # CF-free JSON, all episodes incl. VIP; URL expires in ~10-15 min
            u = self.cfg["resolve"] + "?" + urllib.parse.urlencode(dict(
                action="resolve_watch", id=id, ep=ep, server=server, lang=self.cfg["lang"],
                _=int(time.time() * 1000)))
            j = json.loads(http_get(u, headers={"Accept": "application/json"}))
            if not j.get("ok") or not j.get("url"):
                raise RuntimeError(j)
            subs = [dict(sub, proxy=self.cfg["resolve"] + "?action=proxy_sub&url=" +
                         urllib.parse.quote(sub["url"], safe="")) for sub in j.get("subtitles") or []]
            exp = re.search(r"Expires=(\d+)", j["url"])
            return dict(url=j["url"], qualities=j.get("qualities", []), subtitles=subs, headers={},
                        episode=j.get("episode"), expires=int(exp.group(1)) if exp else None)
        if s == "starshort":
            r = parse_watch_starshort(self._get(page="watch", id=id, ep=ep, lang=self.cfg["lang"], server=server))
            if not r["url"]:
                raise RuntimeError("no encryptedSrc")
            if r["expires"] and r["expires"] < time.time():
                r["stale"] = True   # server cached an expired auth_key -> CDN answers 403
            return r
        if s == "dramabite":
            r = parse_watch_dramabite(self._get(page="watch", id=id, ep=ep, lang=self.cfg["lang"], server=server))
            if not r["url"]:
                raise RuntimeError("no videoSrc")
            return r
        raise NotImplementedError(s)


# ----------------------------------------------------------------------------- demo / self-test
FX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def offline():
    rd = lambda f: open(os.path.join(FX, f), encoding="utf-8").read()
    for s in ("starshort", "kalostv", "dramabite"):
        f = parse_feed(rd(f"{s}_home.html"), 1)
        print(f"[{s}] feed: {len(f['items'])} items has_more={f['has_more']} first={f['items'][0]}")
        d = parse_detail(rd(f"{s}_detail.html"), "?")
        print(f"[{s}] detail: {d['title']!r} total={d['total_eps']} eps={len(d['episodes'])} "
              f"cover={d['cover'][:60]} syn={d['synopsis'][:50]!r}")
    sr = parse_search(rd("starshort_search.html"))
    print(f"[starshort] search: {len(sr['items'])} items has_more={sr['has_more']} first={sr['items'][0]}")
    w = parse_watch_starshort(rd("starshort_watch.html"))
    print(f"[starshort] watch: {w['url'][:90]} expires={w['expires']} quals={len(w['qualities'])}")
    w = parse_watch_dramabite(rd("dramabite_watch.html"))
    print(f"[dramabite] watch: {w['url'][:90]} servers={[x['label'] for x in w['servers']]}")
    j = json.loads(rd("kalostv_resolve_watch_ep45_vip.json"))
    print(f"[kalostv] resolve_watch ep45: vip={j['episode']['is_vip']} "
          f"quals={[q['quality'] for q in j['qualities']]} url={j['url'][:80]}")
    ff = parse_flextv_feed(rd("flextv_home.html"))
    print(f"[flextv] home feed: {len(ff)} items first={ff[0]}")


DEMO = {"starshort": "love", "kalostv": "love", "dramabite": "love"}

if __name__ == "__main__":
    if "--offline" in sys.argv:
        offline()
        sys.exit()
    browser = None
    for site in (sys.argv[1:] or list(DEMO)):
        c = Client(site, browser)
        f = c.feed(1)
        print(f"===== {site}: feed {len(f['items'])} has_more={f['has_more']}")
        if site == "flextv":
            continue
        s = c.search(DEMO[site])
        it = s["items"][0]
        d = c.detail(it["id"])
        print(f"search {len(s['items'])}; detail {d['title']!r} eps={d['total_eps']}")
        for ep in (1, d["total_eps"]):
            st = c.stream(it["id"], ep)
            print(f"stream ep{ep}: {st['url'][:100]} stale={st.get('stale')}")
            print("  verify:", verify_hls(st["url"]))
        browser = c.browser or browser
    if browser:
        browser.close()
