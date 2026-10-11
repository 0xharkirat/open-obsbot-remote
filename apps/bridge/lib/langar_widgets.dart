import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'health.dart';
import 'langar_theme.dart';

/// A place's status mark: a steel thali.
///
/// The state is a shape, not only a colour, so it reads in a dim hall and
/// without colour vision. No patterns (the user ruled them out):
///   served   a filled green plate with a white tick
///   waiting  an open green ring, one quarter heavier (in progress)
///   needs    a solid turmeric plate with a white exclamation mark
///
/// The signature move: when a place changes state, the plate fills from its
/// centre outward in 240 ms, or empties back. Nothing around it moves.
class ThaliMark extends StatefulWidget {
  const ThaliMark({super.key, required this.state, this.size = 44});

  final PlaceState state;
  final double size;

  @override
  State<ThaliMark> createState() => _ThaliMarkState();
}

class _ThaliMarkState extends State<ThaliMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: widget.state == PlaceState.waiting ? 0 : 1,
  );

  @override
  void didUpdateWidget(ThaliMark old) {
    super.didUpdateWidget(old);
    if (old.state == widget.state) return;
    if (widget.state == PlaceState.waiting) {
      // Emptying is the same authored moment, run backward.
      _fill.reverse();
    } else {
      _fill.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: switch (widget.state) {
        PlaceState.served => 'ready',
        PlaceState.waiting => 'waiting',
        PlaceState.needs => 'needs you',
      },
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _fill,
          builder: (context, _) => CustomPaint(
            painter: _ThaliPainter(
              state: widget.state,
              fill: Curves.easeOutExpo.transform(_fill.value),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThaliPainter extends CustomPainter {
  _ThaliPainter({required this.state, required this.fill});

  final PlaceState state;
  final double fill;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    const rim = 4.0;

    if (state == PlaceState.needs) {
      // Needs you: a solid turmeric plate with a white exclamation mark.
      canvas.drawCircle(c, r * fill, Paint()..color = Langar.turmericMark);
      if (fill > 0.6) {
        final white = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(3, r * 0.18)
          ..strokeCap = StrokeCap.round
          ..color = Langar.surface;
        canvas.drawLine(Offset(c.dx, c.dy - r * 0.42), Offset(c.dx, c.dy + r * 0.12), white);
        canvas.drawCircle(
          Offset(c.dx, c.dy + r * 0.42),
          math.max(1.8, r * 0.1),
          Paint()..color = Langar.surface,
        );
      }
      return;
    }

    if (state == PlaceState.served && fill > 0) {
      // Connected: a filled green plate with a white tick, so the state
      // still reads by shape (filled, ticked) and not by colour alone.
      final inner = (r - rim) * fill;
      canvas.drawCircle(c, r * fill, Paint()..color = Langar.green);
      if (fill > 0.6) {
        final s = inner * 0.9;
        final tick = Path()
          ..moveTo(c.dx - s * 0.48, c.dy + s * 0.02)
          ..lineTo(c.dx - s * 0.12, c.dy + s * 0.36)
          ..lineTo(c.dx + s * 0.50, c.dy - s * 0.32);
        canvas.drawPath(
          tick,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(2.5, r * 0.16)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = Langar.surface,
        );
      }
      return;
    }

    // In progress (starting, waiting for the bridge): an open green ring
    // with one quarter drawn heavier, so it reads as on its way rather than
    // as broken.
    canvas.drawCircle(
      c,
      r - rim / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rim * 0.6
        ..color = Langar.greenSoft,
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r - rim / 2),
      -math.pi / 2,
      math.pi / 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rim
        ..strokeCap = StrokeCap.round
        ..color = Langar.green,
    );
  }

  @override
  bool shouldRepaint(_ThaliPainter old) =>
      old.state != state || old.fill != fill;
}

/// The maroon runner band at the top of the window, with one plain jute
/// edge. No woven pattern: the user ruled it out (2026-10-11).
class RunnerBand extends StatelessWidget {
  const RunnerBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Langar.maroon,
        border: Border(bottom: BorderSide(color: Langar.jute, width: 4)),
      ),
      child: child,
    );
  }
}

/// One set place in the row: thali, name and the real value behind it.
///
/// A place that needs you gains a turmeric edge and tint. It never changes
/// size or position, so the eye finds every place where it was last time.
class PlaceTile extends StatelessWidget {
  const PlaceTile({super.key, required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final needs = place.state == PlaceState.needs;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutExpo,
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: needs ? Langar.turmericTint : Langar.surface,
        borderRadius: BorderRadius.circular(Langar.radius),
        border: Border.all(
          color: needs ? Langar.turmeric : Langar.line,
          width: needs ? 2 : 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x0F1D2125), offset: Offset(0, 2), blurRadius: 6),
        ],
      ),
      // At the 720 px minimum window a place is about 155 px wide: a
      // smaller thali leaves the value room on one line.
      child: LayoutBuilder(
        builder: (context, box) => Row(
        children: <Widget>[
          ThaliMark(state: place.state, size: box.maxWidth < 190 ? 34 : 44),
          SizedBox(width: box.maxWidth < 190 ? 10 : 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  place.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Langar.title,
                ),
                const SizedBox(height: 2),
                // Two value lines are always reserved, so every place's name
                // sits on the same line whether or not its value wraps.
                SizedBox(
                  height: Langar.meta.fontSize! * Langar.meta.height! * 2,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      place.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Langar.meta.copyWith(
                        color: needs ? Langar.onTurmericTint : Langar.inkSoft,
                        fontWeight: needs ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}

/// A plain white panel: the one container style in this window.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.attention = false});

  final Widget child;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: attention ? Langar.turmericTint : Langar.surface,
        borderRadius: BorderRadius.circular(Langar.radius),
        border: Border.all(
          color: attention ? Langar.turmeric : Langar.line,
          width: attention ? 2 : 1,
        ),
      ),
      child: child,
    );
  }
}

/// The ON AIR mark on the camera that OBS shows now.
class OnAirPill extends StatelessWidget {
  const OnAirPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Langar.maroon,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // White, never turmeric: turmeric is reserved for "needs you".
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(color: Langar.onMaroon, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          const Text(
            'ON AIR',
            style: TextStyle(
              fontFamily: Langar.font,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Langar.onMaroon,
            ),
          ),
        ],
      ),
    );
  }
}
