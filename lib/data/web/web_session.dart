// OWNER: web-session agent. Public signatures are a contract used by the
// Cloudflare-protected sources and the UI.
//
// Sites behind a Cloudflare challenge are fetched *inside a WebView on that
// site's origin* (same-origin fetch()), so requests carry the browser's own
// clearance. The challenge itself is only ever completed by the user, in a
// visible popup ([verify]); the app never tries to solve it automatically.
//
// How it works
//  * [WebSessionHost] keeps a small pool (max [WebSession.maxWorkers], LRU)
//    of 1x1 px WebViews attached to the tree, one per origin.
//  * [WebSession.get] makes sure the origin's worker has a document of that
//    origin loaded (`/robots.txt`: cheap, no ads), then runs
//    `fetch(url, {credentials:'include'})` in the page and gets the body back
//    through a JavaScript channel, keyed by request id.
//  * A challenge (worker title "Just a moment...", or a 403 challenge body)
//    records the origin in [WebSession.needsVerification] and throws
//    [NeedsVerificationException]. Later calls for that origin fail fast.
//  * [WebSession.verify] shows the real site in a visible WebView; the user
//    completes the check. Android's CookieManager is app-wide, so the
//    clearance then applies to the worker, which is reloaded.
//  * All WebViews use the same Chrome UA (no "; wv") so the clearance matches.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../ui/verify/verify_screen.dart';
import '../source.dart';
import 'challenge.dart';

/// Thrown when an origin needs the user to complete the Cloudflare check.
class NeedsVerificationException extends SourceException {
  final String origin;
  NeedsVerificationException(this.origin)
      : super('$origin needs a quick verification');
}

class WebSession {
  WebSession._();
  static final WebSession instance = WebSession._();

  /// Background WebViews alive at once (least recently used is dropped).
  static const int maxWorkers = 4;

  /// Per-request budget for fetch() inside the page.
  static const Duration requestTimeout = Duration(seconds: 20);

  /// Budget for loading the origin into a worker.
  static const Duration loadTimeout = Duration(seconds: 20);

  /// A worker that lands on a challenge waits this long for the page to
  /// finish on its own (non-interactive checks redirect by themselves)
  /// before the origin is handed to the user. Nothing touches the page.
  static const Duration challengeGrace = Duration(seconds: 4);

  static const String _channel = 'FreeRotBridge';

  final ValueNotifier<Set<String>> _needs = ValueNotifier<Set<String>>(
    const <String>{},
  );
  final LinkedHashMap<String, _Worker> _workers =
      LinkedHashMap<String, _Worker>();
  final Map<String, Future<bool>> _verifying = {};
  _WebSessionHostState? _host;
  Future<String>? _ua;
  int _seq = 0;

  /// GET [url] from within a WebView on its origin; returns the body text.
  /// Throws [NeedsVerificationException] if Cloudflare challenges the request
  /// (and records the origin in [needsVerification]).
  Future<String> get(String url, {Map<String, String>? headers}) async {
    final origin = originOf(url);
    if (origin.isEmpty) throw SourceException('Bad URL: $url');
    if (_needs.value.contains(origin)) throw NeedsVerificationException(origin);
    if (_host == null) {
      throw SourceException('Web session not ready (WebSessionHost missing)');
    }
    for (var attempt = 0;; attempt++) {
      final w = _workerFor(origin);
      try {
        await w.ensureReady();
        final r = await w.fetch(url, headers);
        if (isChallengeResponse(r.status, r.body, mitigated: r.mitigated)) {
          w.state = _WState.challenged;
          _flag(origin);
          throw NeedsVerificationException(origin);
        }
        if (r.status >= 400) throw SourceException('HTTP ${r.status}');
        return r.body;
      } on _WorkerReset {
        if (attempt >= 1) throw SourceException('Request interrupted');
      }
    }
  }

  /// Origins whose last request hit a challenge. UI shows a banner from this.
  ValueNotifier<Set<String>> get needsVerification => _needs;

  /// Show the verification popup (a visible WebView of [origin]) and let the
  /// user complete the check. Resolves true once the page loads normally.
  Future<bool> verify(BuildContext context, String origin) {
    final o = originOf(origin).isEmpty ? origin : originOf(origin);
    return _verifying[o] ??= _verify(context, o).whenComplete(
      () => _verifying.remove(o),
    );
  }

  Future<bool> _verify(BuildContext context, String origin) async {
    final ua = await userAgent();
    if (!context.mounted) return false;
    final ok = await Navigator.of(context, rootNavigator: true).push<bool>(
          MaterialPageRoute<bool>(
            fullscreenDialog: true,
            builder: (_) => VerifyScreen(origin: origin, userAgent: ua),
          ),
        ) ??
        false;
    if (ok) _onVerified(origin);
    return ok;
  }

  /// Walk the user through every origin in [needsVerification], one popup
  /// after another. Returns how many succeeded.
  Future<int> verifyAll(BuildContext context) async {
    var n = 0;
    for (final o in _needs.value.toList()) {
      if (!context.mounted) break;
      // A sibling verification may have cleared it already.
      if (!_needs.value.contains(o)) continue;
      final ok = await verify(context, o);
      if (!ok) break; // closed by the user: stop asking.
      n++;
    }
    return n;
  }

  /// The UA every WebView uses: the device's own Chrome version, in the
  /// format the Chrome app sends (no "; wv").
  Future<String> userAgent() => _ua ??= () async {
        try {
          return chromeUaFrom(await WebViewController().getUserAgent());
        } catch (_) {
          return kFallbackChromeUa;
        }
      }();

  // -------------------------------------------------------------- internals

  void _flag(String origin) {
    if (_needs.value.contains(origin)) return;
    _needs.value = {..._needs.value, origin};
  }

  void _unflag(String origin) {
    if (!_needs.value.contains(origin)) return;
    _needs.value = {..._needs.value}..remove(origin);
  }

  void _onVerified(String origin) {
    _unflag(origin);
    final w = _workers[origin];
    if (w != null) {
      w.state = _WState.idle;
      unawaited(w.ensureReady().then((_) {}, onError: (_) {}));
    }
    // cf_clearance is scoped to the zone: re-check sibling mirrors quietly.
    final site = siteOf(Uri.parse(origin).host);
    for (final o in _needs.value.toList()) {
      if (siteOf(Uri.parse(o).host) == site) unawaited(_recheck(o));
    }
  }

  Future<void> _recheck(String origin) async {
    if (_host == null) return;
    final w = _workerFor(origin)..state = _WState.idle;
    try {
      await w.ensureReady();
      _unflag(origin);
    } catch (_) {
      // Still challenged (re-flagged by ensureReady) or offline: keep it.
    }
  }

  _Worker _workerFor(String origin) {
    final existing = _workers.remove(origin);
    if (existing != null) {
      _workers[origin] = existing; // move to most-recently-used end
      return existing;
    }
    while (_workers.length >= maxWorkers) {
      final victim = _workers.values.firstWhere(
        (w) => w.idle,
        orElse: () => _workers.values.first,
      );
      _workers.remove(victim.origin);
      victim.dispose();
    }
    final w = _Worker(this, origin);
    _workers[origin] = w;
    _host?._changed();
    return w;
  }

  void _attach(_WebSessionHostState host) => _host = host;

  void _detach(_WebSessionHostState host) {
    if (_host != host) return;
    _host = null;
    for (final w in _workers.values) {
      w.dispose();
    }
    _workers.clear();
  }
}

enum _WState { idle, loading, ready, challenged }

class _FetchResult {
  final int status;
  final String body;
  final String mitigated;
  const _FetchResult(this.status, this.body, this.mitigated);
}

/// The worker's page was reloaded or dropped while a request was in flight.
class _WorkerReset implements Exception {
  const _WorkerReset();
}

class _Worker {
  _Worker(this.session, this.origin)
      : host = Uri.parse(origin).host,
        controller = WebViewController() {
    _init = _configure()..ignore(); // errors surface where _init is awaited
  }

  final WebSession session;
  final String origin;
  final String host;
  final WebViewController controller;
  final Map<int, Completer<_FetchResult>> _pending = {};
  late final Future<void> _init;
  _WState state = _WState.idle;
  Future<void>? _loading;
  Completer<void>? _pageFinished;
  bool _disposed = false;

  bool get idle => _pending.isEmpty && _loading == null;

  Future<void> _configure() async {
    final ua = await session.userAgent();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0x00000000));
    await controller.setUserAgent(ua);
    await controller.addJavaScriptChannel(
      WebSession._channel,
      onMessageReceived: _onMessage,
    );
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) {
        if (!r.isMainFrame) return NavigationDecision.navigate;
        final h = Uri.tryParse(r.url)?.host ?? '';
        // Stay on the origin: ad scripts on these pages try to redirect.
        return h == host
            ? NavigationDecision.navigate
            : NavigationDecision.prevent;
      },
      onPageFinished: (_) {
        final c = _pageFinished;
        if (c != null && !c.isCompleted) c.complete();
      },
      onWebResourceError: (e) {
        if (e.isForMainFrame == false) return;
        final c = _pageFinished;
        if (c != null && !c.isCompleted) {
          c.completeError(SourceException('Load failed: ${e.description}'));
        }
      },
    ));
  }

  /// Loads the origin (once; concurrent callers share the load).
  Future<void> ensureReady() async {
    if (_disposed) throw const _WorkerReset();
    if (state == _WState.ready) return;
    if (state == _WState.challenged) {
      session._flag(origin);
      throw NeedsVerificationException(origin);
    }
    await (_loading ??= _load().whenComplete(() => _loading = null));
    if (state == _WState.challenged) throw NeedsVerificationException(origin);
    if (state != _WState.ready) throw SourceException('$host did not load');
  }

  Future<void> _load() async {
    await _init;
    _failPending();
    state = _WState.loading;
    final finished = _pageFinished = Completer<void>();
    try {
      await controller.loadRequest(Uri.parse('$origin/robots.txt'));
      await finished.future.timeout(WebSession.loadTimeout);
    } on TimeoutException {
      state = _WState.idle;
      throw SourceException('$host timed out');
    } catch (e) {
      state = _WState.idle;
      rethrow;
    }
    var st = await _pageState();
    if (st.isChallenge) {
      final end = DateTime.now().add(WebSession.challengeGrace);
      while (st.isChallenge && DateTime.now().isBefore(end) && !_disposed) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        st = await _pageState();
      }
    }
    if (st.isChallenge) {
      state = _WState.challenged;
      session._flag(origin);
      // Park the invisible worker; the user completes the check in the
      // visible popup (WebSession.verify), never here.
      unawaited(controller
          .loadHtmlString('<html><head></head><body></body></html>')
          .then((_) {}, onError: (_) {}));
      throw NeedsVerificationException(origin);
    }
    if (st.host.isNotEmpty && st.host != host) {
      state = _WState.idle;
      throw SourceException('$host redirected to ${st.host}');
    }
    state = _WState.ready;
  }

  Future<PageState> _pageState() async {
    try {
      return PageState.fromJsResult(
        await controller.runJavaScriptReturningResult(kPageStateJs),
      );
    } catch (_) {
      return PageState.empty;
    }
  }

  Future<_FetchResult> fetch(String url, Map<String, String>? headers) async {
    final id = ++session._seq;
    final c = Completer<_FetchResult>();
    // May be failed by a reload before it's awaited below.
    c.future.ignore();
    _pending[id] = c;
    final js = '(function(){var id=$id;'
        'fetch(${jsonEncode(url)},{credentials:"include",'
        'headers:${jsonEncode(headers ?? const <String, String>{})}})'
        '.then(function(r){return r.text().then(function(t){'
        '${WebSession._channel}.postMessage(JSON.stringify({id:id,s:r.status,'
        'm:r.headers.get("cf-mitigated")||"",b:t}));});})'
        '.catch(function(e){${WebSession._channel}.postMessage('
        'JSON.stringify({id:id,s:0,e:String(e)}));});})();';
    try {
      await controller.runJavaScript(js);
      return await c.future.timeout(WebSession.requestTimeout);
    } on TimeoutException {
      throw SourceException('$host request timed out');
    } on _WorkerReset {
      rethrow;
    } on SourceException {
      rethrow;
    } catch (e) {
      throw SourceException('$host request failed: $e');
    } finally {
      _pending.remove(id);
    }
  }

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      final c = _pending.remove((j['id'] as num).toInt());
      if (c == null || c.isCompleted) return;
      if (j['e'] != null) {
        c.completeError(SourceException('$host fetch failed: ${j['e']}'));
        return;
      }
      c.complete(_FetchResult(
        (j['s'] as num?)?.toInt() ?? 0,
        j['b'] as String? ?? '',
        j['m'] as String? ?? '',
      ));
    } catch (_) {
      // Not ours (or malformed): ignore.
    }
  }

  void _failPending() {
    final all = _pending.values.toList();
    _pending.clear();
    for (final c in all) {
      if (!c.isCompleted) c.completeError(const _WorkerReset());
    }
  }

  void dispose() {
    _disposed = true;
    _failPending();
    final c = _pageFinished;
    if (c != null && !c.isCompleted) c.completeError(const _WorkerReset());
  }
}

/// Mount once near the root (wraps the app) so background WebViews that
/// perform [WebSession.get] exist in the widget tree.
class WebSessionHost extends StatefulWidget {
  final Widget child;
  const WebSessionHost({super.key, required this.child});

  @override
  State<WebSessionHost> createState() => _WebSessionHostState();
}

class _WebSessionHostState extends State<WebSessionHost> {
  @override
  void initState() {
    super.initState();
    WebSession.instance._attach(this);
  }

  @override
  void dispose() {
    WebSession.instance._detach(this);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // Workers can be created mid-build (e.g. a FutureBuilder starting a
    // fetch); defer the rebuild in that case.
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final workers = WebSession.instance._workers.values.toList();
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.passthrough,
      children: [
        widget.child,
        // 1x1 px, attached (not Offstage) so the pages keep running JS.
        for (final w in workers)
          Positioned(
            key: ValueKey<String>(w.origin),
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: WebViewWidget(controller: w.controller),
              ),
            ),
          ),
      ],
    );
  }
}
