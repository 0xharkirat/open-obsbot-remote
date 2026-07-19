import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ptz_tuning.dart';
import 'ws_client.dart';

// Reusable manual-PTZ control widgets, shared by the v3 Live screen's
// framing panel. Extracted from the retired ControlScreen; the gesture
// model (tap-nudge / hold-glide / squared joystick / double-stop) is
// the v3 P1 precision engine (see ptz_tuning.dart).

class HoldDirBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final WsClient client;
  final double yawSpeed;
  final double pitchSpeed;
  const HoldDirBtn({
    super.key,
    required this.icon,
    required this.label,
    required this.client,
    required this.yawSpeed,
    required this.pitchSpeed,
  });

  @override
  State<HoldDirBtn> createState() => HoldDirBtnState();
}

/// Press-and-hold directional button used by the 8-way pad on the
/// Buttons tab.
///
/// Pre-revamp this wrapped a `Listener` inside a `FilledButton.tonal`
/// with a no-op `onPressed: () {}`. Two problems on Flutter web (Mac
/// Safari + iPhone Safari) + in Material's gesture arena:
///
///   - The button's internal `TapGestureRecognizer` won the gesture
///     arena on a quick tap, so the inner `Listener.onPointerUp` never
///     fired and the ticker kept running until the next button press.
///   - On vertical drags (Up / Down on the 3×3 pad) the surrounding
///     `SingleChildScrollView` claimed the pointer once the user's
///     finger moved a few pixels, cancelling the press silently with
///     no velocity actually delivered to the bridge - user reported
///     "up / down don't work".
///
/// This rewrite uses a raw `Listener` directly on a `Material` surface
/// (no Button wrapper) so press / release / cancel events are first-
/// class and no upstream recognizer can steal them.
class HoldDirBtnState extends State<HoldDirBtn> {
  Timer? _holdStarter; // fires at the tap/hold threshold -> begin glide
  Timer? _ticker; // velocity refresh while gliding
  // Held time is counted in refresh ticks rather than a Stopwatch: the
  // ticker IS the clock that drives the ramp, so the ramp is exactly
  // reproducible (and testable under fake async, where a Stopwatch's
  // wall clock stands still).
  Duration _held = Duration.zero;
  bool _down = false;
  bool _gliding = false;

  // The widget's legacy yawSpeed/pitchSpeed fields carry DIRECTION now;
  // magnitude comes from the speed preset + ramp (v3 P1). Signs keep
  // the viewer-frame convention: +yaw right, +pitch up.
  double get _yawSign => widget.yawSpeed.sign;
  double get _pitchSign => widget.pitchSpeed.sign;

  void _start() {
    if (_down) return;
    _down = true;
    HapticFeedback.selectionClick();
    setState(() {});
    // Nothing moves yet: a release before the threshold is a TAP and
    // becomes a nudge - an absolute step that cannot overshoot. Only a
    // genuine hold starts the motors.
    _holdStarter = Timer(kTapHoldThreshold, _beginGlide);
  }

  void _beginGlide() {
    if (!_down) return;
    _gliding = true;
    _held = Duration.zero;
    _sendGlide();
    _ticker = Timer.periodic(kVelocityRefresh, (_) {
      _held += kVelocityRefresh;
      _sendGlide();
    });
  }

  void _sendGlide() {
    final ceiling = ceilingDegPerSec(widget.client.ptzSpeed);
    final v = rampVelocity(_held, ceiling);
    widget.client.ptzVelocity(
      yawSpeed: _yawSign * v,
      pitchSpeed: _pitchSign * v,
    );
  }

  void _end() {
    if (!_down) return;
    _down = false;
    _holdStarter?.cancel();
    _holdStarter = null;
    final wasGlide = _gliding;
    _gliding = false;
    _ticker?.cancel();
    _ticker = null;
    if (wasGlide) {
      // Two independent stops (plus the bridge's 400ms watchdog) so a
      // single lost packet cannot leave the gimbal running.
      widget.client.ptzStop();
      Timer(kDoubleStopDelay, () => widget.client.ptzStop());
    } else {
      widget.client.ptzNudge(yawSign: _yawSign, pitchSign: _pitchSign);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _holdStarter?.cancel();
    _ticker?.cancel();
    if (_gliding) widget.client.ptzStop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _start(),
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      child: Material(
        color: _down ? cs.primary : cs.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                widget.icon,
                size: 22,
                color: _down ? cs.onPrimary : cs.onSurface,
              ),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  color: _down ? cs.onPrimary : cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class PtzPad extends StatefulWidget {
  final WsClient client;
  const PtzPad({super.key, required this.client});

  @override
  State<PtzPad> createState() => _PtzPadState();
}

class _PtzPadState extends State<PtzPad> {
  Offset _delta = Offset.zero;
  bool _dragging = false;
  Timer? _ticker;

  void _start(Offset local, Size size) {
    setState(() {
      _dragging = true;
    });
    HapticFeedback.selectionClick();
    _ticker = Timer.periodic(kVelocityRefresh, (_) {
      // v3 P1: squared response into the speed preset's ceiling. Half
      // deflection = quarter speed, so the middle of the stick is a
      // precision zone instead of already-too-fast (the v2 linear map
      // hit 60 deg/s at half stick - unusable for framing).
      final ceiling = ceilingDegPerSec(widget.client.ptzSpeed);
      widget.client.ptzVelocity(
        yawSpeed: joystickAxisSpeed(_delta.dx, ceiling),
        pitchSpeed: joystickAxisSpeed(-_delta.dy, ceiling),
      );
    });
  }

  void _update(Offset local, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final maxR = math.min(cx, cy);
    final dx = ((local.dx - cx) / maxR).clamp(-1.0, 1.0);
    final dy = ((local.dy - cy) / maxR).clamp(-1.0, 1.0);
    setState(() => _delta = Offset(dx, dy));
  }

  void _end() {
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _delta = Offset.zero;
      _dragging = false;
    });
    // Double stop: two independent packets, bridge watchdog behind them.
    widget.client.ptzStop();
    Timer(kDoubleStopDelay, () => widget.client.ptzStop());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (DragStartDetails d) {
            _update(d.localPosition, size);
            _start(d.localPosition, size);
          },
          onPanUpdate: (DragUpdateDetails d) {
            _update(d.localPosition, size);
          },
          onPanEnd: (_) => _end(),
          onPanCancel: _end,
          child: CustomPaint(
            painter: _PadPainter(
              delta: _delta,
              dragging: _dragging,
              color: Theme.of(context).colorScheme.primary,
              base: Theme.of(context).colorScheme.surfaceContainerHighest,
              outline: Theme.of(context).colorScheme.outline,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _PadPainter extends CustomPainter {
  final Offset delta;
  final bool dragging;
  final Color color;
  final Color base;
  final Color outline;

  _PadPainter({
    required this.delta,
    required this.dragging,
    required this.color,
    required this.base,
    required this.outline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(cx, cy) * 0.95;
    final c = Offset(cx, cy);

    final ring = Paint()
      ..style = PaintingStyle.fill
      ..color = base;
    canvas.drawCircle(c, r, ring);

    final ringStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = outline.withValues(alpha: 0.4);
    canvas.drawCircle(c, r, ringStroke);

    // crosshairs
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline.withValues(alpha: 0.3);
    canvas.drawLine(Offset(cx - r, cy), Offset(cx + r, cy), cross);
    canvas.drawLine(Offset(cx, cy - r), Offset(cx, cy + r), cross);

    // knob
    final knobPos = Offset(cx + delta.dx * r * 0.85, cy + delta.dy * r * 0.85);
    final knob = Paint()
      ..style = PaintingStyle.fill
      ..color = dragging ? color : color.withValues(alpha: 0.6);
    canvas.drawCircle(knobPos, r * 0.18, knob);

    final knobOutline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.8);
    canvas.drawCircle(knobPos, r * 0.18, knobOutline);
  }

  @override
  bool shouldRepaint(covariant _PadPainter old) =>
      old.delta != delta || old.dragging != dragging;
}

// ----------------------------------------------------------------------------

class ZoomSlider extends StatefulWidget {
  final WsClient client;
  final DeviceState state;
  const ZoomSlider({super.key, required this.client, required this.state});

  @override
  State<ZoomSlider> createState() => _ZoomSliderState();
}

class _ZoomSliderState extends State<ZoomSlider> {
  double? _dragValue;
  double? _target; // last value we told the lens to reach
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  // 100ms fired ~10 absolute-position commands/sec while dragging, and the lens
  // motor chased every one - the source of the stutter. 160ms is still smooth
  // to the finger but gives the lens room to move between commands.
  static const _minSendGap = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    // Release-settle: keep showing the released value until the lens actually
    // reaches it, THEN track the camera again. The old code cleared the drag
    // override on a fixed 200ms timer, which snapped the thumb back to a
    // mid-move s.zoom - the "jump" on release.
    if (_dragValue != null &&
        _target != null &&
        (s.zoom - _target!).abs() < 0.03) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _dragValue = null;
            _target = null;
          });
        }
      });
    }
    final v = _dragValue ?? s.zoom;
    return Column(
      children: <Widget>[
        Text(
          '${v.toStringAsFixed(2)}×',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: s.zoomMin,
              max: s.zoomMax,
              value: v.clamp(s.zoomMin, s.zoomMax),
              // Mid-drag updates: send throttled live so the lens follows
              // your finger smoothly. Bridge coalesces server-side too
              // (see cmd_zoom_set).
              onChanged: (double nv) {
                setState(() => _dragValue = nv);
                final now = DateTime.now();
                if (now.difference(_lastSent) < _minSendGap) return;
                _lastSent = now;
                _target = nv;
                // Mid-drag is always instant (duration zero) so the lens
                // follows the finger; a chosen move-duration would make the
                // bridge planner cancel-and-restart on each command and never
                // settle. Throttled by _minSendGap so the lens is not chasing
                // ten targets a second.
                widget.client.zoomSet(nv, duration: Duration.zero);
              },
              onChangeEnd: (double nv) {
                // Land exactly on the released value. terminal:true bypasses the
                // bridge's mid-drag coalesce; duration stays zero so the lens
                // snaps to the final target instead of drifting there slowly.
                _target = nv;
                widget.client.zoomSet(nv, terminal: true);
                _lastSent = DateTime.now();
                // Do NOT clear _dragValue on a timer - that caused the thumb to
                // jump to a mid-move s.zoom. build() drops it once the reported
                // zoom converges on _target.
                HapticFeedback.lightImpact();
              },
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${s.zoomMin.toInt()}×',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
