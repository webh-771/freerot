# dramafren.org (root WordPress site) — quick look 2026-09-23

It isn't only a link hub. It is a WordPress blog (theme with `/series/<slug>/` and per-episode posts, **only about 68 posts** in `/wp-json/wp/v2/posts`, `X-WP-Total: 68`) that links to all the `*.dramafren.org` sub-sites **and** hosts a small set of its own videos.

- `https://dramafren.org/wp-json/wp/v2/posts?per_page=…` answered 200 to plain curl (CF-free for the REST API). `content.rendered` is empty, because the player lives in theme meta rather than the post body.
- A post page (for example `/caught-on-cat-cam-marriage-of-lies/`, with `/mirror/2` alternates) embeds
  `<iframe src="https://dramafrenvip.upns.pro/#<videoId>">`, a third-party "UPNS" hosted player (vidstack + hls.js, ad-heavy with popunders).
- `GET https://dramafrenvip.upns.pro/api/v1/info?id=<videoId>` (CF-free) returns a hex string = **AES-128-CBC, key `kiemtienmua911ca`, iv `1234567890oiuytr`** (the known key for this player family). It decrypts to `{"playerId","ads",…}` and holds no stream URL.
- The stream URL needs a further `/api/v1/video?id=…` call. Guessed params returned 404 `"Video not found or deleted"`, and the click-to-play capture was hijacked by ad popups. **Not finished.**

**Verdict:** low value (about 68 items, a third-party encrypted and ad-laden player) compared with the sub-sites. Skip it, or, if it's ever wanted, render the iframe URL in a WebView as-is.
