# KalosTV mirror: kalostv.dramafren.org

Probed 2026-09-23. Uses the shortmax/dramafren PHP template (`template_dramafren_php.md`, `../API_NOTES.md`).
Client: `dramafren_more_client.py` (`Client("kalostv")`). Fixtures: `fixtures/kalostv_*`.

**Status: works.** Playback is a CF-free JSON API that returns a fresh signed HLS URL for **every** episode,
VIP episodes included.

## Hosts / Cloudflare
| Endpoint | CF? | Transport |
|---|---|---|
| `https://kalostv.dramafren.org/index.php?page=…` (home/search/detail/watch) | **challenge (403 `cf-mitigated: challenge`)** | WebView on that origin + `fetch()` |
| `https://cdn-kalostv.dramafren.org/index.php?action=resolve_watch…` | **no challenge** (still CF-proxied, LiteSpeed origin) | plain HTTP |
| `https://cdn-kalostv.dramafren.org/index.php?action=proxy_sub&url=…` | no challenge (untested; used by page JS for subtitles) | plain HTTP |
| `https://cdnm3u8.kalostv.com/production/…m3u8?Expires&Signature&Key-Pair-Id` | none (CloudFront signed) | plain HTTP, no headers |
| `https://cdnts.kalostv.com/production/…/*.ts`, `/image/*.jpg` covers | none | plain HTTP |

`cdn-kalostv` answers `404` for `?page=home`. It only serves the `action=` endpoints, so the HTML pages need the WebView.

## Language
`lang` = `id en es pt zh th vi ar fr ms tl` (default `en`). Taken from the page's search `<select name="lang">`
and the watch JS `kalostvLangs`.

## Feed (home, global "Recently Watched")
`GET index.php?page=home&p_hist={n}`. 12 cards per page. The pager reads `Page 1 of 9`.
hasMore = there is an `<a href="index.php?page=home&amp;p_hist={n+1}">Next »</a>`.
Card: `<a href="index.php?page=detail&amp;id=27788&amp;lang=en">` → `<img src=COVER alt=TITLE>` + `<h3>TITLE</h3>` + "Watch Now".
Parse only after the text `Recently Watched`. The top of the page holds the nav links to sister sites.

## Search
The form is `GET index.php?page=search_result&q={q}&lang={lang}`, the same as shortmax: a hidden `page=search_result` input.
The results page was **not fetched for kalostv**. It is the same template as starshort, so see `starshort.md` for the markup
(`<h2>Search: "q"</h2>` then cards `a[href*=page=detail]` with `<h3>`).
The home page also has a "Paste URL" form: `index.php?input_raw=<share url>` with placeholder
`https://api.kalostv.com/middle/share?video_id=26748...`. It turns an app share link into a detail page (not tested).

## Detail
`GET index.php?page=detail&id={id}&lang=en`. The id is numeric (`27788`). See `fixtures/kalostv_detail.html`.
- title `<h1>`; cover = `<img … alt="{title} Poster">` just before the h1 (`https://cdnts.kalostv.com/image/….jpg`)
- `<span>Total: 45 Eps</span>`, `<span>Server: KalosTV</span>`
- synopsis = first `<p class="text-slate-300 …">` after the h1
- episodes: `a[href*="page=watch"]` → `index.php?page=watch&id=27788&ep={1..N}&lang=en`. There are no lock markers.

## Playback (verified, ep 1 and VIP ep 45)
The watch page is `page=watch&id=&ep=&lang=[&server=]`. Its inline JS holds
`watchActionEndpoints = ["https://cdn-kalostv.dramafren.org/index.php"]` and calls:

```
GET https://cdn-kalostv.dramafren.org/index.php?action=resolve_watch&id=27788&ep=45&server=1&lang=en&_=<ms>
→ 200 application/json   (page JS allows a 45 s timeout; our calls answered within seconds)
{"ok":true,"server":1,
 "url":"https://cdnm3u8.kalostv.com/production/1789988522/fc22…df2.m3u8?Expires=1790175036&Signature=…&Key-Pair-Id=KPZUPR27RPOA4",
 "episode":{"episodes_id":1008257,"sort_id":45,"title":"…第45集","is_vip":1,"price":127,"url":"…","url_265":"…","duration":0},
 "qualities":[{"quality":"H.264 720p","url":…},{"quality":"H.264 540p",…},{"quality":"H.265 540p",…},
              {"quality":"H.265 720p",…},{"quality":"H.264 1080p",…},{"quality":"H.265 1080p",…}],
 "subtitles":[], "source":"KalosTV Gshorts"}
```
- On failure the response is `ok:false` + `message`. The page JS throws `payload.message || 'Video unavailable.'`.
- `server=2` returns the same JSON, but `url` is the **H.265** (`url_265`) rendition. Use server 1 (H.264) on Android
  unless the device decodes HEVC.
- `Expires` is about **10–15 min** after the resolve call. Resolve right before playback and re-resolve on a 403.
- The m3u8 is a plain media playlist (`#EXT-X-TARGETDURATION:2`). Segment URLs are **absolute**
  `https://cdnts.kalostv.com/production/<hash>/<hash>.ts` with no query string. There is no `EXT-X-KEY`; segments are MPEG-TS (first byte 0x47).
  Plain curl works with no Referer, Origin or cookie. The ep-45 segment was 345 KB and started `47 40 11 10`.
- Subtitles: each `subtitles[]` item is `{url, language|lang}`. The page loads it via
  `cdn-kalostv…/index.php?action=proxy_sub&url=<encoded sub.url>` as a `<track kind=subtitles>`. Our test drama had none.
  The server burns its own title into the video.
- Paywall: ep 45 has `is_vip:1, price:127` and still returns a working URL. **Every episode resolves.**
- The page shows a 60 s "watch previous ep" overlay. That gate is client-side (localStorage) only, and the JSON API ignores it.

## Recipe for the app
1. Catalogue (feed/search/detail): load `https://kalostv.dramafren.org/index.php` in a hidden WebView, let CF pass, then
   `evaluateJavascript("fetch('index.php?page=…').then(r=>r.text())")` and parse the HTML natively.
2. Playback: plain Dio/HTTP `resolve_watch` → hand `url` (or a `qualities[].url`) to ExoPlayer/media_kit. No headers are needed.

Fixtures: `kalostv_home.html`, `kalostv_detail.html`, `kalostv_watch.html` (full player JS),
`kalostv_resolve_watch_ep1.json`, `kalostv_resolve_watch_ep45_vip.json`, `kalostv_ep45.m3u8`.
