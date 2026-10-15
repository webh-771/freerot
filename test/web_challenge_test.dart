// Pure challenge-detection helpers + WebSession fail-fast behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:shortmax_player/data/sources/stardust_source.dart';
import 'package:shortmax_player/data/web/challenge.dart';
import 'package:shortmax_player/data/web/web_session.dart';

void main() {
  test('challenge title', () {
    expect(isChallengeTitle('Just a moment...'), isTrue);
    expect(isChallengeTitle('  just a moment…'), isTrue);
    expect(isChallengeTitle('Stardust Player'), isFalse);
    expect(isChallengeTitle(null), isFalse);
    expect(isChallengeTitle(''), isFalse);
  });

  test('challenge response', () {
    const cfBody = '<!DOCTYPE html><html><head><title>Just a moment...'
        '</title></head><body><script>window._cf_chl_opt={cType:'
        "'interactive'}</script></body></html>";
    expect(isChallengeResponse(403, cfBody), isTrue);
    expect(isChallengeResponse(503, '<div id="cf-chl-widget">'), isTrue);
    expect(isChallengeResponse(200, '<html>ok</html>', mitigated: 'challenge'),
        isTrue);
    // A normal page that merely mentions the words is not a challenge.
    expect(isChallengeResponse(200, cfBody), isFalse);
    expect(isChallengeResponse(403, 'Forbidden'), isFalse);
    expect(isChallengeResponse(404, 'Not found'), isFalse);
  });

  test('page state from runJavaScriptReturningResult', () {
    // Android returns the JSON string quoted once more.
    const android = r'"{\"t\":\"Just a moment...\",\"h\":\"a.dramafren.org\",'
        r'\"r\":\"complete\",\"c\":true}"';
    final a = PageState.fromJsResult(android);
    expect(a.isChallenge, isTrue);
    expect(a.isClearOn('a.dramafren.org'), isFalse);

    const ios = '{"t":"Stardust Player","h":"a.dramafren.org",'
        '"r":"complete","c":false}';
    final i = PageState.fromJsResult(ios);
    expect(i.isChallenge, isFalse);
    expect(i.isClearOn('a.dramafren.org'), isTrue);
    expect(i.isClearOn('b.dramafren.org'), isFalse);

    const loading = '{"t":"","h":"a.dramafren.org","r":"loading","c":false}';
    expect(PageState.fromJsResult(loading).isClearOn('a.dramafren.org'),
        isFalse);
    expect(PageState.fromJsResult('garbage').isChallenge, isFalse);
    expect(PageState.fromJsResult(null).host, '');
  });

  test('user agent drops the WebView markers', () {
    const wv = 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/131.0.6778.39 Mobile Safari/537.36';
    final ua = chromeUaFrom(wv);
    expect(ua, contains('Chrome/131.0.0.0 Mobile Safari/537.36'));
    expect(ua, isNot(contains('; wv')));
    expect(ua, isNot(contains('Version/4.0')));
    expect(chromeUaFrom(null), kFallbackChromeUa);
  });

  test('origin helpers', () {
    expect(originOf('https://starshort.dramafren.org/index.php?page=home'),
        'https://starshort.dramafren.org');
    expect(originOf('https://a.b:8443/x'), 'https://a.b:8443');
    expect(originOf('index.php'), '');
    expect(siteOf('starshort.dramafren.org'), 'dramafren.org');
  });

  test('flagged origin fails fast (no WebView, no wait)', () async {
    const origin = 'https://stardusttv.dramafren.org';
    final ws = WebSession.instance;
    ws.needsVerification.value = {origin};
    addTearDown(() => ws.needsVerification.value = const {});

    final sw = Stopwatch()..start();
    await expectLater(
      StardustSource().search('love'),
      throwsA(isA<NeedsVerificationException>()
          .having((e) => e.origin, 'origin', origin)),
    );
    expect(sw.elapsedMilliseconds, lessThan(500));
  });
}
