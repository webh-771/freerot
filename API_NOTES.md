# ShortMax (dramafren) API notes — probed 2026-09-23

`shortmaxv3.dramafren.org` sits behind a Cloudflare interactive challenge, but it only
redirects (301) to the real origin **`https://shortmax.ngeshorts.fun`**, which has NO challenge.
Plain HTTP GET with a browser User-Agent works. All site pages are server-rendered HTML.

## Site (HTML) — base `https://shortmax.ngeshorts.fun/index.php`
Hrefs in the HTML are entity-escaped (`&amp;`) — use a real HTML parser.

| Page | URL | Notes |
|---|---|---|
| Detail | `?page=detail&id={id}&lang={lang}` | `<h1>` title, `Total: N Eps` text, `<p class="text-slate-300 ...">` synopsis, cover = `<img>` near h1 (or JSON-LD `image`), episode links `index.php?page=watch&id={id}&ep={n}&lang=en` |
| Search | `?page=search_result&q={q}&lang={lang}&s_page={n}` | cards `<a href="index.php?page=detail&id=..">` with `<img src alt=title>` and `Eps: N` badge; "Next Page »" link present if more |
| Recently watched (global) | `?page=home&p_hist={n}` | same card-ish markup ("Watch Now"), "Page 1 of 9" text, Next » link |
| Watch | `?page=watch&id=&ep=&lang=` | player JS only; video comes from video_server below |

Fixtures: `test/fixtures/{detail,search,home}.html`.

## Video server (JSON)
`GET https://cdn-shortmaxv3.dramafren.org/index.php?action=video_server&server={server1|server2}&id={id}&ep={ep}&lang={lang}&stale=1`
fallback endpoint `https://cdn-shortmaxv5.dramafren.org/index.php` (same params). Send `Accept: application/json`.

Response: `{"ok":true,"server":{"key","playUrl","proxyUrl","fallbackUrl","stale","qualities":[{"quality":"1080p","url","playUrl","proxyUrl",...}]}}`
- ALL episodes resolve (no paywall). server1 = akamai-static.shorttv.live (fresh), server2 = volcengine-forward (stale cache, may 403).
- m3u8 is plain HLS, segments are ordinary MPEG-TS (0x47) — any HLS player plays them. No headers needed.
- `proxyUrl` = same m3u8 via `cdn-shortmaxv2.dramafren.org/index.php?action=proxy_video&url=...` (rewrites segment URLs).
Fixtures: `test/fixtures/video_server{1,2}.json`.

## Official ShortMax API (catalogue / categories)
`POST https://shortweb.shorttv.live/app-api/app/{path}`
Headers: `Content-Type: application/json`, `X-Encrypted: true`, `Language-Code: {lang}`, browser `User-Agent`.
Body = base64(AES-128-CBC-PKCS7(json)), key = iv = UTF-8 `shortwebapiaesen`. Response body = base64 of same-encrypted `{"code":0,"data":...,"msg"}`; code != 0 → error.

| path | payload | data |
|---|---|---|
| `cmsShortPlay/queryPage` | `{pageNo,pageSize}` (+ `classId` to filter) | `{list:[...], total}` |
| `cmsClassNew/queryList` | `{}` | `[{classId, displayName, ...}]` |

Drama item fields: `shortPlayCode` (**== site id**, string like "867551"), `shortPlayName`, `lanShortPlayName`, `coverId` (cover URL, loads without auth), `summary`, `playNum`.
The official `shortPlayId` is NOT the site id — always use `shortPlayCode`.
