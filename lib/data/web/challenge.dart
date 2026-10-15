// OWNER: web-session agent. Pure helpers (no platform code) shared by the
// background WebView workers and the verification popup. Unit-tested in
// test/web_challenge_test.dart.
//
// These only *detect* a Cloudflare challenge so it can be shown to the user.
// Nothing here interacts with or solves it.
import 'dart:convert';

/// True if [title] is the title of a Cloudflare interstitial.
bool isChallengeTitle(String? title) {
  final t = (title ?? '').trim().toLowerCase();
  return t.startsWith('just a moment');
}

/// True if a fetch() response is a Cloudflare challenge rather than content.
///
/// [mitigated] is the `cf-mitigated` response header (Cloudflare sets it to
/// `challenge` on challenge responses).
bool isChallengeResponse(int status, String body, {String? mitigated}) {
  if ((mitigated ?? '').toLowerCase().contains('challenge')) return true;
  if (status != 403 && status != 503 && status != 429) return false;
  final head = body.length > 20000 ? body.substring(0, 20000) : body;
  return head.contains('Just a moment') ||
      head.contains('cf-chl') ||
      head.contains('_cf_chl_opt') ||
      head.contains('challenge-platform');
}

/// Snapshot of a WebView document, as reported by [kPageStateJs].
class PageState {
  final String title;
  final String host;
  final String readyState;

  /// The document carries Cloudflare challenge markers (`_cf_chl_opt`,
  /// `#challenge-form`).
  final bool challengeMarkers;

  const PageState({
    required this.title,
    required this.host,
    required this.readyState,
    required this.challengeMarkers,
  });

  static const empty =
      PageState(title: '', host: '', readyState: '', challengeMarkers: false);

  /// Currently showing a Cloudflare challenge.
  bool get isChallenge => challengeMarkers || isChallengeTitle(title);

  /// A normal page of [originHost] has loaded (not the challenge, not blank).
  bool isClearOn(String originHost) =>
      !isChallenge &&
      host.toLowerCase() == originHost.toLowerCase() &&
      readyState != 'loading' &&
      readyState.isNotEmpty;

  /// Parses the value returned by `runJavaScriptReturningResult(kPageStateJs)`.
  /// Android hands back the JSON string quoted once more; iOS does not.
  factory PageState.fromJsResult(Object? raw) {
    try {
      Object? v = raw;
      for (var i = 0; i < 2 && v is String; i++) {
        v = jsonDecode(v);
      }
      if (v is! Map) return empty;
      return PageState(
        title: '${v['t'] ?? ''}',
        host: '${v['h'] ?? ''}',
        readyState: '${v['r'] ?? ''}',
        challengeMarkers: v['c'] == true,
      );
    } catch (_) {
      return empty;
    }
  }
}

/// Reads the current document state. Read-only: touches nothing on the page.
const String kPageStateJs = r'''(function(){try{return JSON.stringify({
t:document.title||'',
h:location.host||'',
r:document.readyState||'',
c:!!(window._cf_chl_opt||document.getElementById('challenge-form'))
});}catch(e){return '{}';}})()''';

/// Fallback UA if the WebView's own cannot be read.
const String kFallbackChromeUa =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

/// Turns the WebView's default UA into the UA that the same Chromium build
/// sends as the Chrome app (reduced UA, no `; wv`, no `Version/4.0`).
/// Keeping the real major version avoids a UA / engine mismatch.
String chromeUaFrom(String? webViewUa) {
  final m = RegExp(r'Chrome/(\d+)').firstMatch(webViewUa ?? '');
  if (m == null) return kFallbackChromeUa;
  return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/${m.group(1)}.0.0.0 Mobile Safari/537.36';
}

/// `https://host[:port]` of [url], or '' if it isn't an absolute http(s) URL.
String originOf(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !u.hasScheme || u.host.isEmpty) return '';
  if (u.scheme != 'https' && u.scheme != 'http') return '';
  return u.hasPort &&
          !((u.scheme == 'https' && u.port == 443) ||
              (u.scheme == 'http' && u.port == 80))
      ? '${u.scheme}://${u.host}:${u.port}'
      : '${u.scheme}://${u.host}';
}

/// Last two labels of a host (`a.dramafren.org` -> `dramafren.org`). Used to
/// re-check sibling origins after one verification: Cloudflare scopes
/// `cf_clearance` to the zone, so one check can clear several mirrors.
String siteOf(String host) {
  final parts = host.split('.');
  return parts.length <= 2 ? host : parts.sublist(parts.length - 2).join('.');
}
