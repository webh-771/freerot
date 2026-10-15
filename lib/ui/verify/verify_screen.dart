// OWNER: web-session agent. Full-screen "Quick check" popup: shows the real
// site in a visible WebView so the *user* can complete the Cloudflare check.
// The app only watches the page title/state to notice when it's done; it
// never clicks, types or injects anything into the challenge.
//
// Opened through WebSession.verify(); pops `true` once a normal page of the
// origin has loaded, `false` when closed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/web/challenge.dart';
import '../theme.dart';

class VerifyScreen extends StatefulWidget {
  /// `https://host` of the site to verify.
  final String origin;

  /// Must match the UA of the background workers so the clearance applies.
  final String userAgent;

  const VerifyScreen({
    super.key,
    required this.origin,
    required this.userAgent,
  });

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  late final WebViewController _web;
  late final String _host = Uri.parse(widget.origin).host;
  Timer? _poll;
  bool _pageLoaded = false;
  bool _checking = false;
  int _cleanPolls = 0;
  int _progress = 0;
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.background)
      ..setUserAgent(widget.userAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageStarted: (_) => _cleanPolls = 0,
        onPageFinished: (_) {
          _pageLoaded = true;
          _check();
        },
        onNavigationRequest: (r) {
          if (!r.isMainFrame) return NavigationDecision.navigate;
          final h = Uri.tryParse(r.url)?.host ?? '';
          // The site and Cloudflare only; ad scripts try to redirect away.
          return (h == _host || h.endsWith('challenges.cloudflare.com'))
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse('${widget.origin}/'));
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Read-only look at the page: done when a normal page of the origin shows
  /// on two polls in a row (not the "Just a moment..." interstitial).
  Future<void> _check() async {
    if (_verified || _checking || !_pageLoaded || !mounted) return;
    _checking = true;
    try {
      final st = PageState.fromJsResult(
        await _web.runJavaScriptReturningResult(kPageStateJs),
      );
      if (st.isClearOn(_host)) {
        if (++_cleanPolls >= 2) _done();
      } else {
        _cleanPolls = 0;
      }
    } catch (_) {
      _cleanPolls = 0;
    } finally {
      _checking = false;
    }
  }

  void _done() {
    if (_verified || !mounted) return;
    _poll?.cancel();
    setState(() => _verified = true);
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final loading = _progress < 100 && !_verified;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quick check',
                            style: TextStyle(
                              color: AppColors.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            "Tap the box to confirm you're human. "
                            'This is needed once per site.',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textMuted,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.outline),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        WebViewWidget(controller: _web),
                        if (loading)
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: LinearProgressIndicator(
                              minHeight: 2,
                              value: _progress <= 0 ? null : _progress / 100,
                              color: AppColors.accent,
                              backgroundColor: Colors.transparent,
                            ),
                          ),
                        IgnorePointer(
                          ignoring: !_verified,
                          child: AnimatedOpacity(
                            opacity: _verified ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: const ColoredBox(
                              color: AppColors.background,
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: AppColors.accent,
                                      size: 44,
                                    ),
                                    SizedBox(height: 12),
                                    Text(
                                      'Verified',
                                      style: TextStyle(
                                        color: AppColors.text,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: Text(
                _host,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textFaint,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
