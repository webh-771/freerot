# shortwave.dramafren.org — probed 2026-09-23

**Status: WORKS.** All episodes resolve, including `is_free:0` ones (paywall bypassed). Plain HLS, **HEVC**.
The upstream is the ShortsWave app (`s.shortswave.com`, `api.shortswave.com`, `v.shortswave.com`).

## Architecture
A PHP page with an inline-JS SPA calling `GET https://shortwave.dramafren.org/?api_route=<route>&lang=<lang>&...`
The JSON is plain, with no request signing. The play URL comes base64-encoded (just `atob`).

| Host | CF | Notes |
|---|---|---|
| `shortwave.dramafren.org/?api_route=*` | **CF managed challenge** | WebView, or reuse `cf_clearance` + same UA from Dart HTTP (verified working) |
| `s.shortswave.com` (covers .webp) | CF-free | |
| `api.shortswave.com/v1/play/<chapter_id>/v.m3u8?auth_key=…` | **CF-free** (Cloudflare-fronted but no challenge; `access-control-allow-origin: *`) | plain GET, no headers |
| `v.shortswave.com/video/...ts?X-Goog-*` (segments) | CF-free | GCS V4 signed URLs, `X-Goog-Expires=21600` (6 h) from m3u8 fetch time |

## Languages
`en, in, id, ms, th, es, fr, de, ar, tr, ru, pt, ja, ko` (`in` and `id` return the same Indonesian catalogue). Ids appear to be global (24-hex Mongo ObjectIds).

## 1. Feed: `?api_route=list&lang=en&page=N`
```json
{"dramas":[{"id":"6ab3b019da8012969fdd38a4","cover":"https://s.shortswave.com/image/cover/36110.webp","title":"Astroward","episodes":35}, …]}
```
- 24 per page, newest first. en has about 100 pages (page 100 → 16 items).
- **Past the end the server repeats the last page (page 101 = page 100), so it never returns empty.** has_more = `dramas.length == 24`. Dedupe by id anyway.
- There's no `total` and no description in list items.

## 2. Search: `?api_route=search&lang=en&q=<q>&page=1`
Same shape as list. It returns at most **20** hits and ignores `page` (page 2 = page 1). Single letters give 0 hits.

## 3. Detail: `?api_route=detail&lang=en&id=<id>`
```json
{"drama":{"id":"6ab3b019…","title":"Astroward","description":"…","cover":"https://s.shortswave.com/image/cover/36110.webp"},
 "episodes":[{"index":1,"chapter_id":"6ab3b022da8012969fdd38b1","is_free":1}, … {"index":35,"chapter_id":"6ab3b028da8012969fdd38ba","is_free":0}]}
```
The episode list isn't sorted by chapter_id; use `index`, which is 1-based.

## 4. Playback: `?api_route=unlock&lang=en&drama_id=<id>&chapter_id=<chapter_id>`
```json
{"code":0,"data":{"chapter_id":"6ab3b028…","chapter_index":35,"chapter_duration":78,"chapters":35,"price":0,
  "is_completed":1,"drama_tags":[…],"sublist":[],"play_url_720p":"",
  "play_url_encoded":"aHR0cHM6Ly9hcGkuc2hvcnRzd2F2ZS5jb20vdjEvcGxheS82YWIzYjAyOGRhODAxMjk2OWZkZDM4YmEvdi5tM3U4P2F1dGhfa2V5PTcyMHBhY2QxYmFhNWUwMWE0MjVhOGM5ZjNhYjgxODlkNDRhZg=="}}
```
`atob(play_url_encoded)` = `https://api.shortswave.com/v1/play/6ab3b028da8012969fdd38ba/v.m3u8?auth_key=720pacd1baa5e01a425a8c9f3ab8189d44af`
- The `auth_key` is required. Removing it or using a fake one gets `404 not found`. It appears stable per chapter (`720p` + 32 hex), but it isn't derivable client-side, so always call unlock.
- The m3u8 is a plain HLS v3 media playlist with no `EXT-X-KEY`. It holds about 8 × ~12 s MPEG-TS segments (`0x47` sync), video **HEVC 720x1254** and AAC audio. ExoPlayer plays HEVC on most Android devices. Very old or low-end devices may fail (the site warns about the same codec).
- Tested ep 1 (free) and ep 35 (`is_free:0`, last). Both the m3u8 and the segments return bytes via plain curl.
- Subtitles: `sublist[{url, language, languageId}]` is usually empty (burned-in subs). The site proxies any it gets via `?api_route=subtitle&url=<enc>`.
- Bad chapter_id → `{"error":"Failed to fetch data and no cache available"}`.
- The site has a client-only "watch 60 s of the previous episode" gate in localStorage. It's not server-enforced, so ignore it.

## Files
`fixtures/shortwave_{list,search,detail}.json`, `shortwave_unlock_locked_ep35.json`, `shortwave_playlist_ep35.m3u8`, `shortwave_client.py`.
