import 'package:flutter/material.dart';

import 'ws_client.dart';

/// Visual aid overlay composited on top of the MJPEG preview.
///
/// Four layers, all optional, all toggleable independently:
///   • center crosshair        — small `+` at frame center; gap in the
///                               middle so it doesn't bisect faces
///   • center reference lines  — full-width horizontal + full-height
///                               vertical lines through the dead center,
///                               for aligning subject to true center
///   • rule-of-thirds grid     — dashed lines at 1/3 and 2/3 both axes
///   • Pan / Tilt readout      — top-left text showing live pan (yaw) +
///                               tilt (pitch) in degrees so the operator
///                               knows the gimbal's current attitude
///
/// The overlay listens to `client.state.yaw / pitch` via AnimatedBuilder
/// wherever it's mounted (see PreviewWidget). White at 30%/60% opacity
/// so the overlay reads against bright and dark scenes without
/// obscuring the subject; `IgnorePointer` keeps every layer below tap-
/// invisible.
class GridOverlay extends StatelessWidget {
  final WsClient client;
  final bool showCrosshair;
  final bool showCenterLines;
  final bool showThirds;
  final bool showReadout;

  const GridOverlay({
    super.key,
    required this.client,
    this.showCrosshair = true,
    this.showCenterLines = false,
    this.showThirds = false,
    this.showReadout = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!showCrosshair && !showCenterLines && !showThirds && !showReadout) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        return IgnorePointer(
          child: CustomPaint(
            painter: _GridPainter(
              yaw: s.yaw,
              pitch: s.pitch,
              showCrosshair: showCrosshair,
              showCenterLines: showCenterLines,
              showThirds: showThirds,
              showReadout: showReadout,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  final double yaw;
  final double pitch;
  final bool showCrosshair;
  final bool showCenterLines;
  final bool showThirds;
  final bool showReadout;

  _GridPainter({
    required this.yaw,
    required this.pitch,
    required this.showCrosshair,
    required this.showCenterLines,
    required this.showThirds,
    required this.showReadout,
  });

  static const _white30 = Color(0x4DFFFFFF);
  static const _white45 = Color(0x73FFFFFF);
  static const _white60 = Color(0x99FFFFFF);
  static const _shadow  = Color(0x66000000);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    if (showCenterLines) _paintCenterLines(canvas, w, h);
    if (showThirds) _paintThirds(canvas, w, h);
    if (showCrosshair) _paintCrosshair(canvas, w, h);
    if (showReadout) _paintReadout(canvas, w, h);
  }

  void _paintCenterLines(Canvas canvas, double w, double h) {
    // Solid (not dashed) lines through dead center, both axes. Used for
    // aligning a vertical subject (mic stand, doorway) or a horizon to
    // the true center of frame — finer-grained than the rule-of-thirds
    // grid.
    final paint = Paint()
      ..color = _white45
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), paint);
    canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, h), paint);
  }

  void _paintThirds(Canvas canvas, double w, double h) {
    // Dashed lines at 1/3 and 2/3, both axes.
    final paint = Paint()
      ..color = _white30
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    for (final fx in <double>[1 / 3, 2 / 3]) {
      final x = w * fx;
      _drawDashedLine(canvas, Offset(x, 0), Offset(x, h), paint, 8, 6);
    }
    for (final fy in <double>[1 / 3, 2 / 3]) {
      final y = h * fy;
      _drawDashedLine(canvas, Offset(0, y), Offset(w, y), paint, 8, 6);
    }
  }

  void _paintCrosshair(Canvas canvas, double w, double h) {
    // Small + at frame center. Big enough to be visible but not enough
    // to obscure a face that happens to be centered.
    final cx = w / 2;
    final cy = h / 2;
    const arm = 12.0;
    const gap = 4.0;
    final paint = Paint()
      ..color = _white60
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Horizontal arms (left + right of center gap)
    canvas.drawLine(Offset(cx - arm - gap, cy), Offset(cx - gap, cy), paint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(cx + arm + gap, cy), paint);
    // Vertical arms (top + bottom of center gap)
    canvas.drawLine(Offset(cx, cy - arm - gap), Offset(cx, cy - gap), paint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, cy + arm + gap), paint);

    // Tiny ring at center
    final ringPaint = Paint()
      ..color = _white60
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), 2.0, ringPaint);
  }

  void _paintReadout(Canvas canvas, double w, double h) {
    // Top-left text. Two lines: Pan (left/right) + Tilt (up/down) in deg.
    // We use ←→ and ↑↓ glyphs so non-technical operators don't have to
    // remember which axis is "yaw" vs "pitch".
    final yawText   = 'PAN   ←→ ${yaw.toStringAsFixed(1)}°';
    final pitchText = 'TILT  ↑↓ ${pitch.toStringAsFixed(1)}°';

    void draw(String s, double y) {
      // Drop-shadow for legibility against bright backgrounds.
      final shadow = TextSpan(
        text: s,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _shadow,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      );
      final text = TextSpan(
        text: s,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _white60,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      );
      final tpShadow = TextPainter(text: shadow, textDirection: TextDirection.ltr)..layout();
      final tp       = TextPainter(text: text,   textDirection: TextDirection.ltr)..layout();
      tpShadow.paint(canvas, Offset(8 + 1, y + 1));
      tp.paint(canvas, Offset(8, y));
    }

    draw(yawText, 8);
    draw(pitchText, 22);
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint,
                       double dash, double gap) {
    final scalarLen = (b - a).distance;
    if (scalarLen <= 0) return;
    final nx = (b.dx - a.dx) / scalarLen;
    final ny = (b.dy - a.dy) / scalarLen;
    double traveled = 0;
    while (traveled < scalarLen) {
      final segEnd = (traveled + dash).clamp(0.0, scalarLen);
      canvas.drawLine(
        Offset(a.dx + nx * traveled, a.dy + ny * traveled),
        Offset(a.dx + nx * segEnd,   a.dy + ny * segEnd),
        paint,
      );
      traveled += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.showCrosshair != showCrosshair ||
      old.showThirds != showThirds ||
      old.showReadout != showReadout;
}
