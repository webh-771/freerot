# FlexTV mirror: flextv.dramafren.org

Probed 2026-09-23 (partial). This is a **different template** ("FlexPlayer - FlexTV Unlocked") from the other dramafren mirrors.

**Status: the home feed works with plain HTTP. Search, detail and watch were NOT probed**, because network probing was stopped by
the tool permission layer before I reached flextv.

## Cloudflare
`GET https://flextv.dramafren.org/` → **200 with plain curl** (`server: cloudflare`, sets `PHPSESSID`). There is **no challenge**,
so it can be fetched directly. The page still embeds the passive CF `jsd` beacon. The other endpoints are presumably also
CF-free, but that's not verified.

## Language
The site stores it per session: `GET index.php?action=set_lang&lang={xx}` (sets it in the `PHPSESSID` session, so keep the
cookie jar). Values: `ar de en es fr id it ja ko pt th tr vi zh`.

## Feed (verified from `fixtures/flextv_home.html`)
`GET index.php?page=home&tab={tab}&p={n}` (with no `p`, it's page 1).
Tabs: `1` Popular, `2` New, `6` Original+, `7` For Her, `8` For Him, `11` Anime. Mobile nav "Clips" = tab 2.
The home page listed **85 unique dramas**. Next page link: `<a href="index.php?page=home&tab=1&p=2">Next →</a>`.
Card:
```html
<a href="index.php?page=detail&id=15265" class="group relative …">
  <div class="aspect-poster relative"><img src="https://file-cdn.flextv.cc/image/b2/e29a….jpg?image_process=resize,w_420/quality,Q_70"
       alt="Revenge of the Forsaken Elf Queen" …><div …><span …>▶ 159.9K</span></div></div>
  <div class="p-2 md:p-3"><h2 …>Revenge of the Forsaken Elf Queen</h2><p …>Drama</p></div></a>
```
The title is in `<h2>` (not `h3`); `<p>` holds the genre and `▶ N` the views. The id is numeric. Hrefs are NOT `&amp;`-escaped.
Parser: `dramafren_more_client.parse_flextv_feed`.

## Search / Detail / Playback: TODO
- Search: nav link `index.php?page=search`, which has a form with `name="q"` (other field names are unknown).
- Detail: `index.php?page=detail&id={id}`.
- Watch: unknown. Next step is `cf.py net` on a watch URL, then look for `action=` endpoints and base64 `src` in the inline JS.
