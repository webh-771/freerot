import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';

/// Human-friendly one-liner for an exception.
String friendlyError(Object? error) {
  if (error is SocketException || error is HttpException) {
    return "Can't reach the server. Check your connection.";
  }
  if (error is TimeoutException) return 'That took too long.';
  if (error is UnimplementedError) return 'Not available yet.';
  return 'Something went wrong.';
}

/// Centered error message with a retry button.
class ErrorView extends StatelessWidget {
  final Object? error;
  final VoidCallback? onRetry;
  final bool compact;

  const ErrorView({super.key, this.error, this.onRetry, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: 32, vertical: compact ? 16 : 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact) ...[
              const Icon(Icons.cloud_off_outlined,
                  color: AppColors.textFaint, size: 32),
              const SizedBox(height: 16),
            ],
            Text(
              friendlyError(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textMuted),
            ),
            if (onRetry != null) ...[
              SizedBox(height: compact ? 4 : 12),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Short quiet line of text for empty states.
class EmptyView extends StatelessWidget {
  final String message;
  final IconData? icon;

  /// Optional quiet "Refresh" action under the message.
  final VoidCallback? onRetry;

  const EmptyView({super.key, required this.message, this.icon, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: AppColors.textFaint, size: 32),
              const SizedBox(height: 14),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textMuted),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Refresh')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small spinner used at the end of an infinite list.
class LoadingFooter extends StatelessWidget {
  const LoadingFooter({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
}

/// N-column grid delegate whose tile height = 3:4 cover + [footerExtent]
/// (title lines), scaled with the ambient text scale.
class PosterGridDelegate extends SliverGridDelegate {
  final int columns;
  final double spacing;
  final double runSpacing;
  final double footerExtent;

  const PosterGridDelegate({
    this.columns = 3,
    this.spacing = 12,
    this.runSpacing = 20,
    this.footerExtent = 44,
  });

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = (constraints.crossAxisExtent - spacing * (columns - 1)) /
        columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: spacing,
      mainAxisSpacing: runSpacing,
      mainAxisExtent: width * 4 / 3 + footerExtent,
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(PosterGridDelegate old) =>
      old.columns != columns ||
      old.spacing != spacing ||
      old.runSpacing != runSpacing ||
      old.footerExtent != footerExtent;
}

/// Footer extent for a poster with a two-line title under the current
/// text scale.
double posterFooterExtent(BuildContext context, {bool subtitle = false}) {
  final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
  return 8 + (12 * 1.3 * 2 + (subtitle ? 16 : 0)) * scale + 6;
}
