// OWNER: web-session agent. Slim banner shown on Home/Search while some
// sources wait for the user's Cloudflare check. Hidden when nothing needs it.
import 'package:flutter/material.dart';

import '../../data/web/web_session.dart';
import '../theme.dart';

class VerifyBanner extends StatelessWidget {
  /// Called after at least one site was verified (e.g. to reload a feed).
  final VoidCallback? onVerified;
  final EdgeInsetsGeometry margin;

  const VerifyBanner({
    super.key,
    this.onVerified,
    this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 8),
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: WebSession.instance.needsVerification,
      builder: (context, pending, _) {
        return AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: pending.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: margin,
                  child: _Bar(
                    count: pending.length,
                    onVerify: () async {
                      final n =
                          await WebSession.instance.verifyAll(context);
                      if (n > 0) onVerified?.call();
                    },
                  ),
                ),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  final int count;
  final VoidCallback onVerify;
  const _Bar({required this.count, required this.onVerify});

  @override
  Widget build(BuildContext context) {
    final text = count == 1
        ? '1 source needs a quick check'
        : '$count sources need a quick check';
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined,
              size: 16, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onVerify,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Verify',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
