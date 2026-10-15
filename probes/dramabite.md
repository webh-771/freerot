# DramaBite mirror: dramabite.dramafren.org

Probed 2026-09-23. Uses the shortmax/dramafren PHP template (`template_dramafren_php.md`). The watch page is like
reelshort's: `const videoSrc = atob("…")` is inlined. The backend is MiniEpisode (`*.miniepisode.media`).
Client: `dramafren_more_client.py` (`Client("dramabite")`). Fixtures: `fixtures/dramabite_*`.

**Status: HTML works through a WebView. The ep 1 m3u8 was verified with plain curl.** Segment bytes and late episodes are
**not verified**, because the tool permission layer denied those requests mid-probe.

## Hosts / Cloudflare
| Endpoint | CF? |
|---|---|
| `https://dramabite.dramafren.org/index.php?…` (all pages) | **challenge** (403). `cdn-dramabite.dramafren.org` → CF **523** (origin unreachable), so there is no CF-free twin. |
| `https://cdn-video.miniepisode.media/video/{id}/{ep}/{hash}.m3u8?wsSecret=&wsTime=` | none (plain curl 200) |
| segments `{hash}_000000N.ts?wsHlsSession=…` (relative to the m3u8) | not verified |
| covers `https://cdn-oss.miniepisode.media/episode/{hash}` | none |

## Language
`lang` = `en id ar tr es de fr it pt ja zh th ms` (from `<select name="lang">`, default `en`).

## Feed
`GET index.php?page=home&p_hist={n}`. 12 cards per page. "Page 1 of 9". A `Next »` link means hasMore.
Card: `<a href="index.php?page=detail&amp;id=16221">` + `<img src alt>` + `<h3>`. Global "Recently Watched".

## Search
`GET index.php?page=search_result&q={q}&lang={lang}` (hidden `page=search_result` in the home form). **The results page was not
fetched.** Expect the starshort/shortmax card markup after `Search: "q"`.

## Detail
`GET index.php?page=detail&id={id}[&lang=en]`. The id is numeric (`16221`). See `fixtures/dramabite_detail.html`.
`<h1>` title, cover `<img alt="{title} Poster">`, `<span>Total: 65 Eps</span>`, synopsis in the first `<p>` after the h1,
episodes `index.php?page=watch&id=16221&ep={n}&lang=en` (hrefs here are NOT `&amp;`-escaped).

## Playback
`GET index.php?page=watch&id={id}&ep={n}&lang=en[&server=1|2]` (CF, WebView). Inline JS:
```js
const totalEp = 65; const dramaId = "16221"; const dramaLang = "en"; const selectedServer = 1;
const videoSrc = atob("aHR0cHM6Ly9jZG4tdmlkZW8ubWluaWVwaXNvZGUubWVkaWEv…");
const availableQualities = [];
const availableServers = [{"label":"Server 1","source":"Main","server":1,"active":true,"href":"index.php?page=watch&id=16221&ep=1&lang=en&server=1"},
                          {"label":"Server 2","source":"Backup","server":2,"active":false,"href":"…&server=2"}];
```
Regex: `const videoSrc = atob\("([^"]*)"\)` → base64-decode →
`https://cdn-video.miniepisode.media/video/16221/1/7c77fdf337e80cf607625201d84bdafd.m3u8?wsSecret=34688f…&wsTime=1790174701`
- This is Wangsu signing. `wsTime` was the **time of the page request**, so the mirror signs fresh on every load (no stale cache
  like starshort). The TTL is unknown. Resolve right before playing.
- m3u8 (plain curl, no headers → 200): media playlist, `#EXT-X-TARGETDURATION:3`, 40 segments, **no `EXT-X-KEY`**,
  segment lines `21710b…_0000000.ts?wsHlsSession=42901f…` (relative). MPEG-TS is expected, but segment bytes weren't fetched.
- Server 2 ("Backup") is linked but untested.
- The localStorage gate `kalos_viewed_{id}_{ep-1}` with a 60 s overlay is client-side only.
- Late episodes (ep 40/65) and the lock behaviour were **not tested** (requests denied).

Fixtures: `dramabite_home.html`, `dramabite_detail.html`, `dramabite_watch.html`, `dramabite_ep1.m3u8`.
