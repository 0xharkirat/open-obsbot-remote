import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cache_menu.dart';
import 'preview_widget.dart';
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
            child: LayoutBuilder(
              builder: (BuildContext ctx, BoxConstraints c) {
                final landscape = c.maxWidth > c.maxHeight;
                return landscape
                    ? _buildLandscape(s)
                    : _buildPortrait(s);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _speedMenu(BuildContext ctx) {
    final cur = widget.client.moveSpeed;
    IconData iconFor(MoveSpeed s) => switch (s) {
          MoveSpeed.instant => Icons.flash_on,
          MoveSpeed.ultra => Icons.hourglass_empty,
          MoveSpeed.cinema => Icons.movie_creation_outlined,
          MoveSpeed.slow => Icons.directions_walk,
          MoveSpeed.medium => Icons.directions_run,
          MoveSpeed.fast => Icons.bolt,
        };
    return PopupMenuButton<MoveSpeed>(
      tooltip: 'Move speed',
      icon: Icon(iconFor(cur)),
      onSelected: (s) => widget.client.setMoveSpeed(s),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<MoveSpeed>>[
        for (final s in MoveSpeed.values)
          CheckedPopupMenuItem<MoveSpeed>(
            value: s,
            checked: s == cur,
            child: Row(children: <Widget>[
              Icon(iconFor(s), size: 16),
              const SizedBox(width: 8),
              Text(moveSpeedLabel(s)),
            ]),
          ),
      ],
    );
  }

  Widget _buildPortrait(CameraState s) {
    // Mobile-portrait layout. Hero controls (preview + joystick + zoom
    // slider) are PINNED above a scrollable region; only the action
    // rows scroll. This is the only layout that works on touch devices
    // — wrapping the whole page in SingleChildScrollView lets the
    // scroll view's GestureRecognizer win the gesture arena over the
    // joystick's GestureDetector, so vertical-first joystick drags get
    // eaten as scrolls and the camera doesn't move. See
    // docs/TOUCH_FINDINGS_2026-05-10.md for the reproduction.
    return Column(
      children: <Widget>[
        _statusBar(s),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: PreviewWidget(client: widget.client),
        ),
        // Joystick + zoom slider — fixed slice, NOT inside the scroll view.
        SizedBox(
          height: 280,
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: PtzPad(client: widget.client),
                ),
              ),
              SizedBox(
                width: 80,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ZoomSlider(client: widget.client, state: s),
                ),
              ),
            ],
          ),
        ),
        // Bottom action rows scroll on small phones where they don't fit.
        Expanded(
          child: SingleChildScrollView(
            child: _bottomBar(s),
          ),
        ),
      ],
    );
  }

  Widget _buildLandscape(CameraState s) {
    return Column(
      children: <Widget>[
        _statusBar(s),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: <Widget>[
                      PreviewWidget(client: widget.client),
                      const SizedBox(height: 8),
                      Expanded(child: PtzPad(client: widget.client)),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ZoomSlider(client: widget.client, state: s),
                ),
              ),
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _bottomControls(s),
                    ),
                  ),
                ),
              ),
            ],
          ),
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

  Widget _bottomBar(CameraState s) {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _bottomControls(s),
      ),
    );
  }

  List<Widget> _bottomControls(CameraState s) {
    return <Widget>[
      Row(children: <Widget>[
        Expanded(child: _bigBtn('Recenter', Icons.center_focus_strong,
            () => widget.client.ptzRecenter())),
        const SizedBox(width: 8),
        Expanded(child: _bigBtn('Sleep', Icons.bedtime,
            () => widget.client.runStatus('sleep'))),
        const SizedBox(width: 8),
        Expanded(child: _bigBtn('Wake', Icons.wb_sunny,
            () => widget.client.runStatus('run'))),
      ]),
      const SizedBox(height: 8),
      Row(children: <Widget>[
        Expanded(child: _toggleBtn('AI HUMAN', s.aiMode == 'human',
            () => widget.client.aiSetMode(
                s.aiMode == 'human' ? 'none' : 'human', 'normal'))),
        const SizedBox(width: 8),
        Expanded(child: _toggleBtn('HDR', s.hdr,
            () => widget.client.hdr(!s.hdr))),
        const SizedBox(width: 8),
        Expanded(child: _toggleBtn('FOV ${s.fov}°', false, () {
          final next = s.fov == 86 ? 78 : (s.fov == 78 ? 65 : 86);
          widget.client.fov(next);
        })),
      ]),
      const SizedBox(height: 8),
      Row(children: <Widget>[
        Expanded(child: _HoldDirBtn(
          icon: Icons.keyboard_arrow_left,
          label: 'Left',
          client: widget.client,
          yawSpeed: -80,
          pitchSpeed: 0,
        )),
        const SizedBox(width: 8),
        Expanded(child: _HoldDirBtn(
          icon: Icons.keyboard_arrow_up,
          label: 'Up',
          client: widget.client,
          yawSpeed: 0,
          pitchSpeed: 40,
        )),
        const SizedBox(width: 8),
        Expanded(child: _HoldDirBtn(
          icon: Icons.keyboard_arrow_down,
          label: 'Down',
          client: widget.client,
          yawSpeed: 0,
          pitchSpeed: -40,
        )),
        const SizedBox(width: 8),
        Expanded(child: _HoldDirBtn(
          icon: Icons.keyboard_arrow_right,
          label: 'Right',
          client: widget.client,
          yawSpeed: 80,
          pitchSpeed: 0,
        )),
      ]),
      const SizedBox(height: 8),
      Row(children: <Widget>[
        Expanded(child: _presetBtn(0, 'P1', s)),
        const SizedBox(width: 8),
        Expanded(child: _presetBtn(1, 'P2', s)),
        const SizedBox(width: 8),
        Expanded(child: _presetBtn(2, 'P3', s)),
        const SizedBox(width: 8),
        Expanded(child: _presetBtn(3, 'P4', s)),
      ]),
    ];
  }

  Widget _bigBtn(String label, IconData icon, VoidCallback onTap) {
    return SizedBox(
      height: 56,
      child: FilledButton.tonalIcon(
        onPressed: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        icon: Icon(icon),
        label: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _toggleBtn(String label, bool on, VoidCallback onTap) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: on
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          foregroundColor: on
              ? Theme.of(context).colorScheme.onPrimary
              : Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Text(label, textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _presetBtn(int id, String label, CameraState s) {
    return SizedBox(
      height: 64,
      child: GestureDetector(
        onLongPress: () {
          HapticFeedback.heavyImpact();
          widget.client.presetSave(id, label);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved $label at current position'),
                duration: const Duration(milliseconds: 800)),
          );
        },
        child: FilledButton.tonal(
          onPressed: () {
            HapticFeedback.lightImpact();
            widget.client.presetRecall(id);
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(label, style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700)),
              const Text('hold to save', style: TextStyle(fontSize: 9)),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _HoldDirBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final WsClient client;
  final double yawSpeed;
  final double pitchSpeed;
  const _HoldDirBtn({
    required this.icon,
    required this.label,
    required this.client,
    required this.yawSpeed,
    required this.pitchSpeed,
  });

  @override
  State<_HoldDirBtn> createState() => _HoldDirBtnState();
}

class _HoldDirBtnState extends State<_HoldDirBtn> {
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
