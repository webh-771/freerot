"""Shared helper for the dramafren probe clients.

Cloudflare-protected hosts (microdrama/shortwave/moboreels.dramafren.org) serve a managed
challenge to any non-browser client. BUT once a real browser has passed it, the resulting
`cf_clearance` cookie + the SAME User-Agent string works from plain HTTP (verified with
urllib/curl — no TLS impersonation needed). This mirrors what the Flutter app should do:
solve the challenge once in a WebView, read `cf_clearance` from CookieManager, then call
the JSON endpoints directly with that cookie + the WebView's UA.

Here we get the cookie from the shared debugging Chrome on localhost:9222.
"""
import json, ssl, time, urllib.request, urllib.parse

try:
    import certifi
    SSL = ssl.create_default_context(cafile=certifi.where())
except Exception:  # pragma: no cover
    SSL = ssl.create_default_context()

DEFAULT_UA = ("Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36")
_cache = {}


def clearance(host):
    """Return (cookie_header, user_agent) for a CF-protected host via Chrome CDP."""
    if host in _cache:
        return _cache[host]
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp("http://localhost:9222")
        ctx = b.contexts[0]
        pg = ctx.new_page()
        try:
            pg.goto(f"https://{host}/", wait_until="domcontentloaded", timeout=60000)
            for _ in range(40):
                if "Just a moment" not in pg.title():
                    break
                time.sleep(1)
            ua = pg.evaluate("navigator.userAgent")
        finally:
            pg.close()
        jar = {c["name"]: c["value"] for c in ctx.cookies(f"https://{host}/")}
    ck = "; ".join(f"{k}={v}" for k, v in jar.items() if k == "cf_clearance")
    _cache[host] = (ck, ua)
    return _cache[host]


def http(url, method="GET", body=None, headers=None, cf_host=None, raw=False, rng=None, timeout=40):
    h = {"User-Agent": DEFAULT_UA, "Accept": "application/json, */*"}
    if cf_host:
        ck, ua = clearance(cf_host)
        h["User-Agent"] = ua
        h["Cookie"] = ck
    if headers:
        h.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if rng:
        h["Range"] = rng
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=SSL) as r:
            b = r.read()
            status, ctype = r.status, r.headers.get("content-type", "")
    except urllib.error.HTTPError as e:
        b, status, ctype = e.read(), e.code, e.headers.get("content-type", "")
    if raw:
        return status, ctype, b
    try:
        return json.loads(b)
    except Exception:
        return {"_status": status, "_raw": b[:300].decode("utf-8", "replace")}


def q(params):
    return urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
