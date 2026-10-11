import 'dart:ui';

import 'package:flutter/material.dart';

enum BrowserSurfaceStyle { clean, glass }

class BrowserThemeTokens {
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color primary;
  final Color secondary;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color icon;
  final Color selection;
  final Color destructive;
  final Color divider;

  const BrowserThemeTokens({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.primary,
    required this.secondary,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.icon,
    required this.selection,
    required this.destructive,
    required this.divider,
  });

  factory BrowserThemeTokens.of(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BrowserThemeTokens(
      background: Theme.of(context).scaffoldBackgroundColor,
      surface: colors.surface,
      surfaceElevated: colors.surfaceContainerHigh,
      primary: colors.primary,
      secondary: colors.secondary,
      border: colors.outlineVariant,
      textPrimary: colors.onSurface,
      textSecondary: colors.onSurfaceVariant,
      icon: colors.onSurfaceVariant,
      selection: colors.primary.withValues(alpha: 0.15),
      destructive: colors.error,
      divider: colors.outlineVariant.withValues(alpha: 0.65),
    );
  }
}

class BrowserSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadiusGeometry borderRadius;
  final BrowserSurfaceStyle style;
  final Color? color;

  const BrowserSurface({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.style = BrowserSurfaceStyle.clean,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = BrowserThemeTokens.of(context);
    final surfaceColor = color ?? (style == BrowserSurfaceStyle.clean ? tokens.surface : tokens.surface.withValues(alpha: 0.72));
    final surface = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: borderRadius,
        border: Border.all(
          color: tokens.border.withValues(
            alpha: style == BrowserSurfaceStyle.clean ? 0.75 : 0.55,
          ),
        ),
      ),
      child: child,
    );
    if (style == BrowserSurfaceStyle.clean) return surface;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: surface,
      ),
    );
  }
}
