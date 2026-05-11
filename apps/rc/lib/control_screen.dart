import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cache_menu.dart';
import 'sequencer_screen.dart';
import 'tab_shell.dart';
import 'ws_client.dart';

class ControlScreen extends StatefulWidget {
  final WsClient client;
  final VoidCallback? onSwitchSimple;
  const ControlScreen({super.key, required this.client, this.onSwitchSimple});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  Timer? _pingTimer;

  @override
  void initState() {
    super.initState();
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      widget.client.ping();
    });
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.client,
      builder: (BuildContext context, _) {
        final s = widget.client.state;
        return Scaffold(
          appBar: AppBar(
            title: Text('${s.modelDisplay} • ${s.sn.isEmpty ? '...' : s.sn}'),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text('${widget.client.lastLatencyMs} ms'),
                ),
              ),
              // Move-duration is controlled by the chip strip at the
              // bottom of every advanced-mode tab — no need to mirror
              // it in the AppBar. Simple mode (which has no chips)
              // still surfaces the popup in its own AppBar.
              _gridMenu(context),
              IconButton(
                tooltip: s.sequence.running ? 'Sequence running' : 'Sequence',
                icon: Icon(
                  s.sequence.running
                      ? Icons.multiline_chart
                      : Icons.timeline,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SequencerScreen(client: widget.client),
                  ),
                ),
              ),
              if (widget.onSwitchSimple != null)
                IconButton(
                  tooltip: 'Simple mode',
                  icon: const Icon(Icons.dashboard_customize),
                  onPressed: widget.onSwitchSimple,
                ),
              IconButton(
                tooltip: 'Disconnect',
                icon: const Icon(Icons.logout),
                onPressed: () => widget.client.close(),
              ),
              CacheMenu(onCleared: () => widget.client.close()),
            ],
          ),
          body: SafeArea(
            // Status chips removed in the post-review pass — every field
            // they carried has a dedicated home now:
            //   * Pan / Tilt → overlaid on the preview (grid readout).
            //   * Zoom       → next to the vertical zoom slider.
            //   * AI mode    → Image tab → Auto-track segmented.
            //   * FOV        → Image tab → View segmented.
            //   * runStatus  → tray icon glyph in the menubar.
            // Dropping the bar frees ~40 px of vertical space and gives
            // the live preview more room to breathe on phones.
            child: TabShell(client: widget.client),
          ),
        );
      },
    );
  }

  Widget _gridMenu(BuildContext ctx) {
    return PopupMenuButton<String>(
      tooltip: 'Grid overlay',
      icon: const Icon(Icons.grid_on),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: 'crosshair',
          checked: widget.client.gridCrosshair,
          child: const Text('Center crosshair'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'center',
          checked: widget.client.gridCenterLines,
          // Renamed in the live-test feedback round: the "center lines"
          // are no longer static — they translate with yaw / pitch and
          // rotate with roll, like an aircraft attitude indicator. Use
          // the airplane glyph so the menu hints at the new behavior.
          child: const Text('Attitude indicator (steer to align)'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'thirds',
          checked: widget.client.gridThirds,
          child: const Text('Rule of thirds'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'readout',
          checked: widget.client.gridReadout,
          child: const Text('Pan / Tilt readout'),
        ),
      ],
      onSelected: (v) {
        switch (v) {
          case 'crosshair':
            widget.client.setGridCrosshair(!widget.client.gridCrosshair);
          case 'center':
            widget.client.setGridCenterLines(!widget.client.gridCenterLines);
          case 'thirds':
            widget.client.setGridThirds(!widget.client.gridThirds);
          case 'readout':
            widget.client.setGridReadout(!widget.client.gridReadout);
        }
      },
    );
  }

}

// ----------------------------------------------------------------------------

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
///     no velocity actually delivered to the bridge — user reported
///     "up / down don't work".
///
/// This rewrite uses a raw `Listener` directly on a `Material` surface
/// (no Button wrapper) so press / release / cancel events are first-
/// class and no upstream recognizer can steal them.
class HoldDirBtnState extends State<HoldDirBtn> {
  Timer? _ticker;
  bool _down = false;

  void _start() {
    if (_down) return;
    _down = true;
    HapticFeedback.selectionClick();
    setState(() {});
    widget.client.ptzVelocity(
      yawSpeed: widget.yawSpeed,
      pitchSpeed: widget.pitchSpeed,
    );
    _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) {
      widget.client.ptzVelocity(
        yawSpeed: widget.yawSpeed,
        pitchSpeed: widget.pitchSpeed,
      );
    });
  }

  void _end() {
    if (!_down) return;
    _down = false;
    _ticker?.cancel();
    _ticker = null;
    widget.client.ptzStop();
    setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
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
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final dx = _delta.dx;
      final dy = _delta.dy;
      // map -1..1 → speed, then scale by the shared velocity slider
      // (`client.velocityScale`) so the joystick + the 8-way pad share
      // a single "how fast" knob.
      final scale = widget.client.velocityScale;
      final yawSpeed = (dx * 120 * scale).clamp(-150.0, 150.0);
      final pitchSpeed = (-dy * 60 * scale).clamp(-80.0, 80.0);
      widget.client.ptzVelocity(yawSpeed: yawSpeed, pitchSpeed: pitchSpeed);
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
    widget.client.ptzStop();
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
  final CameraState state;
  const ZoomSlider({super.key, required this.client, required this.state});

  @override
  State<ZoomSlider> createState() => _ZoomSliderState();
}

class _ZoomSliderState extends State<ZoomSlider> {
  double? _dragValue;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minSendGap = Duration(milliseconds: 100);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final v = _dragValue ?? s.zoom;
    return Column(
      children: <Widget>[
        Text('${v.toStringAsFixed(2)}×',
            style: const TextStyle(fontWeight: FontWeight.w600)),
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
                // When the user has picked a slow move-duration (e.g.
                // 5 s, 30 s, 3 min) the bridge planner runs to that
                // target. Sending a new value every 100 ms while
                // dragging would cancel-and-restart the planner at
                // each tick — lens motor stutters, never reaching
                // the target. So: mid-drag is always *instant* so the
                // lens follows your finger; the chosen move-duration
                // is applied only on release (terminal=true below).
                widget.client.zoomSet(nv, duration: Duration.zero);
              },
              onChangeEnd: (double nv) {
                // Final value uses the user's chosen move-duration so
                // a slow chip ("30 s") gives a smooth ease-in-out from
                // the current lens position to nv over that window.
                // `terminal:true` bypasses the bridge's mid-drag
                // coalesce so the lens always lands exactly on nv.
                widget.client.zoomSet(nv, terminal: true);
                _lastSent = DateTime.now();
                Future<void>.delayed(const Duration(milliseconds: 200),
                    () => mounted ? setState(() => _dragValue = null) : null);
                HapticFeedback.lightImpact();
              },
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('${s.zoomMin.toInt()}×',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
