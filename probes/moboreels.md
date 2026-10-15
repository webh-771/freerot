# moboreels.dramafren.org — probed 2026-09-23

**Status: WORKS.** Every episode (locked ones too) resolves to a direct H.264 MP4 (1080x1920). Separate SRT subtitles.
The upstream is the MoboReels app (assets on `*.cdreader.com`).

## Architecture
A PHP page with an inline-JS SPA calling `GET https://moboreels.dramafren.org/?api_route=<route>&lang=<lang>&...` (plain JSON, no signing).

| Host | CF | Notes |
|---|---|---|
| `moboreels.dramafren.org/?api_route=*` | **CF managed challenge** | WebView, or reuse `cf_clearance` + same UA (verified) |
| `video-cdn3.cdreader.com` (covers) | CF-free | the URLs sometimes contain `//backend/`; keep them as-is |
| `cdnvideo.cdreader.com/...f0.mp4?t=&us=&sign=` (video) | **CF-free** (Tencent EdgeOne) | plain GET, no headers, Range OK, CORS `*`. `t` = hex unix expiry, about **+1 h** |

## Languages
- The UI offers `en,id,zh,RTW(zh-TW),es,pt,fr,ru,it,ja,ar,th,vi,ko,fil,de,hi,ms,tr`.
- **Home feed (`channels`/`list`) only works for `en, id, pt, th, tr`.** Other codes return `{"error":"Invalid langId \"4\". Allowed: 3, 5, 11, 12, 22"}`.
- `search`/`detail`/`episodes`/`video` work for other langs, e.g. es = 751 hits for "a" and zh works.

## 1. Feed
`?api_route=channels&lang=en` →
`{"code":200,"data":{"channels":[{"channelId":"162602653701375558","channelType":2,"title":"Home","isDefault":1},{"channelId":"113757996389499537","title":"New"},{"channelId":3,"channelType":3,"title":"Charts"},{"channelId":"161071697598751542","title":"Dubbed"},…Comics, Anime, Original, AsianDrama, Novel]}}`
- Channel ids differ per language. The site JS hard-codes `162979468352028714`, which is now invalid (→ error), so always read `channels` first.
- `channelType 3` ("Charts") → `{"code":400,"data":{"sections":[]}}` and isn't supported.

`?api_route=list&lang=en&channelId=<id>` →
```json
{"code":200,"data":{"skipSeries":20,"channelId":"1626…","sections":[
  {"title":null,"series":[{"seriesId":59256322,"seriesName":"Mated To My Boyfriend's Brother",
    "coverUrl":"https://video-cdn3.cdreader.com//backend/2320641784200213408.webp","description":"…",
    "totalEpisodes":62,"freeEpisodes":7,"status":"completed","genres":[]}]},
  {"title":"Best Sellers","series":[…10]},{"title":"💫Rising Stars",…},{"title":"Coming Soon",…23},{"title":"New Releases",…},{"title":"You Might Like",…20}]}}
```
- **No paging**: `pageNo`/`page`/`skipSeries`/`offset` are all ignored. Each channel gives about 20–80 titles in fixed sections. For "more", use the other channels plus search.

## 2. Search (paginated): `?api_route=search&lang=en&q=<q>&pageNo=N`
`{"code":200,"data":{"pageNo":1,"pageSize":20,"total":348,"items":[{seriesId,seriesName,coverUrl,description,totalEpisodes,…}]}}`
- has_more = `pageNo*pageSize < total`. An empty `q` gives `{"error":"searchKey is required"}`.

## 3. Detail
- `?api_route=detail&lang=en&id=<seriesId>` → `{"code":200,"data":{seriesId,seriesName,coverUrl,description,totalEpisodes,freeEpisodes,status,genres:[…]}}`
- `?api_route=episodes&lang=en&id=<seriesId>` → `{"code":200,"data":{"total":65,"items":[{"episId":"220647721499068651","episNum":1,"isFree":true,"isLock":false,"price":0,"episIndex":0,…}]}}`
- seriesId is an int (e.g. `83764322`), episId is a string, and episNum is 1-based.

## 4. Playback: `?api_route=video&lang=en&id=<seriesId>&episNum=<n>`
```json
{"data":{"mediaUrl":"https://cdnvideo.cdreader.com/4c1b3983vodhk1310397514/a54aedfd5001834821238441972/f0.mp4?t=6ab3f3f2&us=389a72aff6024f62be3115f236c2e074&sign=6f1eb1cd9c80485b6f97e2b1f87d31a0"}}
```
- If the response also has `episMedia[{codec,resolution,mediaUrl}]`, the site picks the highest-resolution `h264` entry. Otherwise it uses `mediaUrl`.
- Format: progressive MP4, H.264 1080x1920 plus AAC, no DRM.
- **Tested ep 1 (free) and ep 62 or 65 (`isLock:true`, last): both give `206 video/mp4` with plain curl.** The paywall isn't enforced.
- The URL expires about 1 h after issue, so fetch it just in time per episode.

## 5. Subtitles: `?api_route=subtitle&lang=en&episId=<episId>` (text)
The body is SRT, preceded by style lines such as `[font-size=18]`, `[region=72,900,648,285]` and `[font-stroke=#000000,1.5]`. Strip the leading `[...]` lines (and the BOM) before handing it to an SRT parser. The video is clean, with no burned-in subs.

## Files
`fixtures/moboreels_{channels,list,search,detail,episodes,video_ep1,video_ep65_locked}.json`, `moboreels_subtitle.srt`, `moboreels_client.py`.
