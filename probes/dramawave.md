# dramawave.dramafren.org — "DramaWave Unlocked"

Template: see `template_dramafren_php.md`. Client: `dramafren_client.py` (`Dramafren("dramawave")`).
Fixtures: `fixtures/dramawave_{home,home_cdnhost,search,detail,watch_ep1}.html`, `fixtures/dramawave_master.m3u8`.

## CF status
| Endpoint | CF? |
|---|---|
| `dramawave.dramafren.org/*` | CF interactive (403) |
| **`cdn-dramawave.dramafren.org/index.php?...`** (same app, every page and action) | **CF-free, plain GET** |
| `video-v6.mydramawave.com/vt/...` m3u8 / init.mp4 / .mp4 segments / .srt | CF-free, no headers |
| `cdn-dramawave.dramafren.org/proxy?url=<enc m3u8>` (the "proxyRescueSrc" fallback) | CF-free |
| `cdn-dramawave.dramafren.org/index.php?proxy_sub=<b64 srt url>&ext=.vtt` returns WEBVTT | CF-free |
| covers `static-v1.mydramawave.com/vt/prod/cover/...` | CF-free |

**Use `https://cdn-dramawave.dramafren.org/index.php` as the base for everything.** No WebView is needed.
Feed data is shared with the front host: `Page 1 of 25` on both.

## Endpoints
- **Feed**: `?hp={n}` returns 12 "Recently Watched" cards (href `page=detail&id=X&lang=xx-XX`),
  pager `Page <span>1</span> of 25` + `<a href="index.php?hp=2#recent-watched">Next »</a>`.
- **Search**: `?q={q}&lang={lang}`. There's **no `page=` param**: the form is just q + lang.
  Returns up to 20 cards with `<span>40 Eps</span>`. There's no paging (`p`, `s_page` and `hp` all return the same 20).
  Result order varies between calls.
- **Detail**: `?page=detail&id={10-char alnum, e.g. ticRNLEglC}&lang={lang}`
  - `<h1>` title, `<span>Total: 35 Eps</span><span>ID: ticRNLEglC</span>`, the `<p>` synopsis is often empty,
    and the cover comes from `<img alt="Watch … English Sub">` / `og:image`. JSON-LD is `NewsArticle` (headline/image only).
  - episodes: `index.php?page=watch&id={id}&ep={n}&lang={lang}`
- **Watch**: `?page=watch&id={id}&ep={n}&server={1|2|3}&lang={lang}`

## Playback
Inline script in the watch HTML:
```js
var src = "https://video-v6.mydramawave.com/vt/d5599c56-…/h264-2ed70c28-….m3u8";
const proxyRescueSrc = "https://cdn-dramawave.dramafren.org/proxy?url=https%3A%2F%2Fvideo-v6…m3u8";
const totalEp = 35; const dramaId = "ticRNLEglC"; const currentServer = 1;
const subtitleOptions = [{"lang_code":"pl-PL","label":"Polish","url":"?proxy_sub=aHR0cHM6Ly92aWRlby12Ni5teWRyYW1hd2F2ZS5jb20vdnQvMjM1NzIv….c3J0"}, …];
const defaultSubtitleIndex = 5;
const qualityOptions = [{"label":"HLS","url":"<same m3u8>"}];
```
- Regexes: `var src = "([^"]*)"`, `const proxyRescueSrc = "([^"]*)"`, `const subtitleOptions = (\[.*?\]);` (JSON).
- **Stream**: HLS master (`EXT-X-STREAM-INF` 1080x1920 / 720x1280 / …, codecs avc1+mp4a) with a separate
  `EXT-X-MEDIA TYPE=AUDIO` AAC rendition. Variants are **fMP4** (`EXT-X-MAP` init.mp4 + `_N.mp4` segments),
  with **no EXT-X-KEY and no encv/pssh in init**, so clear. ExoPlayer plays it directly.
- **Subtitles**: `url` is relative to the index.php host. Use
  `https://cdn-dramawave.dramafren.org/index.php?proxy_sub=<b64>&ext=.vtt` to get WEBVTT. Alternatively
  base64-decode `proxy_sub` to get the raw `.srt` on video-v6.mydramawave.com.
- The server picker offers server=1/2/3. Only 1 was tested.
- Late episodes are **unverified**. The permission layer denied this probe.

## Lang
`en-US id-ID zh-CN zh-TW ja-JP ko-KR es-MX pt-PT fr-FR ru-RU de-DE vi-VN it-IT tr-TR ms-MY th-TH tl-PH hi-IN ar-SA`

## Verified run (2026-09-23, plain HTTP only)
feed 12 items has_more; search "love" 20 items; detail "Heirless Wolf King…" 40 eps;
ep1 master m3u8, then variant, then a 180 KB fMP4 segment; subtitle proxy returns valid WEBVTT.
