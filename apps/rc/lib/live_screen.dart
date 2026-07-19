import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'footer.dart';
import 'preview_widget.dart';
import 'ptz_tuning.dart';
import 'ptz_widgets.dart';
import 'sequences_hub.dart';
import 'settings_screen.dart';
import 'source_picker_sheet.dart';
import 'ws_client.dart';

/// v3 root: the pocket vision mixer.
///
/// One surface runs a service. Staging preview (the camera you are
/// lining up) fills the top; the on-air camera rides in a red PiP.
/// Below: the camera bus, then either the staged camera's presets or -
/// when you tap Frame - the manual controls in their place. A single
/// TAKE cuts the staged camera on air. Everything set-and-forget
/// (image, sequences, connection) lives behind the gear.
///
/// Replaces the v2 Simple/Advanced split + tabbed ControlScreen. Red is
/// on-air only; green is staged.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.client});

  final WsClient client;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  WsClient get client => widget.client;
  bool _framing = false;

  @override
  void initState() {
    super.initState();
    // A controller in an operator's hand must not dim or lock mid-service.
    // Best-effort: works natively on Android/iOS and via NoSleep on web.
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  // When on, a manual TAKE crossfades (dissolves) to the program instead of
  // cutting. _fadeMs is how long that dissolve takes (was hardcoded 500).
  bool _fadeTake = false;
  int _fadeMs = 500;
  static const List<(String, int)> _fadeChoices = <(String, int)>[
    ('0.3s', 300),
    ('0.5s', 500),
    ('1s', 1000),
    ('1.5s', 1500),
    ('2s', 2000),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final bridge = client.bridge;
        final staged = client.state;
        final onAirId = client.activeDeviceId;
        final stagedIsLive = staged.deviceId == onAirId && onAirId.isNotEmpty;
        final multi = bridge.devices.length > 1;
        // Session-less video source staged: preview + TAKE only. None of
        // the control affordances may render - there is no session to
        // drive, so they would all error on the bridge.
        final videoStaged = staged.isVideoSource;
        // The bus always shows once anything is connected: its trailing
        // "+" chip is how a second (generic) camera gets added, so it
        // must exist even while there is only one - or zero - cameras.
        final showBus = bridge.devices.isNotEmpty || client.socketOpen;
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: <Widget>[
                _TopStrip(client: client),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Column(
                      children: <Widget>[
                        _stage(ctx, multi, onAirId, videoStaged),
                        const SizedBox(height: 8),
                        if (showBus) ...<Widget>[
                          _CameraBus(client: client),
                          const SizedBox(height: 8),
                        ],
                        if (videoStaged)
                          const _VideoSourceNote()
                        else
                          _framing
                              ? _FramingPanel(client: client)
                              : _PresetGrid(client: client),
                      ],
                    ),
                  ),
                ),
                _actionBar(ctx, stagedIsLive, multi, videoStaged),
                const AppFooter(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Staging preview (large) with the on-air camera as a tap-to-swap PiP.
  Widget _stage(BuildContext ctx, bool multi, String onAirId, bool video) {
    final preview = PreviewWidget(
      client: client,
      showCrosshair: client.gridCrosshair,
      showCenterLines: client.gridCenterLines,
      showThirds: client.gridThirds,
      // A generic source has no gimbal, so a Pan/Tilt readout would show
      // fake zeros. The composition guides stay - they apply to any feed.
      showReadout: client.gridReadout && !video,
    );
    if (!multi || onAirId.isEmpty || onAirId == client.selectedDeviceId) {
      // Single camera, or the staged camera IS on air: no separate PiP.
      return preview;
    }
    return Stack(
      children: <Widget>[
        preview,
        Positioned(
          right: 8,
          top: 8,
          width: 116,
          child: _ProgramPip(client: client, onAirId: onAirId),
        ),
      ],
    );
  }

  Widget _actionBar(
    BuildContext ctx,
    bool stagedIsLive,
    bool multi,
    bool videoStaged,
  ) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        children: <Widget>[
          // Frame toggle: swaps the preset area for manual controls.
          // A video source has neither, so the toggle disappears.
          if (!videoStaged) ...<Widget>[
            OutlinedButton.icon(
              onPressed: () => setState(() => _framing = !_framing),
              icon: Icon(
                _framing ? Icons.grid_view : Icons.control_camera,
                size: 18,
              ),
              label: Text(_framing ? 'Presets' : 'Frame'),
            ),
            const SizedBox(width: 8),
          ],
          if (multi) ...<Widget>[
            // Cut vs crossfade for the manual TAKE. Semantics.toggled carries
            // the on/off state to screen readers (isSelected alone doesn't
            // expose it).
            Semantics(
              toggled: _fadeTake,
              child: IconButton(
                tooltip: _fadeTake ? 'TAKE crossfades' : 'TAKE cuts hard',
                isSelected: _fadeTake,
                onPressed: () => setState(() => _fadeTake = !_fadeTake),
                icon: Icon(
                  _fadeTake ? Icons.gradient : Icons.content_cut,
                  color: _fadeTake
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            // Crossfade duration, shown only when crossfade is on. Was hard
            // wired to 500ms; now the operator picks how slow the dissolve is.
            if (_fadeTake)
              PopupMenuButton<int>(
                tooltip: 'Crossfade length',
                initialValue: _fadeMs,
                onSelected: (v) => setState(() => _fadeMs = v),
                itemBuilder: (_) => <PopupMenuEntry<int>>[
                  for (final c in _fadeChoices)
                    PopupMenuItem<int>(value: c.$2, child: Text(c.$1)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    _fadeChoices
                        .firstWhere(
                          (c) => c.$2 == _fadeMs,
                          orElse: () => ('${_fadeMs}ms', _fadeMs),
                        )
                        .$1,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Expanded(
              child: FilledButton(
                // The only red button in the app. Disabled (staged is
                // already on air) reads as inert; otherwise it commits
                // the cut with the chosen transition.
                onPressed: stagedIsLive
                    ? null
                    : () {
                        HapticFeedback.mediumImpact();
                        client.makeLive(
                          client.selectedDeviceId,
                          fadeMs: _fadeTake ? _fadeMs : 0,
                        );
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF3B30),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      theme.colorScheme.surfaceContainerHighest,
                  minimumSize: const Size.fromHeight(46),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    fontSize: 15,
                  ),
                ),
                child: Text(stagedIsLive ? 'ON AIR' : 'TAKE'),
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }
}

/// Connection state + staged camera name + gear. The whole nav for the
/// app is this one gear; everything rare lives behind it.
class _TopStrip extends StatelessWidget {
  const _TopStrip({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staged = client.state;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
      child: Row(
        children: <Widget>[
          _StatusDot(runStatus: staged.runStatus, connected: staged.connected),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              staged.displayName.isEmpty ? 'OBSBOT Remote' : staged.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Sequences',
            icon: Icon(
              (client.state.sequence.running || client.mix.running)
                  ? Icons.multiline_chart
                  : Icons.timeline,
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SequencesHub(client: client),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(client: client),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The on-air camera in a red-framed PiP; tap to stage it (swaps which
/// camera the large preview + controls follow).
class _ProgramPip extends StatelessWidget {
  const _ProgramPip({required this.client, required this.onAirId});
  final WsClient client;
  final String onAirId;

  @override
  Widget build(BuildContext context) {
    final onAir = client.bridge.deviceById(onAirId);
    return GestureDetector(
      onTap: () => client.selectDevice(onAirId),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFFF3B30), width: 2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                PreviewWidget(client: client, deviceId: onAirId, minimal: true),
                Positioned(
                  left: 3,
                  top: 3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    color: const Color(0xFFFF3B30),
                    child: const Text(
                      'ON AIR',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
                if (onAir != null)
                  Positioned(
                    left: 3,
                    bottom: 2,
                    child: Text(
                      onAir.displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        shadows: <Shadow>[Shadow(blurRadius: 3)],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Camera bus: one chip per camera. Tap stages it. Outline = staged;
/// red dot = on air; the status dot carries run/sleep/gone. The trailing
/// "+" chip opens the add-camera picker; a generic source's chip
/// long-presses to remove.
class _CameraBus extends StatelessWidget {
  const _CameraBus({required this.client});
  final WsClient client;

  Future<void> _confirmRemove(BuildContext context, DeviceState d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Remove camera'),
        content: Text(
          'Remove "${d.displayName}" from the bridge? '
          'The camera itself is not affected.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok ?? false) await client.removeSource(d.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedId = client.selectedDeviceId;
    final onAirId = client.activeDeviceId;
    final devices = client.bridge.devices;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: devices.length + 1, // trailing add chip
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (BuildContext c, int i) {
          if (i == devices.length) return _AddCameraChip(client: client);
          final d = devices[i];
          final staged = d.deviceId == selectedId;
          final onAir = d.deviceId == onAirId;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => client.selectDevice(d.deviceId),
            // Only generic sources are removable from the phone; OBSBOT
            // cameras attach and detach with their USB cable.
            onLongPress: d.isVideoSource ? () => _confirmRemove(c, d) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: staged
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  width: staged ? 2 : 1,
                ),
                color: theme.colorScheme.surfaceContainer,
              ),
              child: Row(
                children: <Widget>[
                  _StatusDot(runStatus: d.runStatus, connected: d.connected),
                  const SizedBox(width: 8),
                  // Source labels can be long ("Camo Studio Virtual
                  // Camera"); cap the chip so the bus stays scannable.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 132),
                    child: Text(
                      d.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: staged ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (onAir) ...<Widget>[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'ON AIR',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Trailing "+" chip on the camera bus: opens the add-camera picker
/// listing everything AVFoundation on the bridge Mac can see.
class _AddCameraChip extends StatelessWidget {
  const _AddCameraChip({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Add camera',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => SourcePickerSheet.show(context, client),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            color: theme.colorScheme.surfaceContainer,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.add,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'Add',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a staged video source shows in place of presets and framing
/// controls: nothing to drive, so say so once and stay out of the way.
class _VideoSourceNote extends StatelessWidget {
  const _VideoSourceNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.videocam_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Video source - preview and TAKE only. '
              'No pan, zoom, or presets.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Six preset tiles for the staged camera. Tap = recall (positions the
/// off-air camera, invisibly). Long-press = save/rename.
class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final s = client.state;
    final byId = <int, PresetEntry>{for (final p in s.presets) p.id: p};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // How fast a preset recall glides. This is the control the v3 redesign
        // dropped - recall was stuck at the fixed default with no way to change
        // the speed. Bound to the same moveDuration the recall actually uses.
        _PresetGlideRow(client: client),
        const SizedBox(height: 8),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 2.1,
          children: <Widget>[
            for (int i = 0; i < 6; i++)
              _PresetTile(
                client: client,
                id: i,
                entry: byId[i],
                active: s.activePresetId == i,
              ),
          ],
        ),
      ],
    );
  }
}

/// The preset glide-speed selector: how long a tapped preset takes to move the
/// camera into position. Instant snaps; the rest run the bridge MotionPlanner.
class _PresetGlideRow extends StatelessWidget {
  const _PresetGlideRow({required this.client});
  final WsClient client;

  static const List<(String, int)> _choices = <(String, int)>[
    ('Instant', 0),
    ('1s', 1000),
    ('2s', 2000),
    ('5s', 5000),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = client.moveDuration.inMilliseconds;
    return Row(
      children: <Widget>[
        Icon(Icons.speed, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text('Glide', style: theme.textTheme.labelMedium),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: <Widget>[
              for (final c in _choices)
                ChoiceChip(
                  label: Text(c.$1),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  selected: cur == c.$2,
                  onSelected: (_) =>
                      client.setMoveDuration(Duration(milliseconds: c.$2)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.client,
    required this.id,
    required this.entry,
    required this.active,
  });
  final WsClient client;
  final int id;
  final PresetEntry? entry;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final has = entry != null;
    final label = has && entry!.name.isNotEmpty ? entry!.name : 'P${id + 1}';
    // Expose a button role + state to screen readers; the bare GestureDetector
    // has neither (WCAG 4.1.2). selected marks the on-air preset.
    return Semantics(
      button: true,
      selected: active,
      label: has ? '$label preset' : 'Preset ${id + 1}, empty',
      hint: has ? 'Recall. Long press to rename.' : 'Long press to save.',
      child: GestureDetector(
        onTap: has
            ? () {
                HapticFeedback.lightImpact();
                client.presetRecall(id);
              }
            : null,
        onLongPress: () async {
          HapticFeedback.heavyImpact();
          final name = await _prompt(context, entry?.name ?? 'P${id + 1}');
          if (name == null) return;
          client.presetSave(id, name);
        },
        child: Container(
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary
                : (has
                      ? theme.colorScheme.surfaceContainerHigh
                      : theme.colorScheme.surfaceContainerLowest),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Stack(
            children: <Widget>[
              Center(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: has ? 18 : 15,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? theme.colorScheme.onPrimary
                        : (has
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.outline),
                  ),
                ),
              ),
              // Discoverability: tap-to-recall / hold-to-save is invisible
              // otherwise. The v2 tiles carried this hint; the studio
              // dropped it and the operator could not find how to save.
              Positioned(
                left: 0,
                bottom: 0,
                child: Text(
                  has ? 'P${id + 1}  ·  hold to rename' : 'hold to save here',
                  style: TextStyle(
                    fontSize: 10,
                    color:
                        (active
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.outline)
                            .withValues(alpha: 0.75),
                  ),
                ),
              ),
              if (active)
                const Positioned(
                  right: 0,
                  top: 0,
                  child: Icon(
                    Icons.check_circle,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _prompt(BuildContext ctx, String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: ctx,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Save preset'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'e.g. Ardas, Palki, Sangat',
          ),
          onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
            child: const Text('Save current pose'),
          ),
        ],
      ),
    );
  }
}

/// Manual controls in the preset area's place (Frame toggle). Pad or
/// joystick by preference, zoom, speed, recenter - all driving the
/// staged camera.
class _FramingPanel extends StatelessWidget {
  const _FramingPanel({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final joystick = client.driveControlStyle == 'joystick';
    return Column(
      children: <Widget>[
        SizedBox(
          height: 190,
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: joystick
                    ? PtzPad(client: client)
                    : _EightWayPad(client: client),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: ZoomSlider(client: client, state: client.state),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(child: _SpeedSegmented(client: client)),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: client.ptzRecenter,
              icon: const Icon(Icons.filter_center_focus, size: 18),
              label: const Text('Center'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () =>
                client.setDriveControlStyle(joystick ? 'buttons' : 'joystick'),
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: Text(joystick ? 'Use buttons' : 'Use joystick'),
          ),
        ),
      ],
    );
  }
}

/// 3x3 hold pad built from HoldDirBtn (signs only; magnitude from the
/// speed preset + ramp - v3 P1).
class _EightWayPad extends StatelessWidget {
  const _EightWayPad({required this.client});
  final WsClient client;

  Widget _dir(IconData icon, String label, double y, double p) => HoldDirBtn(
    icon: icon,
    label: label,
    client: client,
    yawSpeed: y,
    pitchSpeed: p,
  );

  Widget _row(List<Widget> kids) => Expanded(
    child: Row(
      children: <Widget>[
        for (int i = 0; i < kids.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: kids[i]),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        _row(<Widget>[
          _dir(Icons.north_west, 'Up-Left', -1, 1),
          _dir(Icons.north, 'Up', 0, 1),
          _dir(Icons.north_east, 'Up-Right', 1, 1),
        ]),
        const SizedBox(height: 6),
        _row(<Widget>[
          _dir(Icons.west, 'Left', -1, 0),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(child: Icon(Icons.gamepad, size: 18)),
          ),
          _dir(Icons.east, 'Right', 1, 0),
        ]),
        const SizedBox(height: 6),
        _row(<Widget>[
          _dir(Icons.south_west, 'Down-Left', -1, -1),
          _dir(Icons.south, 'Down', 0, -1),
          _dir(Icons.south_east, 'Down-Right', 1, -1),
        ]),
      ],
    );
  }
}

/// Fine / Normal / Fast manual-PTZ speed. Public-ish twin of the one in
/// tab_shell; the studio keeps its own so the tab file can be retired.
class _SpeedSegmented extends StatelessWidget {
  const _SpeedSegmented({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<PtzSpeed>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        textStyle: const TextStyle(fontSize: 12),
        backgroundColor: cs.surfaceContainer,
        foregroundColor: cs.onSurface,
        selectedBackgroundColor: cs.primary,
        selectedForegroundColor: cs.onPrimary,
        side: BorderSide(color: cs.outlineVariant),
      ),
      segments: const <ButtonSegment<PtzSpeed>>[
        ButtonSegment<PtzSpeed>(value: PtzSpeed.fine, label: Text('Fine')),
        ButtonSegment<PtzSpeed>(value: PtzSpeed.normal, label: Text('Normal')),
        ButtonSegment<PtzSpeed>(value: PtzSpeed.fast, label: Text('Fast')),
      ],
      selected: <PtzSpeed>{client.ptzSpeed},
      onSelectionChanged: (Set<PtzSpeed> sel) {
        if (sel.isNotEmpty) client.setPtzSpeed(sel.first);
      },
    );
  }
}

/// Green run / amber sleep / red privacy / grey gone. Shared visual
/// language across bus, top strip, and the Mac deck.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.runStatus, required this.connected});
  final String runStatus;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = !connected
        ? const Color(0xFF8E8E93)
        : switch (runStatus) {
            'run' => const Color(0xFF34C759),
            'sleep' => const Color(0xFFFFB300),
            'privacy' => const Color(0xFFFF3B30),
            _ => const Color(0xFF8E8E93),
          };
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
