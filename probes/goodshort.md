# goodshort.dramafren.org ("GoodShort Unlocked")

Template: `template_dramafren_unlocked.md`. Client: `dramafren_player_client.py` (`DramafrenClient("goodshort")`).
Fixtures: `fixtures/goodshort_{home_front,home_cdn,search,detail,watch_epm1}.html`, `goodshort_get_video_url.json`, `goodshort_proxy_ep51.m3u8`.

**Status: works fully CF-free** through `cdn-goodshort.dramafren.org`, which serves the entire app with no challenge.

## CF status per endpoint
| Endpoint | CF? |
|---|---|
| `goodshort.dramafren.org/*` | CF challenge |
| `cdn-goodshort.dramafren.org/index.php?page=home|search_result|detail|watch` | **CF-free** |
| `cdn-goodshort…/index.php?action=get_video_url…` | CF-free JSON |
| `cdn-goodshort…/proxy?token=v2.…` (playlist and each segment) | CF-free |

## Feed / search / detail (base `https://cdn-goodshort.dramafren.org/index.php`)
- Feed: `?page=home&p_hist={n}`. 12/page. The cdn host keeps its own history (**3 pages**); the front host has 10.
  For the full feed use `https://goodshort.dramafren.org/index.php?page=home&p_hist=n` with cf_clearance.
- Search: `?page=search_result&q=love&lang=en`. Single page (~15). Badge `87 EPS`.
- Detail: `?page=detail&id=31001769950&lang=en&sv=1` (slug optional). `Total: 51 Eps`. Episode links
  `page=watch&id=…&ep=0..50&…&sv=1` with labels `001…051`. **ep is 0-based.**

## Playback (2 steps)
1. **chapterIds.** The watch page JS has `var chapterIds = ['66155558', …]` (index = ep). Fetch it fast with **`ep=-1`**:
   `GET cdn-goodshort/index.php?page=watch&id=31001769950&ep=-1&lang=en&sv=1` takes ~1-2 s. A valid ep makes the server
   resolve the video inline, which can take ~30 s. Cache the list per (id, lang).
2. **Resolve**, the same call the page's `switchEpisode()` makes:
```
GET https://cdn-goodshort.dramafren.org/index.php?action=get_video_url&id=31001769950&chap_id=66155608&sv=1&lang=en
{"status":"success","video_url":"https://cdn-goodshort.dramafren.org/proxy?token=v2.a2aFZ…",
 "qualities":[{"quality":"720P","url":"…/proxy?token=v2…"},{"quality":"540P",…},{"quality":"1080P",…}]}
```
   Failure = `status != "success"` (the page shows "Locked or Error. Try switching to another server"). `sv=2` also works.
3. `video_url` is an HLS VOD playlist (`application/vnd.apple.mpegurl`) whose segment lines are absolute
   `https://cdn-goodshort.dramafren.org/proxy?token=v2.…` URLs. The segments are plain MPEG-TS (`0x47` sync, 5 s each).
   No keys and no headers. Verified on ep index 0 and 50 (last).

## Gotchas
- The backend is **slow and flaky** when cold. `get_video_url` for a title nobody had opened hung for over 3×45 s once. A few
  minutes later the same call returned in 0.6-6 s. The first proxied segment sometimes took >60 s. Retries fixed both.
  In the app: 15-20 s per-request timeout, retry 2-3×, and try `sv=2`.
  Set generous HLS timeouts and retries (the site's own hls.js config uses 20-30 s timeouts with 8 retries).
- The watch page HTML may be a server cache of another ep (`phpBakedEp`). Ignore it and always use get_video_url.
- The baked `initialUrl` uses an older `index.php?token=` form. Don't use it.
