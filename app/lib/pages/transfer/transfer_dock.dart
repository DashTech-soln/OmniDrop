import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/pages/transfer/transfer_strings.dart';

class TransferDock extends StatefulWidget {
  final int count;
  final bool active;
  final double bottomClearance;
  final VoidCallback onTap;

  const TransferDock({
    required this.count,
    required this.active,
    required this.bottomClearance,
    required this.onTap,
    super.key,
  });

  @override
  State<TransferDock> createState() => _TransferDockState();
}

class _TransferDockState extends State<TransferDock> with SingleTickerProviderStateMixin {
  static const _size = 60.0;
  static const _edgePadding = 12.0;
  static const _topPadding = 8.0;

  late final AnimationController _orbitController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  Offset? _position;
  Size? _lastSize;

  @override
  void initState() {
    super.initState();
    _setAnimating(widget.active);
  }

  @override
  void didUpdateWidget(covariant TransferDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _setAnimating(widget.active);
    }
  }

  void _setAnimating(bool active) {
    if (active) {
      unawaited(_orbitController.repeat());
    } else {
      _orbitController.stop();
      _orbitController.value = 0;
    }
  }

  Offset _clampPosition(Offset position, Size size) {
    final maxLeft = math.max(_edgePadding, size.width - _size - _edgePadding);
    final maxTop = math.max(
      _topPadding,
      size.height - widget.bottomClearance - _size,
    );
    return Offset(
      position.dx.clamp(_edgePadding, maxLeft).toDouble(),
      position.dy.clamp(_topPadding, maxTop).toDouble(),
    );
  }

  @override
  void dispose() {
    _orbitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final maxLeft = math.max(
          _edgePadding,
          size.width - _size - _edgePadding,
        );
        final maxTop = math.max(
          _topPadding,
          size.height - widget.bottomClearance - _size,
        );
        if (_lastSize != size) {
          _lastSize = size;
          _position = _position == null ? Offset(maxLeft, math.max(_topPadding, maxTop - 100)) : _clampPosition(_position!, size);
        }
        final position = _position!;

        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedPositioned(
              key: widget.key ?? const ValueKey('transfer-dock'),
              left: position.dx,
              top: position.dy,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: GestureDetector(
                onTap: widget.onTap,
                onPanUpdate: (details) {
                  setState(() {
                    _position = _clampPosition(
                      _position! + details.delta,
                      size,
                    );
                  });
                },
                onPanEnd: (_) {
                  setState(() {
                    final left = _position!.dx + _size / 2 < size.width / 2 ? _edgePadding : maxLeft;
                    _position = _clampPosition(
                      Offset(left, _position!.dy),
                      size,
                    );
                  });
                },
                child: Semantics(
                  button: true,
                  label: '${widget.count} ${TransferStrings.selected}',
                  child: RepaintBoundary(
                    child: SizedBox.square(
                      dimension: _size,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: 0.84),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.55),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.18),
                                  blurRadius: 14,
                                ),
                              ],
                            ),
                            child: SizedBox.square(
                              dimension: _size,
                              child: Center(
                                child: Text(
                                  '${widget.count}',
                                  key: const ValueKey('transfer-dock-count'),
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ),
                          if (widget.active)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _OrbitPainter(
                                    animation: _orbitController,
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
            ),
          ],
        );
      },
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final Animation<double> animation;

  _OrbitPainter({required this.animation}) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final colors = [glassCyan, glassViolet, Colors.redAccent];
    for (var node = 0; node < colors.length; node++) {
      final phase = animation.value * math.pi * 2 + node * math.pi * 2 / 3;
      for (var trail = 5; trail >= 0; trail--) {
        final angle = phase - trail * 0.09;
        final alpha = 0.09 + (5 - trail) * 0.14;
        final point = center + Offset(math.cos(angle), math.sin(angle)) * 29;
        canvas.drawCircle(
          point,
          trail == 0 ? 3 : 2,
          Paint()..color = colors[node].withValues(alpha: alpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) => oldDelegate.animation != animation;
}
