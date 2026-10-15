# ReelFren (reelfren.com) — API spec for FreeRot

Probed 2026-09-23. Reference client: `probes/reelfren_client.py` (run `python3 reelfren_client.py`; verified end to end, including real video bytes). Fixtures: `probes/fixtures/reelfren_*`.

## TL;DR

- **Only the website is behind Cloudflare.** `https://reelfren.com/*` (HTML, `/_next/static/*.js`) returns a 403 "Just a moment" challenge to curl.
- **The JSON backend is not challenged:** `https://api.reelfren.com/api/*` answers plain GETs with JSON. You don't need cookies, tokens, signatures, a Referer or Origin, or a particular User-Agent. Tested with curl's default UA, an empty UA, `Dart/3.4 (dart:io)` and `okhttp/4.12.0`. There is no request or response encryption.
- The helper host `https://proxy.dramafren.org` (also used for some stream URLs) is also directly reachable.
- The media CDNs (netshort, dramabox, wetv, vibeshort and so on) serve plain **MP4 or clear HLS**. No `EXT-X-KEY`, no DRM, no Referer needed, and Range requests are supported (206).
- **The app never needs a WebView.** Use Dart `http`/`dio` for JSON and ExoPlayer/`video_player` for the URLs.

## Hosts

| Host | Purpose | CF challenge? |
|---|---|---|
| `https://reelfren.com` | Next.js SSR site (pages have the data server-rendered, including the first `<video src>`) | **YES**. Needs a browser. The app doesn't need this host. |
| `https://api.reelfren.com` | JSON API (`/api/home`, `/api/search`, `/api/detail`, `/api/video`, `/api/subtitle/*`, `/api/proxy/*`) | **NO**. Plain HTTP works. It is still fronted by Cloudflare (server: cloudflare, LiteSpeed origin). |
| `https://proxy.dramafren.org` | Media/subtitle pass-through proxy (`/api/proxy/{provider}?url=...`) | NO |
| Provider CDNs (listed below) | Actual media | NO |

**Relative URL rule** (copied from the site's `backendApiAssetUrl()`): any `videoUrl`, `qualityList[].url` or `subtitles[].url` that starts with
- `/api/proxy/` → prefix it with `https://proxy.dramafren.org`
- any other `/api/` path → prefix it with `https://api.reelfren.com` (api.reelfren.com also serves `/api/proxy/*`, so either host works)
- `http(s)://` → use it as is.

## Common object: Drama (list item)

```json
{"id":"2100522336622321665","provider":"netshort","title":"The Beauty Blind Box",
 "cover":"https://awscover.netshort.com/...webp","intro":"NetShort drama","episodes":30}
```
- `id` is an opaque **string** and its format varies by provider: numeric (`netshort` `2100522336622321665`, `dramabox` `42000023836`, `vibeshort` `859882`), alphanumeric (`wetv` `tn57v4wrc6xihiz`, `dramawave` `VJVg61jsOk`), UUID (`mydrama`), slug (`shorten` `slave-to-emperor`, `iqiyi` `fated-hearts-episode-1-1ggw7a63yug`), or id plus slug (`filmbox` `7499050641378399408_the-scandal-mlNU8SlJXV8`). Always key on the pair **(provider, id)** and pass `id` back exactly as received. Don't try to parse the site's `/drama/{provider}/{id}-{slug}` URLs, because ids can contain `-` and `_`.
- `episodes` can be `0` (for example aniboy movies or unknown).
- `intro` is sometimes a placeholder such as "NetShort drama" or "Anamana search result". `/api/detail` often has the real synopsis.
- `cover` is an absolute URL on the provider CDN or `wsrv.nl`. It loads without a Referer (the site uses `referrerPolicy=no-referrer`).
- Duplicates happen across pages. Dedupe on `provider:id`, which is what the site does.

## Providers (36 keys seen)

`anamana aniboy blinkdrama bonustv candyjar cubetv dramabox dramanova dramawave filmbox flareflow flextv flextv2 freereels happyshort iqiyi joyreels kalostv melolo moboreels moviebox movieboxshorts mydrama netshort pinedrama rapidtv rapidtv2 raptdrama reelife reelshort sereal shorten storyreel vibeshort vigloo wetv`
(aniboy and bstation are anime providers. wetv, iqiyi and filmbox are long-form C-drama and movie providers. The rest are vertical short dramas.)

---

## 1. Feed / home / explore — `GET /api/home`  (NOT CF)

```
GET https://api.reelfren.com/api/home?offset=0&lang=en
GET https://api.reelfren.com/api/home?provider=netshort&offset=1&lang=en
GET https://api.reelfren.com/api/home?provider=sereal&feed=latest&offset=0&lang=en
GET https://api.reelfren.com/api/home?provider=aniboy&category=anime&offset=0&lang=en
```
| param | meaning |
|---|---|
| `offset` | **Page index** (0, 1, 2, ...), not an item offset. The site increments it by 1. |
| `lang` | UI and catalog language (`en`, `id`, `es`, `pt`, `ar`, `zh`, `zh-hant`, ... ~60 codes). It changes the catalog. For example `lang=id` gives Indonesian netshort titles. |
| `provider` | optional; limits results to one provider (this is the per-provider listing) |
| `category` | optional, provider-specific tab. Values seen in the site's links: netshort/iqiyi/vigloo/happyshort=`home`, vibeshort/dramanova/freereels/kalostv/mydrama/reelife/movieboxshorts=`all`, flextv=`newest`, shorten=`releases`, pinedrama=`0`, aniboy/bstation=`anime`, wetv=`10240` (anime), moviebox=`1232643093049001320` |
| `feed` | optional, for example sereal `latest` |

Response: `{"offset":0,"data":[Drama, ...]}`. Fixtures: `reelfren_home_mixed_page0.json` and `reelfren_home_netshort_page1.json`.

Paging behavior:
- **No provider:** page 0 returns about **1,900** mixed items from 33 providers, a large blob of about 1 MB. Pages 1 and later return about 400–450 items each. Stop when `data` is `[]`. For a light home screen, prefer per-provider calls.
- **With provider:** usually **20 per page**. Keep going until `data` is `[]`.
  - wetv (298), filmbox (334), vibeshort (205), blinkdrama (203) and storyreel (230) return **everything on page 0** and `[]` from page 1 on.
  - **dramabox ignores `offset`** and returns the same 20 on every page. Use search to find more dramabox titles.
- `moviebox` currently returns HTTP 502, and `movieboxshorts` returns empty.
- Cache headers: `s-maxage=43200`, so the data is edge-cached for about 12 hours.

## 2. Search — `GET /api/search`  (NOT CF)

```
GET https://api.reelfren.com/api/search?q=love&lang=en&offset=0
GET https://api.reelfren.com/api/search?q=love&lang=en&offset=1&provider=netshort
```
| param | meaning |
|---|---|
| `q` | query text (required) |
| `lang` | as above |
| `offset` | **page index** 0, 1, 2, ... |
| `provider` | optional single provider |

Response (`reelfren_search_love_page0.json`):
```json
{"query":"love","count":7702,"hasMore":true,
 "data":[{"id":"1000294","provider":"anamana","title":"The Succubus's Love Counsel","cover":"https://acpi.dreamtechpte.com/...jpg","intro":"Anamana search result","episodes":30}, ...]}
```
- The unified search (no provider) fans out to every provider. Page 0 returned **820 items** for "love". Later pages returned about 500. Each provider contributes up to about 20–60 items per page. It takes about **2–15 s**, so show a spinner and use a timeout of 60 s or more.
- With `provider`, you get 20 per page. `count` is that provider's total. Stop when `hasMore=false` or `data=[]`. Some providers return everything at once (for example dramabox gave 10 with `hasMore:false`).
- `count` changes slightly between pages because it is recomputed. Treat it as approximate.

## 3. Detail + episode list — `GET /api/detail`  (NOT CF)

```
GET https://api.reelfren.com/api/detail?provider=netshort&id=2100522336622321665&lang=en
```
Response (`reelfren_detail_netshort.json`, trimmed):
```json
{"id":"2100522336622321665","provider":"netshort","title":"The Beauty Blind Box",
 "cover":"https://awscover.netshort.com/...webp","intro":"NetShort drama","episodes":30,
 "videos":[{"episode":1,"duration":0,"vid":"2100799661712711681","available":true},
           {"episode":2,"duration":0,"vid":"2100799661687582723","available":true}, ...]}
```
- `videos[]` is the episode list. Each entry has `episode` (1-based), `duration` (seconds, often 0), `vid` (the provider's internal episode id, for information only) and `available` (in every probe it was `true`, so it is **not** a reliable lock flag).
- **Placeholder / locked detection:** for some providers (vibeshort, storyreel, iqiyi, ...) the backend only knows the first N episodes. The rest are placeholders with `vid == str(episode)` and `duration == 0`, and `/api/video` returns **HTTP 502** for them. That happens on the real site too ("Video cannot be loaded"). Examples: vibeshort 859882 has eps 1–20 real and 21–40 placeholders, iqiyi has 39 of 77 as placeholders, and storyreel has 20 of 54. Mark those episodes as locked in the UI.
- `episodes` in detail can be larger than `videos.length`, and the site then shows the extra episodes. Use `max(episodes, videos.length)`.

## 4. Playback — `GET /api/video`  (NOT CF)

This is exactly what the watch page's JavaScript calls (`rL()` in chunk `3nzwk_i5adxu_.js`). The SSR watch page puts the same URL into `<video src>` (see `fixtures/reelfren_watch_netshort_ep1_video_tag.html`).
```
GET https://api.reelfren.com/api/video?provider=netshort&id=2100522336622321665&ep=1&lang=en&server=1&cv=v21
    optional: &refresh=1&rt=<epoch ms>   (force a fresh upstream resolve, which bypasses the backend cache)
    optional: &probe=hidden              (the site sends this for hidden episodes; it made no difference in tests)
headers the site sends: accept: application/json (not required)
```
`server`: only `1` exists in practice. The response always had `sourceServer:"1"`, and 2 and 3 returned the same data. `cv=v21` is a cache-version tag that the site always sends, so send it too.

Response (`reelfren_video_netshort_ep1.json`):
```json
{"title":"NetShort Episode 1","episodeNumber":1,"totalEpisodes":30,"locked":false,
 "videoUrl":"https://ns-aws-cdn.netshort.com/o8I63q...?a=0&auth_key=1790579424-...&mime_type=video_mp4...",
 "qualityList":[{"label":"MP4","url":"https://ns-aws-cdn.netshort.com/...","format":"mp4"}],
 "sourceServer":"1","subtitles":[]}
```
- `videoUrl` is the default. `qualityList[]` has `{label, url, format: "mp4"|"hls"|missing, size?, fallbackUrl?, kid?, dashManifest?}`. Where `format` is missing, detect HLS from `.m3u8` in the URL or `#EXTM3U` in the body. The labels are free text (`1080p`, `720p Backup`, `Server 1`, `SD H.264`, `540p H.265`, `Japanese`, ...).
- `subtitles[]` is `{label, url, srclang}`. The URL is often relative (`/api/proxy/wetv-subtitle?url=...` or `/api/subtitle/filmbox?url=...`), so apply the relative URL rule. The result is WebVTT (tested with wetv).
- It is playable when `videoUrl` is set or any `qualityList[].url` is set. It is locked when `locked:true` and there are no URLs.
- **Errors:** HTTP 502 with body `error code: 502` means the episode can't be resolved (placeholder or paywalled upstream). Retrying doesn't help (the result was consistent over several minutes). Treat it as locked. Fixture: `reelfren_video_vibeshort_ep30_locked.txt`.
- **URLs are signed and expire.** For example netshort `auth_key` is valid about 4–5 days, dramabox about 1.4 days, and kalostv `Expires` about **15 min**. Resolve right before playing and don't persist the URLs.

### Stream properties (all fetched with plain HTTP and **no Referer/Origin/Cookie**; Range gives 206)
- **MP4 (progressive):** netshort, dramabox (`*.1080p.wz`, still MP4), anamana, dramanova, flextv2, joyreels, moboreels, happyshort, reelife, sereal, rapidtv, rapidtv2, pinedrama (tiktokcdn), melolo (**HEVC/hvc1**, not encrypted).
- **HLS, clear (no `EXT-X-KEY`), TS segments:** wetv (Auto), vibeshort and storyreel (1080/720/480 variants; the m3u8 may be gzip-encoded, which is handled automatically), blinkdrama, reelshort, cubetv, kalostv, mydrama, raptdrama, shorten, flextv, flareflow, bonustv and aniboy (via proxy.dramafren.org), iqiyi (via `indocast.site` proxy).
- **HLS with fMP4 segments:** dramawave and freereels (mydramawave CDN), candyjar (**HEVC**, bunny CDN), vigloo (via proxy.dramafren.org).
- **No DRM anywhere in the tested set.** The site still has a leftover `melolo-sw.js` service worker and a `/api/melolo-key?kid=` ClearKey path for quality entries that carry `kid`, but the current melolo responses are plain MP4 with no `kid`. If a `kid` ever appears, fetch `GET https://api.reelfren.com/api/melolo-key?kid=<kid>`, which returns `{"key": ...}`, and use it as a ClearKey.

### Provider test matrix (2026-09-23; ep1 and the last episode for one title each; "OK" means the media bytes were fetched)
| provider | fmt | ep1 | last ep | notes |
|---|---|---|---|---|
| netshort | mp4 | OK | OK (32/32, 38/38) | |
| dramabox | mp4 1080/720/540 | OK | OK (52/52) | feed paging broken |
| wetv | hls + 11 subs | OK | OK | |
| vibeshort | hls 1080/720/480 | OK | **502 from ep21+** (placeholders) | |
| blinkdrama | hls | OK | OK (77/77) | |
| reelshort | hls | OK | OK (95/95) | |
| dramawave / freereels | hls fMP4 + subs | OK | OK | |
| anamana, dramanova, flextv, flextv2, joyreels, kalostv, moboreels, happyshort, reelife, sereal, rapidtv2, pinedrama, raptdrama, shorten, cubetv, candyjar, bonustv, aniboy, flareflow, melolo | mixed | OK | OK | rapidtv gave one transient 403 |
| storyreel, iqiyi | hls | OK | **502** (placeholders) | |
| vigloo | hls via proxy | OK | ep50 OK, ep54 502 | |
| mydrama | hls | OK | last ep: cloudfront 403 | |
| **filmbox** | mp4 via `indocast.site/api/proxy` | **FAIL** | FAIL | upstream returns `427/429`. It is broken on reelfren.com itself too ("MEDIA_ELEMENT_ERROR"). |
| moviebox / movieboxshorts | – | – | – | `/api/home` 502 / empty |

## 5. CF status summary

| Endpoint | CF-protected? | Auth / signature / crypto |
|---|---|---|
| `reelfren.com/*` pages and `/_next/static/*` | **Yes** (Turnstile / managed challenge) | n/a. Not needed by the app. |
| `api.reelfren.com/api/home` | No | none |
| `api.reelfren.com/api/search` | No | none |
| `api.reelfren.com/api/detail` | No | none |
| `api.reelfren.com/api/video` | No | none |
| `api.reelfren.com/api/subtitle/*`, `/api/proxy/*` | No | none |
| `proxy.dramafren.org/api/proxy/{provider}?url=` | No | none |
| media CDNs | No | pre-signed query strings only (from `/api/video`) |

CORS: the API returns `access-control-allow-origin: https://reelfren.com`. That doesn't matter for a native Flutter app, but it would block a Flutter **web** build, which would then need a proxy.

## 6. Rate limiting / anti-bot quirks
- 40 parallel `/api/video` calls (concurrency 10) all returned 200. There were no rate-limit headers and no UA filtering. The API is still behind Cloudflare, so a future WAF or Bot Fight rule could start challenging non-browser clients. Detect `403` + `text/html` + "Just a moment" and surface it.
- Occasional `502 error code: 502` (a Cloudflare-style body) happens for unresolvable episodes. Retry once on 502/503/504 at most, then mark the episode locked.
- `/api/search` without `provider` is slow (2–15 s). `/api/home` without `provider` is large (about 1 MB).
- Upstream proxies (`indocast.site` for filmbox and iqiyi) are fragile or rate-limited (filmbox is currently fully broken).
- HEVC streams (melolo, candyjar, and kalostv's "H.265" quality) won't play on older Android devices without HEVC decode. Prefer H.264 labels where there is a choice.

## Implementation recipe (Flutter)
1. Home: for each chosen provider, `GET /api/home?provider=P&offset=0&lang=en`. Infinite scroll with offset+1 until `[]`. Dedupe on `provider:id`.
2. Search: `GET /api/search?q=..&offset=N&lang=en` (optionally with `&provider=`). Infinite scroll until `hasMore=false` or `data=[]`.
3. Detail: `GET /api/detail?provider=P&id=ID&lang=en`. The episode grid is `1..max(episodes, videos.length)`. Grey out placeholders (`vid==str(episode) && duration==0`).
4. Play: `GET /api/video?provider=P&id=ID&ep=N&lang=en&server=1&cv=v21`. Resolve the URL with the relative URL rule. Pick `videoUrl` or a `qualityList` entry. Feed it to ExoPlayer with the HLS or progressive source based on `format`/`.m3u8`, with no extra headers. Load `subtitles[]` as WebVTT. On 502 or `locked`, show the episode as locked. If the player fails, retry once with `&refresh=1&rt=<ms>`, then try the next `qualityList` entry or its `fallbackUrl`.
