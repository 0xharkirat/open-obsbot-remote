import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ws_client.dart';

/// Visual aid overlay composited on top of the MJPEG preview.
///
/// Four layers, all optional, all toggleable independently:
///   • center crosshair         -  small `+` at frame center; gap in the
///                               middle so it doesn't bisect faces. This
///                               is the "you are pointing here right now"
///                               mark.
///   • attitude indicator       -  full-width / full-height cross that
///                               *moves* relative to the static center,
///                               showing where the camera's home position
///                               (yaw 0, pitch 0) sits in the current
///                               view. Like an aircraft attitude indicator:
///                               horizon line translates with pitch +
///                               rotates with roll, vertical reference
///                               translates with yaw. Align the moving
///                               cross with the static crosshair to
///                               re-center the camera.
///   • rule-of-thirds grid      -  dashed lines at 1/3 and 2/3 both axes
///   • Pan / Tilt readout       -  top-left text showing live pan (yaw) +
///                               tilt (pitch) in degrees so the operator
///                               knows the gimbal's current attitude
///
/// The overlay listens to `client.state.yaw / pitch / roll / fov` via
/// AnimatedBuilder wherever it's mounted (see PreviewWidget). The
/// attitude indicator renders in saturated HUD green over a dark
/// outline (flight-sim convention; reads on bright and dark frames);
/// the static crosshair / rule-of-thirds / readout are white at
/// 30%/60% opacity so they don't compete with the moving green cross.
/// `IgnorePointer` keeps every layer below tap-invisible.
///
/// When home is panned outside the visible frame the moving cross is
/// clamped to the nearest edge with a small arrow tip pointing toward
/// the actual heading, so the operator always sees which way to pan
/// back to re-center.
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
              roll: s.roll,
              fovH: s.fov.toDouble(),
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
  final double roll;
  final double fovH;
  final bool showCrosshair;
  final bool showCenterLines;
  final bool showThirds;
  final bool showReadout;

  _GridPainter({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.fovH,
    required this.showCrosshair,
    required this.showCenterLines,
    required this.showThirds,
    required this.showReadout,
  });

  static const _white30 = Color(0x4DFFFFFF);
  static const _white60 = Color(0x99FFFFFF);
  static const _shadow  = Color(0x66000000);

  // HUD green for the attitude indicator. Flight-simulator / camera-rig
  // HUDs use a saturated green because it reads against both bright sky
  // and dark interior frames without competing with skin tones. The
  // `_hudGreenShadow` is a near-black outline drawn under the line + ring
  // so the green stays visible on washed-out / blown-out frames.
  static const _hudGreen       = Color(0xFF00FF66);
  static const _hudGreenShadow = Color(0xCC003314);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // Order matters: attitude indicator under thirds under fixed
    // crosshair under text, so the most-meaningful layer (the moving
    // cross showing where home is) reads clearly without bisecting
    // the static reference marks.
    if (showCenterLines) _paintAttitude(canvas, w, h);
    if (showThirds) _paintThirds(canvas, w, h);
    if (showCrosshair) _paintCrosshair(canvas, w, h);
    if (showReadout) _paintReadout(canvas, w, h);
  }

  void _paintAttitude(Canvas canvas, double w, double h) {
    // Aircraft-style attitude indicator. The pair of lines shows where
    // the camera's home position (yaw=0, pitch=0, roll=0) sits in the
    // current view:
    //   * Camera pans right (yaw +) → the vertical reference shifts
    //     LEFT (home is now to the left of the camera's view).
    //   * Camera tilts up (pitch +) → the horizontal reference shifts
    //     DOWN (home is now below the camera's view).
    //   * Gimbal rolls (roll +) → the cross rotates so the "horizon"
    //     stays visually level relative to gravity (the camera image is
    //     rotated by +roll, so we counter-rotate by -roll in painter
    //     coords).
    //
    // To re-center the camera you steer the moving cross onto the
    // static crosshair at frame center.
    //
    // Edge handling: when home is panned outside the visible frame the
    // marker is clamped to the nearest edge (inset by `_edgeInset` so
    // the ring isn't half-clipped) and a small arrow tip is drawn at
    // the clamp point pointing in the *actual* heading direction. This
    // keeps the user oriented when the camera is panned far from home
    // instead of letting the marker silently disappear off-screen.

    final cx = w / 2;
    final cy = h / 2;

    // Approximate vertical FOV from the camera's reported horizontal
    // FOV by the displayed aspect ratio. Tiny 2 Lite reports 86° wide
    // / 78° normal / 65° narrow; the 16:9 frame is what we render.
    final aspect = h / w;
    final fovV = fovH * aspect;

    // Avoid div-by-zero on edge cases (some snapshots have fov=0
    // before the first state event arrives).
    final yawOffPx = fovH <= 0 ? 0.0 : -yaw / fovH * w;
    final pitchOffPx = fovV <= 0 ? 0.0 : pitch / fovV * h;
    final rawHomeX = cx + yawOffPx;
    final rawHomeY = cy + pitchOffPx;

    // Clamp the marker into the visible frame. Inset so the ring stays
    // wholly on-screen instead of being half-cropped at the boundary.
    const edgeInset = 14.0;
    final minX = edgeInset;
    final maxX = w - edgeInset;
    final minY = edgeInset;
    final maxY = h - edgeInset;
    final homeX = rawHomeX.clamp(minX, maxX);
    final homeY = rawHomeY.clamp(minY, maxY);
    final clampedX = rawHomeX != homeX;
    final clampedY = rawHomeY != homeY;
    final clamped = clampedX || clampedY;

    canvas.save();
    canvas.translate(homeX, homeY);
    canvas.rotate(-roll * math.pi / 180);

    // Length needs to span the rotated frame's diagonal at the most
    // extreme yaw/pitch offsets so the lines never "stop" inside the
    // visible area.
    final span = math.sqrt(w * w + h * h) * 1.2;

    // Shadow pass: a slightly thicker dark stroke under the green so
    // the indicator stays legible against bright / washed-out frames.
    final shadowLine = Paint()
      ..color = _hudGreenShadow
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(-span, 0), Offset(span, 0), shadowLine);
    canvas.drawLine(Offset(0, -span), Offset(0, span), shadowLine);

    final line = Paint()
      ..color = _hudGreen
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(-span, 0), Offset(span, 0), line);
    canvas.drawLine(Offset(0, -span), Offset(0, span), line);

    // Small ring on the moving cross so the user can spot the home
    // marker even when it's near an edge. Shadow first, then green.
    final ringShadow = Paint()
      ..color = _hudGreenShadow
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset.zero, 6.0, ringShadow);
    final ring = Paint()
      ..color = _hudGreen
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset.zero, 6.0, ring);

    canvas.restore();

    // When clamped, draw an arrow tip OUTSIDE the rotated frame (in
    // canvas-space, not painter-space) pointing toward the actual
    // heading. This avoids inheriting the gimbal roll - the arrow
    // should always point along world-axes (left/right/up/down) so
    // the operator knows which way to pan back.
    if (clamped) {
      final dx = clampedX ? (rawHomeX - homeX).sign : 0.0;
      final dy = clampedY ? (rawHomeY - homeY).sign : 0.0;
      _paintHeadingArrow(canvas, Offset(homeX, homeY), dx, dy);
    }
  }

  void _paintHeadingArrow(Canvas canvas, Offset at, double dx, double dy) {
    // Small triangle 12 px outside the ring, pointing along (dx, dy).
    // (dx, dy) is a unit-ish direction; both components are -1, 0, or +1.
    final len = math.sqrt(dx * dx + dy * dy);
    if (len <= 0) return;
    final ux = dx / len;
    final uy = dy / len;
    // Tip sits 14 px beyond the ring radius (6 px), so 20 px out.
    final tip = at + Offset(ux * 20, uy * 20);
    // Base is 8 px back from tip, ±4 px perpendicular.
    final back = tip - Offset(ux * 8, uy * 8);
    final perpX = -uy * 4;
    final perpY = ux * 4;
    final p1 = back + Offset(perpX, perpY);
    final p2 = back - Offset(perpX, perpY);

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();

    final fillShadow = Paint()
      ..color = _hudGreenShadow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, fillShadow);

    final fill = Paint()
      ..color = _hudGreen
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fill);
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
    // Small + at frame center  -  the "you are pointing here" fixed
    // reticle. Aircraft analogy: this is the airplane symbol fixed to
    // the cockpit; the attitude indicator's moving cross is the world
    // horizon.
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
      old.roll != roll ||
      old.fovH != fovH ||
      old.showCrosshair != showCrosshair ||
      old.showCenterLines != showCenterLines ||
      old.showThirds != showThirds ||
      old.showReadout != showReadout;
}
