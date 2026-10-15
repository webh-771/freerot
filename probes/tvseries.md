# tvseries.dramafren.org ("DramaSeries") — probed 2026-09-23

**Status: BROKEN for playback right now.** Listing, search and detail work (from the site's cache), but every video URL returns 403.
**Content type: full-length movies and TV series** from **MovieBox** (aoneroom / hakunaymatata), for example 60+ min episodes and multi-season shows. Not short dramas.

## CF status
**The whole origin is CF-free.** Plain HTTP (any UA) works for the page and for every `?api_route=` call. No cookies are needed.

| Host | CF | Notes |
|---|---|---|
| `tvseries.dramafren.org/?api_route=*` | CF-free | direct HTTP |
| `pbcdnw.aoneroom.com` (covers) | CF-free | |
| `api.filmdramaid.xyz/aliplay/video/<b64url>` (video proxy) | LiteSpeed, **403 `427 Forbidden` on everything**, including from inside a real browser on the site origin | broken |
| `cacdn.hakunaymatata.com/subtitle/*.srt?Policy&Signature` | CloudFront-signed | the site proxies them via `?api_route=subtitle&url=` |

## Languages
`lang` = `en, id, ar, fr, hi, ur, fil`. This only changes labels, so lists are largely the same.

## Routes
All are `https://tvseries.dramafren.org/?api_route=<r>&lang=<l>`, and POST bodies are JSON (`Content-Type: application/json`).

| Route | Method | Body/params | Response |
|---|---|---|---|
| `tablist` | GET | – | `{"success":true,"platform":"tv","language":"en","data":[{"type":"GENRE"\|"COUNTRY"\|"SORT BY"\|"YEARS","name","tab_key","position_index":2}, …77]}` |
| `tabdata` | POST | `{"key":"Latest","type":"SORT BY","position":2}` | `{"success":true,"data":{"isMore":true,"page_info":{"type","key","positionIndex","has_more","nextPage":"2","page":"1","perPage":18,"totalCount":34687},"book":{"list":[{id,name,cover,badge:"DracinKu",introduction:"",tags:[…],chapterCount:0,playCount}]}}}` |
| `tabfeed` | POST | `{"page_info":{…page_info from tabdata…}}` | **always `{"error":"Failed to fetch data and no cache available"}`**, so page 2+ is broken (it's broken on the live site too) |
| `search` | POST | `{"keyword":"love"}` | `data.book` = 22–30 items, with `page_info.totalCount` (759–885). Any page param errors. |
| `detail` | GET | `&id=<id>` | `{"data":{"book":{id,name,cover,introduction,tags,chapterCount},"chapters":[{"eps":"EP-1","index":0,"videoPath":"https://api.filmdramaid.xyz/aliplay/video/<b64url>","subtitle":[{"subtitle":"<srt url>","display_name","language":"en"}],"dash":[],"isLock":false}]}}` |
| `popular` | GET | `&period=today\|week\|month` | `[{id,name,cover,views_today,display_views,…}]` (site-local view counter) |
| `subtitle` | GET | `&url=<srt url>` | SRT passthrough |
| `track` | POST | `{id,name,cover}` | view-count beacon, not needed |

- **id** = base64 of JSON `{"sid":"<MovieBox subjectId>","pid":"<MovieBox detailPath>"}`, e.g. `eyJzaWQiOiIyODkyMjM2Njk5NjMzOTU5NDMyIiwicGlkIjoicGxhc3RpYy1iZWF1dHktb0dGb0cwcnRFcjMifQ==` → `{"sid":"2892236699633959432","pid":"plastic-beauty-oGFoG0rtEr3"}`.
- Any uncached request (a new COUNTRY tab, some ids such as "Love … S1-S3", the paging calls) returns `{"error":"Failed to fetch data and no cache available"}`. The PHP backend's upstream is currently failing and it serves stale cache only.
- For multi-season shows, `chapters` flattens the episodes (`eps` label, 0-based `index`).

## Playback (current failure)
`videoPath` = `https://api.filmdramaid.xyz/aliplay/video/` + base64url(`https://bcdnxw.hakunaymatata.com/cms/<hash>.mp4?sign=<md5>&t=<unix>`).
- All `t` values seen are from 2026-09-16/17 or earlier, so the cached URLs are stale. The proxy returns `403 "427 Forbidden"` (tested ep 1 and the last ep of several titles, from curl and from Chrome on the site origin, where `<video>` stays at readyState 0).
- The decoded hakunaymatata URL gets `429` or `403` directly (it's expired, and that CDN also gates on the requesting page).

## Upstream observation (MovieBox H5 API, not the dramafren site)
- `GET https://h5.aoneroom.com/wefeed-h5-bff/web/subject/detail?subjectId=<sid>` is **CF-free** (istio-envoy). It returns `data.subject{title,description,cover.url,genre,countryName,imdbRatingValue,detailPath,subjectType}` and `data.resource.seasons[{se,maxEp,resolutions[]}]`.
- `GET …/wefeed-h5-bff/web/subject/play?subjectId=<sid>&se=<n>&ep=<n>&detail_path=<pid>` returned fresh `streams[{format:"MP4",resolutions:"360|480|1080",url:"https://bcdnxw.hakunaymatata.com/…mp4?sign=…&t=<now>",codecName:"h264",duration}]` (see `fixtures/tvseries_upstream_moviebox_play.json`). With no page Referer it returned `streams:[]`.
- Those MP4s loaded (206) when fetched from the MovieBox web page context in Chrome, but returned **429** to plain curl, including with Chrome TLS impersonation. I stopped there. Treat this as a separate, unverified integration: it isn't part of the dramafren site, and it depends on MovieBox's own web-origin gating.

## Recommendation
Skip tvseries for now, or ship it behind a health check that tests `HEAD`/Range on one `videoPath` and hides the source while it returns 403.

## Files
`fixtures/tvseries_{tablist,tabdata,search,detail}.json`, `tvseries_upstream_moviebox_play.json`, `tvseries_client.py` (the demo prints the 403).
