# netshort.dramafren.org ("NetShort Unlocked")

Template: `template_dramafren_unlocked.md`. Client: `dramafren_player_client.py` (`DramafrenClient("netshort")`).
Fixtures: `fixtures/netshort_{home_front,search_cdn,detail,watch}.html`, `netshort_resolve_watch_{s1,s2}.json`.

**Status: works CF-free.** Playback is a clean JSON endpoint. HTML is reachable via the cdn twin with a dummy whitelisted `action`.

## CF status per endpoint
| Endpoint | CF? |
|---|---|
| `netshort.dramafren.org/*` | CF challenge |
| `cdn-netshort(v2).dramafren.org/index.php?page=…` (no action) | 404 (CF rule) |
| `cdn-netshort(v2)…/index.php?page=…&action=proxy_video` | **CF-free, full HTML** (also `proxy_m3u8`, `proxy_stream`) |
| `cdn-netshort(v2)…/index.php?action=resolve_watch…` | CF-free JSON |
| `ns-aws-cdn.netshort.com` / `video.netshort.com` mp4 | CF-free, no headers, Range OK |

## Feed / search / detail (base `https://cdn-netshort.dramafren.org/index.php`, always append `&action=proxy_video`)
- Search: `?page=search_result&q=love&lang=en&action=proxy_video`. Single page (~20). Badge `🔥 1K`, tag chips.
- Detail: `?page=detail&id=2101848053751341058&action=proxy_video` (**no lang/slug**). `Total: 30 Eps`, `Server: Backup|Primary`.
  Episode links `page=watch&id=…&ep=1..N`.
- Feed: the cdn host's own history is nearly empty (**1 page**). Use the front host
  `https://netshort.dramafren.org/index.php?page=home&p_hist={n}` with cf_clearance (9 pages × 12), or rely on search.
- Why the action trick works: the cdn host's CF rule only passes whitelisted `action=` values. PHP doesn't handle
  `proxy_video` when `page=` is also present, so it renders the page. It's fragile. If it starts returning 404, fall back to the WebView.

## Playback
The watch JS (`watchActionEndpoints = ["https://cdn-netshort.dramafren.org/index.php","https://cdn-netshortv2.dramafren.org/index.php"]`,
random start index, 12 s timeout each) calls:
```
GET https://cdn-netshort.dramafren.org/index.php?action=resolve_watch&id=2101848053751341058&ep=30&server=1[&_=<ms>]
{"ok":true,"server":1,"videoUrl":"https://ns-aws-cdn.netshort.com/o4RNpQ…?a=0&auth_key=1790837860-…&mime_type=video_mp4&…",
 "qualities":[{"quality":"Default","url":…}],"subtitles":[],"source":…}
error: {"ok":false,"status":404,"server":2,"message":"Video URL is unavailable for this episode."}
```
- **MP4** (H.264, `ftyp isom`), no DRM. Late ep 30/30 resolves. `auth_key` expiry is ≈ +7 days.
- `server`: 1 → ns-aws-cdn.netshort.com, 2 → video.netshort.com. The two hosts are not consistent: `cdn-netshort` returned 404
  for server=2, while `cdn-netshortv2` served it. Try (server 1, both hosts), then (server 2, both hosts).
- Subtitles: `subtitles[].url` + `subtitleLanguage|lang|language` → `…/index.php?action=proxy_sub&url=<enc>`. Empty in samples.
