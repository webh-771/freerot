# stardusttv.dramafren.org — "Stardust Player"

Template: see `template_dramafren_php.md`. Client: `dramafren_client.py` (`Dramafren("stardusttv")`).
Fixtures: `fixtures/stardusttv_{home,search,detail,watch_ep1}.html`.

## CF status
| Endpoint | CF? |
|---|---|
| `stardusttv.dramafren.org/*` (all pages) | **CF interactive, 403 to curl.** No CF-free twin exists (cdn-stardusttv* has no DNS). Use the WebView. |
| `acdn-v.stardust-tv.com/prod/...m3u8` + `.ts` | CF-free, no headers |
| covers `assets.stardusttv.cc/uploadfile/...jpg` | CF-free |

## Endpoints (base `https://stardusttv.dramafren.org/index.php`)
- **Feed**: `?hp={n}` returns the "Recently Watched" global list, 24 cards per page, and `Page 1 of 9` + `<a href="index.php?hp=2">Next »</a>`.
- **Search**: `?page=search_result&q={q}&lang={lang}&p={n}` returns 9 cards per page, `Page 1 of 58` + `Next »` (href has `&p=2`).
  hasMore = page < total. The cards have no episode badge.
- **Detail**: `?page=detail&id={id}&slug={slug}&lang={lang}`. id is numeric (e.g. `22901`) and slug is a kebab
  title (`the-fighter-who-refused-to-kneel`). Keep the slug from the card href; I didn't test pages without it.
  - title `<h1>`, cover `<img>` before h1 or `og:image`, `<span>Total: 51 Eps</span>`
  - synopsis is always the placeholder "Full episodes available." (use the title only)
  - episodes: `index.php?page=watch&id=22901&slug=...&ep={n}&lang=en_US`, n = 1..N
- **Watch**: `?page=watch&id={id}&slug={slug}&ep={n}&sv={1|2}&lang={lang}` (the server picker offers sv=1 and sv=2).

## Playback
The inline script in the watch HTML contains:
```js
const totalEp = 51; const dramaId = "22901"; const currentServer = 1; const currentLang = "en_US";
const encryptedSrc = "aHR0cHM6Ly9hY2RuLXYuc3RhcmR1c3QtdHYuY29tL3Byb2QvMjI5MDEvMS9jZWJmNGJkZWNmZjg0YTVjOTI1Yzc1ZDVjMmU3ZGE5Ni5tM3U4";
const videoSrc = encryptedSrc ? decodeURIComponent(escape(atob(encryptedSrc))) : "";
```
Take the regex `const encryptedSrc = "([^"]*)"` and base64-decode it (UTF-8). That gives
`https://acdn-v.stardust-tv.com/prod/22901/1/cebf4bdecff84a5c925c75d5c2e7da96.m3u8`.
- Plain media playlist, 4 s MPEG-TS segments `…/segment-{i}.ts` (relative URLs), no key, 0x47 sync byte. Plain curl works.
- The "restriction" is client-side only. For ep > 1 the JS needs `localStorage["stardust_viewed_{id}_{ep-1}"]`
  (JSON `{val,expiry}`), and without it shows a 60 s wait overlay. The m3u8 is in the HTML anyway.
- sv=2 is untested.
- Late episodes are **unverified**. The permission layer denied my attempt to fetch ep 45.

## Lang
`en_US zh_CN ja_JP ko_KR es_ES zh_TW id_ID th_TH pt_BR fr_FR de_DE ar_AE vi_VN tr_TR ru_RU` (search form `<select name="lang">`).

## Verified run (2026-09-23)
feed 24 items has_more; search "love" 9 items has_more; detail "Illicit Love" 40 eps;
ep1 m3u8 at acdn-v.stardust-tv.com, first segment 138 KB MPEG-TS.
