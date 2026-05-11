import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cache_menu.dart';
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
              _speedMenu(context),
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
            child: Column(
              children: <Widget>[
                _statusBar(s),
                Expanded(child: TabShell(client: widget.client)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _speedMenu(BuildContext ctx) {
    final cur = widget.client.moveDuration;
    // Pick the icon of the closest preset; default to hourglass for
    // anything not in the chip list.
    IconData currentIcon = Icons.timer;
    for (final p in kMoveDurationPresets) {
      if (p.duration == cur) { currentIcon = p.icon; break; }
    }
    return PopupMenuButton<Duration>(
      tooltip: 'Move duration (Instant ↔ slow pan)',
      icon: Icon(currentIcon),
      onSelected: (d) => widget.client.setMoveDuration(d),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<Duration>>[
        for (final p in kMoveDurationPresets)
          CheckedPopupMenuItem<Duration>(
            value: p.duration,
            checked: p.duration == cur,
            child: Row(children: <Widget>[
              Icon(p.icon, size: 16),
              const SizedBox(width: 8),
              Text(p.label),
            ]),
          ),
      ],
    );
  }

  Widget _statusBar(CameraState s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _chip('YAW', '${s.yaw.toStringAsFixed(1)}°'),
          _chip('PITCH', '${s.pitch.toStringAsFixed(1)}°'),
          _chip('ZOOM', '${s.zoom.toStringAsFixed(2)}×'),
          _chip('AI', s.aiMode),
          _chip('FOV', '${s.fov}°'),
          if (s.runStatus != 'run') _chip('STATUS', s.runStatus.toUpperCase()),
        ],
      ),
    );
  }

  Widget _chip(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text.rich(TextSpan(children: <TextSpan>[
        TextSpan(text: '$k ', style: TextStyle(
          color: Theme.of(context).colorScheme.outline,
          fontSize: 12,
        )),
        TextSpan(text: v, style: const TextStyle(
          fontWeight: FontWeight.w600, fontSize: 14,
        )),
      ])),
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
    return SizedBox(
      height: 56,
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          backgroundColor: _down ? cs.primary : cs.surfaceContainerHighest,
          foregroundColor: _down ? cs.onPrimary : cs.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        ),
        onPressed: () {},
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _start(),
          onPointerUp: (_) => _end(),
          onPointerCancel: (_) => _end(),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(widget.icon, size: 22),
              Text(widget.label, style: const TextStyle(fontSize: 11)),
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
      // map -1..1 → speed
      final yawSpeed = (dx * 120).clamp(-150.0, 150.0);
      final pitchSpeed = (-dy * 60).clamp(-80.0, 80.0);
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
                if (now.difference(_lastSent) >= _minSendGap) {
                  widget.client.zoomSet(nv);
                  _lastSent = now;
                }
              },
              onChangeEnd: (double nv) {
                // Always send terminal value so we never end on a stale tick.
                // `terminal:true` bypasses the bridge's mid-drag coalesce so
                // the final lens position always lands exactly where the
                // user released — even if the gap from the previous tick is
                // tiny.
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
