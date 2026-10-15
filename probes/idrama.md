# idrama.dramafren.org — "IDRAMA Player / iDrama Unlocked"

Template: see `template_dramafren_php.md`. Client: `dramafren_client.py` (`Dramafren("idrama")`).
Fixtures: `fixtures/idrama_{home,home_cdnhost,search,detail,watch_ep1}.html`,
`fixtures/idrama_watch_stream.json`, `fixtures/idrama_proxy_video_playlist.m3u8`.

## CF status
| Endpoint | CF? |
|---|---|
| `idrama.dramafren.org/*` | CF interactive (403). `idrama.ngeshorts.fun` 301s back here. |
| **`cdn-idrama.dramafren.org/index.php?...`** (whole app, incl. `action=watch_stream`, `action=proxy_video`) | **CF-free** |
| `cdn-idramav2.dramafren.org` | 200 (another CF-free twin, not probed further) |
| `v-a.idrama.video/...m3u8?ts=&secret=` + `.ts` | CF-free, no headers |
| AES key `api.idrama.video/shorts/open/drm/kds/api/v1/keys?source=jarvis&ak=…` | CF-free, 16 raw bytes, no auth |
| covers `p.idrama.video/group1/...jpg` | CF-free |

**Base: `https://cdn-idrama.dramafren.org/index.php`.** No WebView is needed.
Gotcha: the "Recently Watched" feed is stored **per host**. cdn-idrama has only about 2 items, while the front
host shows `Page 1 of 9`. Calling `action=watch_stream` also adds the drama to the feed of the host you called. For a richer feed you'd have to use the front host through a WebView. Search
works fully on the cdn host.

## Endpoints
- **Feed**: `?page=home&p_hist={n}&lang={lang}` returns 12 cards per page (`Continue Watching`), `« Prev` / `Next »` with `p_hist=n±1`.
- **Search**: `?page=search&q={q}&lang={lang}` returns up to 20 cards with an `N Eps` badge. No paging.
- **Detail**: `?page=detail&id={12-digit, e.g. 100000644441}&lang={lang}`
  - `<h1>` title, `<span> 20 Episodes </span>`, `<p>` synopsis (full text), JSON-LD `TVSeries` (name/image/description).
  - episodes: `index.php?page=watch&id={id}&ep={n}&lang={lang}`
- **Watch page**: `?page=watch&id=&ep=&server={1|2|3}&lang=`. It only holds the JS; the video comes from the JSON call below.

## Playback: `action=watch_stream` (JSON)
```
GET https://cdn-idrama.dramafren.org/index.php?action=watch_stream&id=100000644441&ep=1&server=1&lang=en[&_=<ms>]
{"ok":true,
 "video_url":"https://cdn-idrama.dramafren.org/index.php?action=proxy_video&url=https%3A%2F%2Fv-a.idrama.video%2F864b…%2F68de…m3u8%3Fts%3D1790181457%26secret%3D4bef…&playlist=1",
 "subs":[], "server_no":1, "server_label":"Server 1", "current_ep":1, "total_eps":20}
```
- `ok:false` comes with an `error` string. The player JS also uses `data.server_no` / `server_label`.
- `video_url` is a proxy URL. Its `url=` query param is the **direct** signed m3u8
  (`https://v-a.idrama.video/{a}/{b}.m3u8?ts={expiry}&secret={sig}`). Both work with plain curl. The proxied playlist
  rewrites the key URI through proxy_video and makes segment URLs absolute.
- HLS media playlist, 5 s MPEG-TS, `#EXT-X-KEY:METHOD=AES-128,URI="https://api.idrama.video/…/keys?source=jarvis&ak=…",IV=0x000…0`.
  This is standard HLS AES-128, so ExoPlayer and hls.js decrypt it natively. Verified: the key is 16 B and decrypted segment byte 0 is 0x47.
- `ts` looks like an expiry about 2 h ahead (the sample had ts = now + 1.9 h). Repeated calls return the **same ts/secret**,
  even with the site's own cache-buster `&_=<ms>`, so the server caches or rotates it on its own clock.
  Resolve right before playback and re-resolve on HTTP 403.
- `subs[]` items: `{url, code|language, ...}`. The site loads them as `?action=proxy_sub&url=<enc url>`. They were empty in the sample.
- Late episodes are **unverified** (permission layer). The UI label reads "IDRAMA VIP Unlocked".

## Lang
`id en ja ko es pt th`

## Verified run (2026-09-23, plain HTTP only)
search "love" 20 items; detail "Love after Layoffs" 89 eps; watch_stream ep1 returned an m3u8, the key fetched, and the
first segment decrypted to MPEG-TS.
