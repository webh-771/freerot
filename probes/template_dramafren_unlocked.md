# Shared template: "<Brand> Unlocked" dramafren player (dramabox / goodshort / netshort / flickreels)

Probed 2026-09-23. All four sites run the same PHP app (titled "<Brand> Unlocked" / "<Brand> Player"): Tailwind,
server-rendered HTML, `index.php?page=home|detail|watch|search_result`. It's the same family as shortmax
(`../API_NOTES.md`) and the stardusttv/dramawave/reelshort/idrama template (`template_dramafren_php.md`).
Only the **playback endpoint** differs per site.

Reference client: `probes/dramafren_player_client.py`. It uses only the stdlib and runs end to end for all four:
`python dramafren_player_client.py [site ...]`. Verified: feed, search, detail, and stream for ep 1 **and the last episode**
(the paywall is bypassed on every site). The stream bytes were checked: mp4 `ftyp` or TS sync `0x47`.
Per-site specs: `dramabox.md`, `goodshort.md`, `netshort.md`, `flickreels.md`. Fixtures: `fixtures/<site>_*`.

## Hosts and Cloudflare (the important part)

| Site | Front host (CF challenge) | CF-free host for HTML | CF-free video endpoint |
|---|---|---|---|
| dramabox | dramabox.dramafren.org | **none** (cdn host whitelists only `action=get_video`, `proxy_sub`) | `cdn-dramabox` / `cdn-dramaboxv2` `?action=get_video` |
| goodshort | goodshort.dramafren.org | **cdn-goodshort.dramafren.org** (whole app, no rule) | `cdn-goodshort ?action=get_video_url` then `/proxy?token=` |
| netshort | netshort.dramafren.org | **cdn-netshort / cdn-netshortv2**, only if you **append `&action=proxy_video`** | `cdn-netshort(v2) ?action=resolve_watch` |
| flickreels | flickreels.dramafren.org | **cdn-flickreels.dramafren.org** (whole app, no rule) | the m3u8 is baked into the watch page |

- Front hosts return `403` + `cf-mitigated: challenge` ("Just a moment...", Turnstile interactive) on every path.
- The `cdn-*` twins are still behind the Cloudflare proxy (`server: cloudflare`), but their WAF rule only matches some
  requests. netshort's rule lets a request through when `action` is one of the whitelisted names (`proxy_video`,
  `proxy_m3u8`, `proxy_stream`, `resolve_watch`, `proxy_sub`). PHP ignores unknown actions and falls through to `page=`,
  so `index.php?page=detail&id=X&action=proxy_video` renders the normal detail page with no challenge. **This is a
  quirk and it's fragile.** Keep the WebView path as a fallback.
- **The cf_clearance cookie is set on `.dramafren.org`**, so a single solve covers every subdomain. It is bound to the
  **User-Agent and IP** of the solver. Verified: cookie + the exact UA gives 200, a different UA gives 403, and no cookie gives 403.
  App recipe for CF pages (dramabox HTML, front-host feeds):
  1. Load `https://dramabox.dramafren.org/` in a hidden WebView. It solves the challenge by itself. Wait until the title is
     not "Just a moment...".
  2. Either (a) `evaluateJavascript("fetch('index.php?page=...').then(r=>r.text())")` on that origin (tested OK), or
     (b) read `cf_clearance` from `CookieManager` and use native HTTP with the **WebView's UA string**.
  3. On a 403 with `cf-mitigated: challenge`, redo step 1.
- **Feed gotcha:** "Recently Watched" is stored **per host**. The cdn twins show a short list (netshort cdn = 1 page,
  goodshort cdn = 3 pages), while the front hosts show 9-10 pages. flickreels cdn and front both show 9 pages. Use the front
  host (CF) for the feed when you have a clearance, and fall back to the cdn list otherwise.
- **Video/stream URLs never need Referer/Origin/cookies.** They play with plain HTTP in ExoPlayer or any HLS player.
  `cdn-dramabox` JSON also sends `Access-Control-Allow-Origin: *`.

## Page endpoints (same markup on all four)
Base = the host from the table above, path `/index.php`. Hrefs are entity-escaped (`&amp;`), so use an HTML parser.

### Feed: `?page=home&p_hist={n}` (flickreels adds `&lang=en`)
- The only list is `<h2>Recently Watched</h2>`. Header text is `Page {n} of {N}`, with 12 cards per page.
- Cards: `a[href*="page=detail"]` → `img[src]` = cover, `h3` = title. netshort's home cards also have
  `<span>Watch Now</span>`.
- has_more: an `a[href*="p_hist={n+1}"]` with text `Next »`, or `n < N`.
- The feed is global user history (it changes as anyone, including us, watches). It is not a curated catalogue.
  **Search is the real discovery API.**

### Search: `?page=search_result&q={q}&lang={lang}`
- `<h2>Search Results: "q"</h2>`, then a grid of cards. Selector: `a[href*="page=detail"]`, `img[src]`, `h3` (title).
  Badge `div.absolute.top-2.right-2` = `"87 EPS"` (goodshort) or `"🔥 1K"` popularity (netshort/flickreels).
  netshort/flickreels also have tag chips `span.text-\[10px\].bg-slate-700`.
- **No pagination.** It's a single page. `s_page`, `p` and `pg` are ignored. Result counts vary: dramabox ~10-21,
  goodshort ~15, netshort ~20, flickreels 100+.

### Detail: `?page=detail&id={id}&lang={lang}` (goodshort adds `&sv=1`; netshort has no lang; `slug` is optional)
- `h1` = title. `img.poster-shadow[src]` = cover (also `og:image`, JSON-LD `image`).
- `span` containing `Total: N Eps`. dramabox has an extra `span.bg-slate-700` with comma-separated tags.
  netshort/flickreels have `Server: Primary|Backup`.
- `p.text-slate-300.text-sm.leading-relaxed.mb-6` = synopsis.
- Episode grid under `<h3>Episode List</h3>`: `a[href*="page=watch"]` with label text `Ep 1` (goodshort: `001`).
  Read `ep` from the href query. **goodshort `ep` is 0-based; the others are 1-based.** The first watch link is the
  "Start Watching" button, so dedupe.

### Watch: `?page=watch&id={id}&ep={ep}&lang={lang}`
Player page only. The inline JS reveals the per-site video endpoint (see the site docs). flickreels bakes the m3u8 in here.
goodshort bakes the `chapterIds` array needed for playback.

## Playback summary

| Site | Call | Result | Format | Late eps | Expiry |
|---|---|---|---|---|---|
| dramabox | `cdn-dramabox/index.php?action=get_video&id&ep&lang&sv=1` | `{ok, videoUrl, qualities[540/720/1080p], isHls:false}` | direct **MP4** (hwztakavideoto.dramaboxdb.com) | yes (ep 80/80) | path-signed, resolve per play |
| goodshort | `cdn-goodshort/index.php?action=get_video_url&id&chap_id&sv&lang` | `{status:"success", video_url, qualities[720P/540P/1080P]}` | **HLS**. Playlist and segments go through `cdn-goodshort/proxy?token=v2...` (plain TS) | yes (51/51) | opaque tokens |
| netshort | `cdn-netshort/index.php?action=resolve_watch&id&ep&server=1` | `{ok, server, videoUrl, qualities, subtitles, source}` | direct **MP4** (ns-aws-cdn / video.netshort.com) | yes (30/30) | `auth_key` ≈ +7 days |
| flickreels | HTML `cdn-flickreels/index.php?page=watch&id&ep&lang` → `var initialVideoUrl` | m3u8 URL | **HLS**, plain MPEG-TS, relative segment names | yes (40/40, 60/60) | `verify=` ≈ +45-60 min |

No DRM or encryption on any of these paths. Subtitles arrays were empty in every sample (they're burned in).
When non-empty, play them via `<videoHost>/index.php?action=proxy_sub&url=<enc>` (returns WEBVTT).

## Language values
- dramabox: `en id in zhHans es de fr pt ko th vi zh ar ja it`
- goodshort: `en id es ko th de fr pt ar`
- netshort: `en in th ms pt es fr de it tr ar ja ko zh_CN zh_TW` (search form only; detail/watch take no lang)
- flickreels: `en id th ms pt es fr de it tr ar ja ko zh_CN zh_TW`

Cards carry their own `lang` in the href (the feed can mix `en`/`es`). Pass that lang to detail/stream.

## IDs
- dramabox: 11-digit bookId (`42000027929`, `41000103780`). It's the official DramaBox bookId; covers are
  `hwztchapter.dramaboxdb.com/.../{id}/{id}.jpg`.
- goodshort: 11-digit (`31001769950`). Playback needs the per-episode `chap_id` (8 digits).
- netshort: **19-digit** snowflake (`2101848053751341058`). Keep it as a string, because it overflows JS numbers.
- flickreels: small int (`12153`). Server 2 needs `chapter_id` (6 digits, in the watch page).

## Out of scope / notes
- `dramabox.goodbos.online` is a third-party "DramaBox API" (`/api/dramabox/{trending,search,browse,allepisode}`) that
  needs a paid `x-token`. It's referenced by the dramabox player JS. Not used here.
- dramabox `sv=2` (cdn-dramaboxv2 only) returns `http://drabox.dotkosong.web.id/api/v1/stream?u=<b64 of *.encrypt.mp4>`,
  a third-party decrypting proxy. Prefer sv=1. sv=3 = "Auto Fallback" to server 1.
