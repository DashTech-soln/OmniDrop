import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';

const transferGaugeTickCount = 72;

int completedTransferGaugeTicks(double progress) {
  return (progress.clamp(0.0, 1.0) * transferGaugeTickCount).round();
}

class TransferGauge extends StatelessWidget {
  final double progress;
  final String elapsed;
  final String activeFile;
  final double size;

  const TransferGauge({
    required this.progress,
    required this.elapsed,
    required this.activeFile,
    this.size = 244,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedProgress = progress.clamp(0.0, 1.0);
    final scale = (size / 244).clamp(0.65, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(size),
              painter: TransferGaugePainter(
                progress: normalizedProgress,
                colors: Theme.of(context).colorScheme,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(normalizedProgress * 100).round()}%',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontSize: (Theme.of(context).textTheme.displaySmall?.fontSize ?? 36) * scale,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                SizedBox(height: 8 * scale),
                Text(
                  elapsed,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: (Theme.of(context).textTheme.labelLarge?.fontSize ?? 14) * scale,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 1.2,
                  ),
                ),
                SizedBox(height: 7 * scale),
                SizedBox(
                  width: size * 0.62,
                  child: Text(
                    activeFile,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: (Theme.of(context).textTheme.labelSmall?.fontSize ?? 11) * scale,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TransferGaugePainter extends CustomPainter {
  final double progress;
  final ColorScheme colors;

  TransferGaugePainter({required this.progress, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.39;
    final completedTicks = completedTransferGaugeTicks(progress);
    final tickPaint = Paint()
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    for (var tick = 0; tick < transferGaugeTickCount; tick++) {
      final angle = -math.pi / 2 + tick * math.pi * 2 / transferGaugeTickCount;
      final major = tick % 6 == 0;
      final innerRadius = radius - (major ? 13 : 8);
      final outerRadius = radius;
      tickPaint.color = tick < completedTicks
          ? Color.lerp(glassCyan, glassViolet, tick / transferGaugeTickCount)!
          : colors.onSurface.withValues(alpha: 0.18);
      if (tick < completedTicks) {
        tickPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2);
      } else {
        tickPaint.maskFilter = null;
      }
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * innerRadius,
        center + Offset(math.cos(angle), math.sin(angle)) * outerRadius,
        tickPaint,
      );
    }

    final arcRect = Rect.fromCircle(center: center, radius: radius + 15);
    canvas.drawArc(
      arcRect,
      -math.pi / 2,
      math.pi * 2,
      false,
      Paint()
        ..color = colors.primary.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant TransferGaugePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.colors != colors;
  }
}
