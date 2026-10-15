# dramabox.dramafren.org ("Dramabox Unlocked")

Template: `template_dramafren_unlocked.md`. Client: `dramafren_player_client.py` (`DramafrenClient("dramabox", cf_clearance=..., user_agent=...)`).
Fixtures: `fixtures/dramabox_{home,search,detail,watch}.html`, `dramabox_get_video_{sv1,sv2,error}.json`.

**Status: works.** Playback is CF-free. HTML (feed/search/detail) is **CF-only**: there's no CF-free twin, so use the WebView or cf_clearance path.

## CF status per endpoint
| Endpoint | CF? |
|---|---|
| `https://dramabox.dramafren.org/index.php?page=*` | **CF challenge** → WebView fetch, or cf_clearance + the same UA |
| `https://cdn-dramabox.dramafren.org/index.php?action=get_video…` (+ `cdn-dramaboxv2`) | CF-free, `ACAO: *` |
| `cdn-dramabox…?action=proxy_sub&url=` | CF-free (WEBVTT) |
| `cdn-dramabox` with any other action/page | 404 (CF rule); `proxy_stream` gives 503 "Captain API disabled" |
| `hwztakavideoto.dramaboxdb.com/*.mp4` | CF-free, no headers, Range OK |

## Feed / search / detail
- Feed: `https://dramabox.dramafren.org/index.php?page=home&p_hist={n}`. 12/page, "Page n of 9".
  Card href: `index.php?page=detail&id=42000027929&lang=en&slug=betrayed-broken-...` (lang may be `es` etc.).
- Search: `index.php?page=search_result&q=love&lang=en`. Single page (~10-21 results). The cards have no episode badge.
  Cover `…/{id}.jpg?t=…&image_process=resize,h_300`.
- Detail: `index.php?page=detail&id={id}&lang={lang}` (slug optional). `Total: 80 Eps` + a tags span
  (`Revenge, Betrayal, …`). Episodes are `ep=1..N`, labels `Ep 1`.

## Playback
The watch page JS has `videoEndpointUrls = ["https://cdn-dramabox.dramafren.org/index.php?action=get_video&id=…&ep=1&lang=en&sv=1", "https://cdn-dramaboxv2…same"]`.
It tries them in order with a 10 s timeout and `Accept: application/json`.
```
GET https://cdn-dramabox.dramafren.org/index.php?action=get_video&id=42000027929&ep=80&lang=en&sv=1
{"ok":true,"videoUrl":"https://hwztakavideoto.dramaboxdb.com/068407f0…/6ab33fc3/90/9x2/…/701632609_1/701632609.720p.wz.h264.mp4",
 "subtitles":[],"qualities":[{"quality":"Server 1 720p","url":…},{"quality":"Server 1 1080p",…},{"quality":"Server 1 540p",…}],
 "activeVideoServer":1,"sourceLabel":"Video Isolated Server 1","isAuto":false,"isHls":false,"nativeNoCors":false}
error: {"ok":false,"error":"Video unavailable"}
```
- Plain H.264 **MP4**, no DRM. `curl -r 0-31` returns 206 `ftyp isom`. The late episode (80/80) resolves, so there's no paywall.
- `sv`: 1 = isolated server (use this). `cdn-dramabox` only serves sv=1; sv=2/3 there return an error.
  On `cdn-dramaboxv2`, sv=2 = a third-party `http://drabox.dotkosong.web.id/api/v1/stream?u=…` proxy of an `.encrypt.mp4` (avoid),
  and sv=3 = auto-fallback to server 1.
- Player rule from the JS: `isHls` true → hls.js; `.mp4` or `seg=` → native. For the app: `isHls ? HLS : progressive`.
- URL path embeds a hex timestamp (`6ab33fc3`). Resolve right before playing and don't cache the URL for long.
- Subtitles: `subtitles[].url` + `subtitleLanguage` → `cdn-dramabox/index.php?action=proxy_sub&url=<enc>`. Empty in every sample.

## Gotchas
- `lang` goes into get_video. Use the card's lang (some titles are `es`).
- No CF-free HTML origin exists. I checked `cdn-dramabox(v2)` with page/action variants, `dramaboxv2` (CF), and `dramaboxv3`/`cdn-dramaboxv3` (no DNS).
