import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/library.dart';
import '../models.dart';
import 'detail/detail_screen.dart';
import 'player/player_screen.dart';
import 'theme.dart';
import 'widgets/states.dart';

/// Push the drama detail page.
Future<void> openDetail(BuildContext context, Drama drama) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => DetailScreen(drama: drama)),
  );
}

/// Push the player for [detail] at [ep].
Future<void> openPlayer(BuildContext context, DramaDetail detail, int ep,
    {int positionMs = 0}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        detail: detail,
        startEp: ep,
        startPositionMs: positionMs,
      ),
    ),
  );
}

/// Resume offset for a progress entry (0 if that episode is basically done).
int resumePositionFor(WatchProgress p) =>
    Library.isFinished(p) ? 0 : p.positionMs;

/// Fetch the detail for a continue-watching entry (with a small blocking
/// spinner) and jump straight into the player at the saved point.
Future<void> resumeProgress(BuildContext context, WatchProgress p) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  var cancelled = false;

  showDialog<void>(
    context: context,
    barrierColor: const Color(0x990B0B0C),
    builder: (_) => const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      ),
    ),
  ).then((_) => cancelled = true);

  DramaDetail? detail;
  Object? error;
  try {
    detail = await Catalog.instance.detail(p.drama);
  } catch (e) {
    error = e;
  }
  if (cancelled) return; // user backed out of the spinner
  cancelled = true;
  navigator.pop(); // close spinner

  if (detail == null) {
    messenger?.showSnackBar(SnackBar(
      content: Text(friendlyError(error)),
      action: SnackBarAction(
        label: 'Retry',
        textColor: AppColors.accent,
        onPressed: () {
          if (navigator.mounted) resumeProgress(navigator.context, p);
        },
      ),
    ));
    return;
  }
  await navigator.push(MaterialPageRoute<void>(
    builder: (_) => PlayerScreen(
      detail: detail!,
      startEp: p.ep,
      startPositionMs: resumePositionFor(p),
    ),
  ));
}

/// Confirm-and-remove sheet for a continue-watching entry.
Future<void> confirmRemoveProgress(BuildContext context, WatchProgress p) async {
  final remove = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              p.drama.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Remove from Continue watching?',
              style: Theme.of(ctx)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
  if (remove == true) await Library.instance.removeProgress(p.drama.key);
}
