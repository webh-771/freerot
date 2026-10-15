# microdrama.dramafren.org — probed 2026-09-23

**Status: WORKS.** All episodes (including the last/locked ones) resolve to direct MP4s.
Upstream catalogue is the "ReelTV / MicroDrama" app (assets on `*.janzhoutec.com`).

## Architecture
A single PHP page with an inline-JS SPA. The page calls its own origin:
`GET https://microdrama.dramafren.org/?api_route=<route>&lang=<lang>&...`
There is no signing or encryption on the requests or responses (plain JSON).

| Host | CF | Notes |
|---|---|---|
| `microdrama.dramafren.org/?api_route=*` | **CF managed challenge** (403 `cf-mitigated: challenge` for curl/curl_cffi) | Call it from a WebView on this origin, **or** solve it once in a WebView and reuse `cf_clearance` with the **same User-Agent** from Dart HTTP. Verified: cookie + UA works from plain urllib/curl. |
| `poster.janzhoutec.com` (covers) | CF-free | plain GET |
| `reeltv.janzhoutec.com` (video) | CF-free | plain GET, no Referer/Origin needed, Range OK (Byte-nginx / BytePlus CDN) |

## Languages
`lang` = `en` (default), `id`, `th`, `es`, `pt`, `ja`, `ko`. **Each language is a separate catalogue with its own ids.**
Calling `detail` with an id from another language returns `{"error":"Failed to fetch data and no cache available"}`.

## 1. Feed: `?api_route=list&lang=en&page=N`
```json
{"total":286,"dramas":[{"id":"2100422082557042689","title":"The Mafia'S Stolen Bride",
  "description":"Sabrina wakes from a crash…","episodes":40,
  "cover":"https://poster.janzhoutec.com/tos-sgcomm1-v-376351e6ad930ea1-sg/cf14…~tplv-vod-noop.image"}]}
```
- Always returns the newest **50**, whatever `page`/`p`/`offset`/`limit` says. `total` is the catalogue size.
- The site's infinite scroll just appends duplicates. **Rule: treat page 1 as the only page (has_more = false)**, or use the catalogue trick below.
- **Full catalogue trick:** `?api_route=search&q=%20` (a single space) returns every title (`total` = catalogue size, e.g. 286 en, 250 id, 269 es) in one response.

## 2. Search: `?api_route=search&lang=en&q=<q>&page=1`
Same shape as list. Returns **all** matches at once (`ceo` → 38, `love` → 111); `page` is ignored (page 2 equals page 1).
`q=` (empty) → `{"error":"Failed to fetch data and no cache available"}`. No hits → `{"total":0,"dramas":[]}`.

## 3. Detail: `?api_route=detail&lang=en&id=<id>`
```json
{"drama":{"id":"2100…","title":"…","description":"…","cover":"…","episodes":40},
 "episodes":[{"index":1,"videos":[
   {"quality":"540P","url":"https://reeltv.janzhoutec.com/ooCVGL…?auth_key=1790339076-Uu91rd5WrK-0-454f3a05d39bdc0ef2a8b2c17537967b","width":540,"height":960},
   {"quality":"720P","url":"…","width":720,"height":1280},{"quality":"480P",…},{"quality":"360P",…}]}, …]}
```
- ids are numeric strings (~19 digits). `index` is 1-based.
- Every episode, locked or not, carries its video URLs in the detail response. No separate unlock call exists.

## 4. Playback
The video URL comes straight from `detail.episodes[i].videos[]`. The site picks `720P`, else `[0]`.
- Format: **progressive MP4** (`ftyp isom`, H.264), no DRM or encryption.
- `auth_key=<expiry>-<rand>-0-<md5>` (Aliyun-style type-A). Expiry is about **+2 days** (1790339076 = 2026-09-25). Re-fetch detail when it expires.
- Plain GET works with no headers (tested with curl; `206 video/mp4`). **ep 1 and ep 40 (the last) both return bytes.**
- The site plays `?api_route=play&vid=base64(url)`, a CF-protected pass-through proxy. The app doesn't need it.

## Gotchas
- An upstream error on uncached input always looks like `{"error":"Failed to fetch data and no cache available"}`.
- Page paging is broken on the site side, so use search-space for the full list.
- No subtitles route: the videos have burned-in subtitles.

## Files
`fixtures/microdrama_{list,search,detail}.json`, `microdrama_client.py` (uses `_cf_session.py`).
