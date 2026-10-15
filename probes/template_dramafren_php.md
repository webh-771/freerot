# Shared template: dramafren PHP "player" mirrors

Probed 2026-09-23. Applies to **stardusttv, dramawave, reelshort, idrama** (`<site>.dramafren.org`),
and is the same template family as shortmax (see `../API_NOTES.md`).
Reference client: `probes/dramafren_client.py` (runs end to end for all four, ep 1).
Per-site specs: `stardusttv.md`, `dramawave.md`, `reelshort.md`, `idrama.md`.

## Hosts and Cloudflare

| Site | Front host (CF interactive challenge) | CF-free twin host | App transport for HTML/JSON |
|---|---|---|---|
| stardusttv | stardusttv.dramafren.org | **none found** | WebView on the front origin |
| reelshort | reelshort.dramafren.org | **none found** | WebView on the front origin |
| dramawave | dramawave.dramafren.org | **cdn-dramawave.dramafren.org** | plain HTTP |
| idrama | idrama.dramafren.org | **cdn-idrama.dramafren.org** (also cdn-idramav2) | plain HTTP |

- The front hosts answer plain HTTP with `403` + "Just a moment..." (`cType: 'interactive'`) on every path,
  including `robots.txt`, `favicon.ico` and `index.php?action=...`.
- `cdn-dramawave` and `cdn-idrama` serve the *entire* PHP app (home, search, detail, watch, action=...)
  with no challenge. They are still Cloudflare-proxied (`server: cloudflare`), just without the WAF rule.
- For stardusttv/reelshort I checked DNS for `cdn-<site>`, `cdn-<site>v2/v3`, `<site>v2/v3`, `proxy*`,
  and crt.sh (wildcard cert, 52 names listed). None resolves to a CF-free copy. `idrama.ngeshorts.fun`
  301s back to the CF front, so there's no non-CF origin like shortmax's.
- **Stream URLs (m3u8, segments, keys, subtitles) are CF-free on every site** and need no headers:
  no Referer, Origin or cookie.

### WebView recipe (stardusttv, reelshort)
Load `https://<site>.dramafren.org/index.php` once in a hidden WebView. It passes the challenge by itself,
and that sets `cf_clearance` on `.dramafren.org`. Then run
`evaluateJavascript("fetch('index.php?page=...').then(r=>r.text())")` and parse the returned HTML
natively. `dramafren_client.BrowserFetcher` does exactly this through Playwright/CDP.
The pages also inject ad and popup scripts (484r.com, dd133.com, otieu.com popups). Block popups
(`window.open`) in the WebView.

## Page map (all `GET index.php?...`, server-rendered HTML)

| Purpose | stardusttv | dramawave | reelshort | idrama |
|---|---|---|---|---|
| feed (Recently Watched) | `hp={n}` | `hp={n}` | `page=home&p_hist={n}` | `page=home&p_hist={n}&lang=` |
| search | `page=search_result&q=&lang=&p={n}` | `q=&lang=` (no `page`) | `page=search_result&q=&lang=` | `page=search&q=&lang=` |
| detail | `page=detail&id=&slug=&lang=` | `page=detail&id=&lang=` | `page=detail&id=` | `page=detail&id=&lang=` |
| watch | `page=watch&id=&slug=&ep=&sv={1,2}&lang=` | `page=watch&id=&ep=&server={1,2,3}&lang=` | `page=watch&id=&ep=&server={1,2}` | `page=watch&id=&ep=&server={1,2,3}&lang=` |
| video URL lives in | watch HTML `const encryptedSrc="<b64>"` | watch HTML `var src="..."` | watch HTML `availableQualities` / `videoSrc=atob("...")` | **JSON** `action=watch_stream` |
| id format | numeric `22901` + slug | 10-char alnum `ticRNLEglC` | 24-hex `6ab09f3259b059c7850814a9` | 12-digit `100000644441` |
| lang values | en_US zh_CN ja_JP ko_KR es_ES zh_TW id_ID th_TH pt_BR fr_FR de_DE ar_AE vi_VN tr_TR ru_RU | en-US id-ID zh-CN zh-TW ja-JP ko-KR es-MX pt-PT fr-FR ru-RU de-DE vi-VN it-IT tr-TR ms-MY th-TH tl-PH hi-IN ar-SA | en in zh zh-TW ja ko th vi ru fr de it es hi pt ar ms tr pl | id en ja ko es pt th |

Hrefs in the HTML are entity-escaped (`&amp;`), so unescape them before parsing query strings.

## Shared markup

**Card** (feed and search results), identical on all four sites:
```html
<a href="index.php?page=detail&amp;id=ID[&amp;slug=SLUG][&amp;lang=LANG]" class="...">
  <div class="aspect-[3/4] ..."><img src="COVER" ...>
     [idrama search only: <div class="absolute top-2 right-2 ...">89 Eps</div>]</div>
  <div class="p-3|p-4"><h3 class="...">TITLE</h3>
     [dramawave search: <span>40 Eps</span><span>★ N/A</span>]
     [feed: <span>Watch|Watch Now|Continue Watching</span>]</div>
</a>
```
Selector: `a[href*="page=detail"]`, then `img[src]` and `h3`. The id comes from the href query.
Remove duplicate ids.

**Feed** = the global "Recently Watched" list, i.e. whatever any visitor last watched on that host.
It is not a catalog. Watching an episode through `page=watch` pushes that drama to the top.
Only parse after the text `Recently Watched`. Page size is 12 (24 on stardusttv).
hasMore = there is an `<a ...>Next »</a>` whose href has `hp|p_hist = n+1`.
The pager text reads `Page 1 of 9`. Dramawave writes it as `Page <span>1</span> of 25`.

**Detail**:
- `<h1>` holds the title.
- The cover is the last `<img src>` before the `<h1>`, or `og:image`.
- The first `<span>` after the h1 holds `Total: N Eps` (idrama: `N Episodes`).
- The synopsis is the first `<p>` after the h1. dramawave often leaves it empty, and stardusttv always
  shows the placeholder "Full episodes available.". reelshort and idrama also have JSON-LD `description`.
- Episode list: `a[href*="page=watch"]` with `ep=1..N`. **Every episode is listed, with no lock markers.**

**Watch** loads hls.js from jsdelivr. The episode's video URL is resolved server-side, either embedded in
the HTML or returned by the idrama JSON endpoint. None of the sites has a separate video_server API.

## Playback summary

| Site | Stream | Container | Encryption | Plain curl |
|---|---|---|---|---|
| stardusttv | `acdn-v.stardust-tv.com/prod/{id}/{ep}/{hash}.m3u8` | HLS, MPEG-TS | none | yes |
| reelshort | `v-mps.crazymaplestudios.com/...{-sd,-ld,}.m3u8` (3 qualities) | HLS, MPEG-TS | none | yes |
| dramawave | `video-v6.mydramawave.com/vt/.../h264-*.m3u8` (master, 1080/720/..., separate AAC audio group) | HLS, fMP4 (`EXT-X-MAP` init.mp4, avc1, no encv/pssh) | none | yes |
| idrama | `v-a.idrama.video/...m3u8?ts=&secret=` (signed, `ts` = expiry ≈ +2 h) | HLS, MPEG-TS | **AES-128** (standard HLS; the key URL is CF-free and needs no auth, IV 0) | yes |

Any HLS player (ExoPlayer/media_kit) plays all four directly. No DRM (Widevine/CENC) anywhere.

## Late / locked episodes: NOT verified
I didn't get to fetch a late episode. The tool permission layer denied those requests (see the per-site
notes). What the code shows:
- Detail pages link every episode with no lock UI. The idrama player labels itself "IDRAMA VIP Unlocked".
- stardusttv's only gate is client-side. For ep > 1 the page JS checks
  `localStorage["stardust_viewed_{id}_{ep-1}"]` and otherwise shows a 60 s wait overlay. The stream URL
  is already in the HTML (`encryptedSrc`) either way.
- Test ep N > 10 before relying on it: `python dramafren_client.py`, then `stream(id, 40)`.
