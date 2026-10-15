# flickreels.dramafren.org ("FlickReels Unlocked")

Template: `template_dramafren_unlocked.md`. Client: `dramafren_player_client.py` (`DramafrenClient("flickreels")`).
Fixtures: `fixtures/flickreels_{home,search,detail,watch_ep40}.html` (search trimmed to 12 cards), `flickreels_ep40.m3u8`.

**Status: works fully CF-free** through `cdn-flickreels.dramafren.org`, which serves the entire app with no challenge.

## CF status per endpoint
| Endpoint | CF? |
|---|---|
| `flickreels.dramafren.org/*` | CF challenge |
| `cdn-flickreels.dramafren.org/index.php?page=*` | **CF-free** |
| `zshipricf.farsunpteltd.{com,net}/playlet-hls/*.m3u8?verify=…` + `.ts` | CF-free, no headers |
| `cdn-flickreels…?action=proxy_m3u8&url=` | CF-free, but returned `CDN Error: 403` in tests (upstream blocks the proxy) |
| `cdn-flickreels…?action=server2_stream&id&ep&lang&chapter_id` | CF-free JSON, returned `{"status_code":0,"message":"Server 2 stream unavailable"}` |

## Feed / search / detail (base `https://cdn-flickreels.dramafren.org/index.php`)
- Feed: `?page=home&p_hist={n}&lang=en`. 12/page, 9 pages (same count as the front host).
- Search: `?page=search_result&q=love&lang=en`. Single page but large (133 results for "love"). Badge `🔥 60`, tag chips.
- Detail: `?page=detail&id=12153&lang=en`. `Total: 40 Eps`, `Server: Primary`. Episode links `ep=1..N`.

## Playback: the m3u8 is in the watch HTML
```
GET https://cdn-flickreels.dramafren.org/index.php?page=watch&id=12153&ep=40&lang=en      (~1 s)
  <video id="player" src="https://zshipricf.farsunpteltd.com/playlet-hls/hls_1789897109_1_23268.m3u8?verify=1790176036-gX3x…%3D">
  var initialVideoUrl = "https:\/\/zshipricf.farsunpteltd.net\/playlet-hls\/hls_1789897109_40_33292.m3u8?verify=1790177982-EAEF…%3D";
  availableServers.push({id:1, url:…, corsFallbackUrl:"https://cdn-flickreels.dramafren.org/index.php?action=proxy_m3u8&url=…"})
  availableServers.push({id:2, lazy:true, endpoint:"index.php?action=server2_stream&id=12153&ep=40&lang=en&chapter_id=752211"})
  availableServers.push({id:3, lazy:true, endpoint:"index.php?action=server3_stream&id=12153&ep=40&lang=en"})
```
Parse `var initialVideoUrl = "…"` (a JSON string, so unescape `\/`), or `video#player[src]`.
```
#EXTM3U / #EXT-X-VERSION:3 / #EXT-X-TARGETDURATION:14
#EXTINF:13.520000,
hls_1789897109_40_33292-00001.ts        <- relative to the m3u8 URL, no ?verify needed
...
#EXT-X-ENDLIST
```
- Plain HLS, MPEG-TS segments (`0x47`), **no encryption**, no headers. Late eps resolve (40/40, 60/60).
- `verify=` expires ≈ 45-60 min after issue. Fetch the watch page right before playing.
- Host alternates between `farsunpteltd.com` and `.net`. Both work.
- `&server=2|3` re-renders the page with that server. server2_stream/server3_stream were unavailable in tests. Stick to server 1.
