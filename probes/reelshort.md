# reelshort.dramafren.org — "ReelShort Player"

Template: see `template_dramafren_php.md`. Client: `dramafren_client.py` (`Dramafren("reelshort")`).
Fixtures: `fixtures/reelshort_{home,search,detail,watch_ep1}.html`.

## CF status
| Endpoint | CF? |
|---|---|
| `reelshort.dramafren.org/*` | **CF interactive, 403 to curl.** No CF-free twin found. Use the WebView. |
| `v-mps.crazymaplestudios.com/...m3u8` + `.ts` | CF-free, no headers |
| covers `v-img.crazymaplestudios.com/v-images/...jpg` | CF-free |

## Endpoints (base `https://reelshort.dramafren.org/index.php`)
- **Feed**: `?page=home&p_hist={n}` returns 12 "Recently Watched" cards, `Page 1 of 9`, `« Prev` / `Next »` links (`p_hist=n±1`).
  The cards carry no `lang` in the href, and titles are in whatever language the viewer watched (pt, ar, ...).
- **Search**: `?page=search_result&q={q}&lang={lang}` returns up to 20 cards and **no paging** (no pager markup).
  `lang` picks the catalogue language. The cards have no episode badge.
- **Detail**: `?page=detail&id={24-hex}` (no lang param in the site's own links).
  - `<h1>` title, `<span>Total: 51 Eps</span><span>Server: Primary</span>`, `<p>` synopsis (real text),
    JSON-LD `Article` with `headline/image/description`.
  - episodes: `index.php?page=watch&id={id}&ep={n}`
- **Watch**: `?page=watch&id={id}&ep={n}&server={1|2}`

## Playback
The inline script in the watch HTML contains:
```js
const maxEp = 51; const dramaId = "6ab09f3259b059c7850814a9"; const currentServer = 1;
const availableQualities = [{"quality":"720p","hash64":"<b64 url -sd.m3u8>"},
                            {"quality":"540p","hash64":"<b64 url -ld.m3u8>"},
                            {"quality":"0p","hash64":"<b64 url .m3u8>"}];
const videoSrc = atob("<b64 of the 540p url>");
```
Parse `const availableQualities = (\[.*?\]);` as JSON, then base64-decode each `hash64`.
The default is `const videoSrc = atob\("([^"]*)"\)`.
Example: `https://v-mps.crazymaplestudios.com/vod-112094/3099bf66…/957c8b69…-e23b1e85…-ld.m3u8`.
- Media playlist, 5 s MPEG-TS segments (relative), no key. Plain curl works.
- The `0p` entry is a master/multi-track playlist. The player JS picks English subtitle tracks from HLS `subtitleTracks`, so subtitles come in-stream there.
- server=2 is untested. Late episodes are **unverified** (the permission layer denied fetching ep 48).

## Lang
`en in zh zh-TW ja ko th vi ru fr de it es hi pt ar ms tr pl` (search form). Same codes as `langMap` in the player JS.

## Verified run (2026-09-23)
feed 12 items has_more; search "love" 20 items; detail "You've Been Replaced, First Love" 74 eps;
ep1 m3u8 on v-mps.crazymaplestudios.com, first segment 390 KB MPEG-TS.
