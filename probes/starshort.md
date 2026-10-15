# StarShort mirror: starshort.dramafren.org

Probed 2026-09-23. Uses the shortmax/dramafren PHP template (`template_dramafren_php.md`). The watch page is like
stardusttv's: the video URL is inlined as base64.
Client: `dramafren_more_client.py` (`Client("starshort")`). Fixtures: `fixtures/starshort_*`.

**Status: works, but only through a WebView, and some episodes are broken server-side (a stale signed URL is cached).**

## Hosts / Cloudflare
| Endpoint | CF? |
|---|---|
| `https://starshort.dramafren.org/index.php?…` (all pages) | **challenge** (403 `cf-mitigated: challenge`). **No CF-free twin found** (`cdn-starshort*`, `starshort.ngeshorts.fun` don't resolve). |
| `https://{bsyvideo,cfvideo}.wolftv.online/<dir>/<file>-sd.m3u8?auth_key=…` | none (plain curl) |
| segments `…/<file>-sd-0000N.ts` (relative, **no auth query needed**) | none |
| covers `https://bsy-cdp-img.wolftv.online/cdp/coverimg/…` | none |

The app must fetch every HTML page inside a WebView on `starshort.dramafren.org` (see the template's WebView recipe).

## Language
`lang` is **numeric**: 1 Chinese, 2 Trad. Chinese, **3 English** (default), 4 Indonesian, 5 Spanish, 6 Thai, 7 Japanese,
8 Korean, 9 German, 10 French, 11 Portuguese, 12 Arabic, 13 Turkish, 14 Russian, 15 Italian, 16 Vietnamese, 17 Polish.

## Feed
`GET index.php?page=home&p_hist={n}`. 12 cards per page. "Page 1 of 9". hasMore = a `Next »` link to `p_hist={n+1}`.
Card: `<a href="index.php?page=detail&amp;id=J5nP">` `<img src=COVER alt=TITLE>` `<h3>TITLE</h3>`. This is the global
"Recently Watched" list, not a catalogue.

## Search
`GET index.php?page=search_result&q={q}&lang=3` (fixture: `starshort_search.html`).
- Results follow `<h2 …>Search: "love"</h2>`. Each card is `<a href="index.php?page=detail&amp;id=l9V">` with `<h3>TITLE</h3>`.
- **Covers are always the placeholder** `https://placehold.co/600x900/...No+Cover`. Take the real cover from detail.
- 10 results, no pager in the markup. Treat hasMore as false. The client sends `s_page` like shortmax, but that's untested.

## Detail
`GET index.php?page=detail&id={id}`. ids are short base62-ish strings (`J5nP`, `l9V`, `zdo`, `AX0`), case-sensitive.
- `<h1>` title; cover `<img … alt="{title} Poster">`; `<span>Total: 45 Eps</span>`; synopsis = first `<p>` after the h1.
- episodes `a[href*=page=watch]` → `index.php?page=watch&id=J5nP&ep={n}&lang=3&server=1`

## Playback
`GET index.php?page=watch&id={id}&ep={n}&lang=3&server={1|2}` (CF, WebView). The inline script contains:
```js
const totalEp = 45; const dramaId = "J5nP"; const currentLang = 3; const currentServer = 1;
const availableQualities = [{"quality":"Auto (HLS)","url":"https:\/\/bsyvideo.wolftv.online\/…-sd.m3u8?auth_key=1790135701-0-0-6d18…"}];
const encryptedSrc = "aHR0cHM6Ly9ic3l2aWRlby53b2x…";   // base64 of the same m3u8 URL
```
Regex: `const encryptedSrc = "([^"]*)"` → base64-decode. `availableQualities` is plain JSON.
- HLS, MPEG-TS (0x47), no `EXT-X-KEY`, no DRM, no headers. `#EXT-X-TARGETDURATION:10`, and segments are relative to the playlist.
  **Verified**: `zdo` ep1 (cfvideo) and `AX0` ep1 (bsyvideo) m3u8 → 200. The `AX0` segment is 1 MB with a `G@` TS header.
- `auth_key=<unix EXPIRY>-0-0-<md5>` is Aliyun-type-A signing, and the first field is the **expiry**. Fresh URLs had
  expiries +6.5 h and +48 h.
- **Gotcha: the mirror caches the resolved URL server-side and keeps serving it after it expires.** For `J5nP`
  (a popular title), eps 1/2/20/45 on server 1 and ep 1 on server 2 all carried an expiry in the past, and every one
  → **403 "ERROR: ACCESS DENIED"** (with or without a Referer). Server 2 ep 45 returned an empty URL.
  `zdo` ep 30 also returned an empty `encryptedSrc`. The page has no refresh parameter.
  App rule: parse the `auth_key` expiry. If it's in the past or the src is empty, try the other `server`. Otherwise show
  "episode unavailable" and retry later.
- Late/locked episodes: ep 45 of J5nP returned a URL (expired, see above). Uncached late episodes were not verified.
- The client-side 60 s "watch the previous episode first" overlay (localStorage `starshort_viewed_{id}_{ep}`) doesn't matter
  when the HTML is parsed directly.

Fixtures: `starshort_home.html`, `starshort_search.html`, `starshort_detail.html`, `starshort_watch.html`,
`starshort_AX0_ep1.m3u8`.
