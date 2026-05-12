import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'control_screen.dart';
import 'move_duration_icons.dart';
import 'preview_widget.dart';
import 'ws_client.dart';

/// v1.2 redesign — 3-tab shell below a pinned live preview.
///
/// Post-review pass (`fix/ui-revamp-from-review`):
///   - Drops the Presets and Sequence tabs. Presets are inlined into the
///     Joystick + Buttons tabs (P1..P6 row) so the user can recall or
///     save while controlling. Sequence moves to an AppBar action with
///     the timeline (graph) icon, opening the SequencerScreen route.
///   - Every tab uses the same template: top quick-action row +
///     primary control + zoom slider + inline preset row + utility row.
///   - Buttons tab gets the same vertical zoom slider as Joystick.
///   - Each control widget reads grid-overlay state from `client.state`
///     so the preview's grid is consistent across tabs.
///
/// Layout choices are driven by `LayoutBuilder.maxWidth`, not device
/// class (see the `flutter-build-responsive-layout` skill):
///
///   • <600  px wide  → preview pinned on top (16:9), tabs below.
///   • ≥600  px wide  → preview pinned on the left (50%), tabs on the right.
class TabShell extends StatefulWidget {
  final WsClient client;
  const TabShell({super.key, required this.client});

  @override
  State<TabShell> createState() => _TabShellState();
}

class _TabShellState extends State<TabShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  static const _tabs = <Tab>[
    Tab(icon: Icon(Icons.gamepad), text: 'Joystick'),
    Tab(icon: Icon(Icons.touch_app), text: 'Buttons'),
    Tab(icon: Icon(Icons.image), text: 'Image'),
  ];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark.touch,
      child: LayoutBuilder(
        builder: (BuildContext ctx, BoxConstraints c) {
          final wide = c.maxWidth >= 600;
          return wide ? _wide(c) : _narrow();
        },
      ),
    );
  }

  Widget _narrow() {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: PreviewWidget(
            client: widget.client,
            showCrosshair: widget.client.gridCrosshair,
            showCenterLines: widget.client.gridCenterLines,
            showThirds: widget.client.gridThirds,
            showReadout: widget.client.gridReadout,
          ),
        ),
        _tabBar(),
        Expanded(child: _tabViews()),
      ],
    );
  }

  Widget _wide(BoxConstraints c) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: c.maxWidth * 0.5,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.topCenter,
              child: PreviewWidget(
                client: widget.client,
                showCrosshair: widget.client.gridCrosshair,
                showCenterLines: widget.client.gridCenterLines,
                showThirds: widget.client.gridThirds,
                showReadout: widget.client.gridReadout,
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: <Widget>[
              _tabBar(),
              Expanded(child: _tabViews()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tabBar() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: TabBar(
        controller: _tab,
        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
        tabs: _tabs,
      ),
    );
  }

  Widget _tabViews() {
    return TabBarView(
      controller: _tab,
      children: <Widget>[
        _JoystickTab(client: widget.client),
        _ButtonsTab(client: widget.client),
        _ImageTab(client: widget.client),
      ],
    );
  }
}

// ===========================================================================
// Shared building blocks
// ===========================================================================

/// Top "global" action row used at the top of the Joystick + Buttons tabs.
/// Recenter / Sleep / Wake placed in the same position so the user's
/// muscle memory carries between tabs.
///
/// PR Q (`feat/forui-tab-content`) migrated the three buttons from
/// Material `OutlinedButton` to forui `FButton.raw` with
/// `variant: FButtonVariant.outline`. The classic 3-per-row overflow
/// bug (`OutlinedButton.icon`'s intrinsic icon+label width pushing past
/// the slot on 360 px phones) is structurally avoided here: each
/// button's child is a Flexible+Text with `maxLines: 1` +
/// `TextOverflow.ellipsis`, so even at extreme narrow widths the row
/// stays on a single line. Tooltips carry the icon semantics that the
/// icon-less buttons lose.
class _QuickActions extends StatelessWidget {
  final WsClient client;
  const _QuickActions({required this.client});

  Widget _btn(String label, String tooltip, VoidCallback onPress) {
    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: FButton.raw(
          onPress: onPress,
          variant: FButtonVariant.outline,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _btn('Recenter', 'Recenter the gimbal to home position',
            () => client.ptzRecenter()),
        const SizedBox(width: 8),
        _btn('Sleep', 'Put the camera to sleep',
            () => client.runStatus('sleep')),
        const SizedBox(width: 8),
        _btn('Wake', 'Wake the camera up',
            () => client.runStatus('run')),
      ],
    );
  }
}

/// Inline P1..P6 row used at the bottom of the Joystick + Buttons tabs.
/// Tap = recall with current move-duration. Long-press = save current
/// position (with confirmation snackbar). Brings the preset action close
/// to where the user is already touching to control the gimbal, so they
/// don't have to switch tabs.
class _InlinePresetRow extends StatelessWidget {
  final WsClient client;
  const _InlinePresetRow({required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final presets = client.state.presets;
        return Row(
          children: <Widget>[
            for (int i = 0; i < 6; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _InlinePresetCard(
                  client: client,
                  id: i,
                  entry: _lookupPreset(presets, i),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

PresetEntry? _lookupPreset(List<PresetEntry> presets, int id) {
  for (final p in presets) {
    if (p.id == id) return p;
  }
  return null;
}

class _InlinePresetCard extends StatelessWidget {
  final WsClient client;
  final int id;
  final PresetEntry? entry;
  const _InlinePresetCard({
    required this.client,
    required this.id,
    required this.entry,
  });

  bool get _saved => entry != null && entry!.name.isNotEmpty;
  String get _label => 'P${id + 1}';

  void _save(BuildContext ctx) {
    HapticFeedback.heavyImpact();
    client.presetSave(id, _saved ? entry!.name : _label);
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('Saved $_label at current position'),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPress: () => _save(context),
      child: SizedBox(
        height: 60,
        child: Material(
          color: _saved ? cs.primaryContainer : cs.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: cs.outlineVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _saved
                ? () {
                    HapticFeedback.lightImpact();
                    client.presetRecall(id);
                  }
                : () => _save(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    _label,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      color: _saved ? cs.onPrimaryContainer : cs.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _saved ? 'tap • hold' : 'hold to save',
                    style: TextStyle(
                      fontSize: 9,
                      height: 1.0,
                      color: _saved
                          ? cs.onPrimaryContainer.withValues(alpha: 0.7)
                          : cs.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared bottom-of-tab control bundle.
///
/// In v1.2 this carried both a live-velocity slider AND the move-duration
/// chips. User review pointed out the redundancy — slider scaled live
/// joystick / button velocity (0.1×–1×) while the chips controlled
/// preset-recall timing, but the conceptual overlap was confusing and
/// having two near-identical "speed" controls on the same row hurt more
/// than it helped.
///
/// Now we keep only the chips. The joystick already gives analog speed
/// control via deflection magnitude, and the 8-way buttons issue full
/// velocity. Chip-controlled `client.moveDuration` drives:
///   - P1..P6 preset recall (tap a preset card).
///   - Any future ptz.angle command that doesn't pass an explicit
///     duration.
///
/// Same widget on Joystick + Buttons tabs so the two surfaces are
/// visually identical below the gimbal control.
class _BottomControls extends StatelessWidget {
  final WsClient client;
  const _BottomControls({required this.client});

  @override
  Widget build(BuildContext context) {
    return _DurationChips(client: client);
  }
}

class _DurationChips extends StatelessWidget {
  final WsClient client;
  const _DurationChips({required this.client});

  @override
  Widget build(BuildContext context) {
    final cur = client.moveDuration;
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < kMoveDurationPresets.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 6),
            ChoiceChip(
              label: Text(kMoveDurationPresets[i].label),
              avatar: Icon(
                iconForMoveDuration(kMoveDurationPresets[i].duration),
                size: 16,
                color: kMoveDurationPresets[i].duration == cur
                    ? cs.onPrimary
                    : cs.onSurface,
              ),
              selected: kMoveDurationPresets[i].duration == cur,
              onSelected: (_) =>
                  client.setMoveDuration(kMoveDurationPresets[i].duration),
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// Tab 1 — Joystick
// ===========================================================================

class _JoystickTab extends StatelessWidget {
  final WsClient client;
  const _JoystickTab({required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              _QuickActions(client: client),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      flex: 4,
                      child: PtzPad(client: client),
                    ),
                    SizedBox(
                      width: 80,
                      child: ZoomSlider(client: client, state: s),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _InlinePresetRow(client: client),
              const SizedBox(height: 8),
              _BottomControls(client: client),
            ],
          ),
        );
      },
    );
  }
}

// ===========================================================================
// Tab 2 — Buttons (8-way hold pad + zoom + inline presets + shared
//                  bottom-controls bundle)
// ===========================================================================

class _ButtonsTab extends StatelessWidget {
  final WsClient client;
  const _ButtonsTab({required this.client});

  // Hold-button velocities in deg/s. The v1.2 user-facing speed slider
  // was dropped per live-test feedback; users now control pace via the
  // duration chips (preset recall + ptz.angle) and analog joystick
  // deflection. Hold-buttons run at full velocity.
  static const double _yaw = 80;
  static const double _pit = 40;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        const yaw = _yaw;
        const pit = _pit;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              _QuickActions(client: client),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      flex: 4,
                      child: Column(
                        children: <Widget>[
                          Expanded(
                              child: _padRow(<Widget>[
                            _dir(Icons.north_west, 'Up-Left', -yaw, pit),
                            _dir(Icons.north, 'Up', 0, pit),
                            _dir(Icons.north_east, 'Up-Right', yaw, pit),
                          ])),
                          const SizedBox(height: 6),
                          Expanded(
                              child: _padRow(<Widget>[
                            _dir(Icons.west, 'Left', -yaw, 0),
                            _center(),
                            _dir(Icons.east, 'Right', yaw, 0),
                          ])),
                          const SizedBox(height: 6),
                          Expanded(
                              child: _padRow(<Widget>[
                            _dir(Icons.south_west, 'Down-Left', -yaw, -pit),
                            _dir(Icons.south, 'Down', 0, -pit),
                            _dir(Icons.south_east, 'Down-Right', yaw, -pit),
                          ])),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: ZoomSlider(client: client, state: s),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _InlinePresetRow(client: client),
              const SizedBox(height: 8),
              _BottomControls(client: client),
            ],
          ),
        );
      },
    );
  }

  Widget _padRow(List<Widget> children) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: children[i]),
        ],
      ],
    );
  }

  Widget _dir(IconData icon, String label, double yawSpeed, double pitchSpeed) {
    return HoldDirBtn(
      icon: icon,
      label: label,
      client: client,
      yawSpeed: yawSpeed,
      pitchSpeed: pitchSpeed,
    );
  }

  Widget _center() {
    // Empty cell — center is the Recenter button up in the quick-action
    // row.
    return const SizedBox.shrink();
  }
}

// ===========================================================================
// Tab 3 — Image (HDR / FOV / face / flip / color + Exposure / Anti-flicker
// / WB, each with a reset-to-default button per section)
// ===========================================================================

class _ImageTab extends StatelessWidget {
  final WsClient client;
  const _ImageTab({required this.client});

  // Per-setting defaults that the Reset buttons restore to.
  static const int _defaultColor = 50;
  static const int _defaultFov = 86;
  static const String _defaultExposureMode = 'auto';
  static const double _defaultEvBias = 0.0;
  static const String _defaultAntiFlicker = 'off';
  static const int _defaultWbKelvin = 4700;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        final theme = Theme.of(ctx);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Refresh-from-camera row. If another app (OBSBOT Center,
              // a different phone connected first) changed exposure /
              // anti-flicker / WB out-of-band, our snapshot is stale.
              // Tapping refresh re-reads live state from the camera.
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                  ),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Refresh from camera'),
                  onPressed: () {
                    client.imageRefresh();
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Re-read live state from camera'),
                        duration: Duration(milliseconds: 900),
                      ),
                    );
                  },
                ),
              ),
              _section(theme, 'Auto-track'),
              _aiSegmented(ctx, s),
              const SizedBox(height: 16),
              _sectionWithReset(theme, 'View',
                  onReset: () => client.fov(_defaultFov)),
              _fovSegmented(ctx, s),
              const SizedBox(height: 16),
              _section(theme, 'Tone'),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _toggleBtn(ctx, 'HDR', s.hdr,
                        () => client.hdr(!s.hdr)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _toggleBtn(ctx, 'Face exposure', s.faceAe,
                        () => client.faceAe(!s.faceAe)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _toggleBtn(ctx, 'Face focus', s.faceFocus,
                        () => client.faceFocus(!s.faceFocus)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _toggleBtn(ctx, 'Flip', s.flipH,
                        () => client.flipH(!s.flipH)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionWithReset(
                theme,
                'Exposure',
                onReset: () {
                  client.setExposureMode(_defaultExposureMode);
                  client.setEvBias(_defaultEvBias);
                },
              ),
              _exposureSegmented(ctx, s),
              if (s.exposureMode == 'auto') _evBiasSlider(ctx, s),
              const SizedBox(height: 12),
              _sectionWithReset(theme, 'Anti-flicker',
                  onReset: () =>
                      client.setAntiFlicker(_defaultAntiFlicker)),
              _flickerSegmented(ctx, s),
              const SizedBox(height: 16),
              _sectionWithReset(
                theme,
                'White balance',
                onReset: () {
                  client.setWbAuto(true);
                  client.setWbTemp(_defaultWbKelvin);
                },
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _toggleBtn(ctx, 'Auto WB', s.wbAuto,
                        () => client.setWbAuto(!s.wbAuto)),
                  ),
                ],
              ),
              if (!s.wbAuto) _wbTempSlider(ctx, s),
              const SizedBox(height: 16),
              _sectionWithReset(
                theme,
                'Color',
                onReset: () => client.colorSet(
                  brightness: _defaultColor,
                  contrast: _defaultColor,
                  saturation: _defaultColor,
                  sharpness: _defaultColor,
                ),
              ),
              _colorSlider(ctx, 'Brightness', s.brightness,
                  (v) => client.colorSet(brightness: v),
                  resetTo: _defaultColor,
                  onReset: () => client.colorSet(brightness: _defaultColor)),
              _colorSlider(ctx, 'Contrast', s.contrast,
                  (v) => client.colorSet(contrast: v),
                  resetTo: _defaultColor,
                  onReset: () => client.colorSet(contrast: _defaultColor)),
              _colorSlider(ctx, 'Saturation', s.saturation,
                  (v) => client.colorSet(saturation: v),
                  resetTo: _defaultColor,
                  onReset: () => client.colorSet(saturation: _defaultColor)),
              _colorSlider(ctx, 'Sharpness', s.sharpness,
                  (v) => client.colorSet(sharpness: v),
                  resetTo: _defaultColor,
                  onReset: () => client.colorSet(sharpness: _defaultColor)),
            ],
          ),
        );
      },
    );
  }

  Widget _section(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.0,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _sectionWithReset(ThemeData theme, String label,
      {required VoidCallback onReset}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 1.0,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              foregroundColor: theme.colorScheme.outline,
            ),
            icon: const Icon(Icons.restart_alt, size: 14),
            label: const Text('Reset', style: TextStyle(fontSize: 11)),
            onPressed: onReset,
          ),
        ],
      ),
    );
  }

  Widget _aiSegmented(BuildContext ctx, CameraState s) {
    return SegmentedButton<String>(
      segments: const <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'none', label: Text('Off')),
        ButtonSegment<String>(
            value: 'human', label: Text('Person'), icon: Icon(Icons.person)),
        ButtonSegment<String>(
            value: 'group', label: Text('Group'), icon: Icon(Icons.groups)),
      ],
      selected: <String>{s.aiMode},
      onSelectionChanged: (Set<String> sel) {
        final next = sel.first;
        client.aiSetMode(next, 'normal');
      },
    );
  }

  Widget _fovSegmented(BuildContext ctx, CameraState s) {
    return SegmentedButton<int>(
      segments: const <ButtonSegment<int>>[
        ButtonSegment<int>(value: 86, label: Text('Wide')),
        ButtonSegment<int>(value: 78, label: Text('Normal')),
        ButtonSegment<int>(value: 65, label: Text('Narrow')),
      ],
      selected: <int>{s.fov},
      onSelectionChanged: (Set<int> sel) => client.fov(sel.first),
    );
  }

  Widget _exposureSegmented(BuildContext ctx, CameraState s) {
    return SegmentedButton<String>(
      segments: const <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'auto', label: Text('Auto')),
        ButtonSegment<String>(value: 'manual', label: Text('Manual')),
      ],
      selected: <String>{s.exposureMode},
      onSelectionChanged: (Set<String> sel) =>
          client.setExposureMode(sel.first),
    );
  }

  Widget _evBiasSlider(BuildContext ctx, CameraState s) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text('EV bias', style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: -2.0,
              max: 2.0,
              divisions: 24,
              value: s.evBias.clamp(-2.0, 2.0),
              label: '${s.evBias >= 0 ? '+' : ''}${s.evBias.toStringAsFixed(1)} EV',
              onChanged: (double v) => client.setEvBias(v),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${s.evBias >= 0 ? '+' : ''}${s.evBias.toStringAsFixed(1)}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _flickerSegmented(BuildContext ctx, CameraState s) {
    return SegmentedButton<String>(
      segments: const <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'off', label: Text('Off')),
        ButtonSegment<String>(value: '50', label: Text('50 Hz')),
        ButtonSegment<String>(value: '60', label: Text('60 Hz')),
      ],
      selected: <String>{s.antiFlicker},
      onSelectionChanged: (Set<String> sel) =>
          client.setAntiFlicker(sel.first),
    );
  }

  Widget _wbTempSlider(BuildContext ctx, CameraState s) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text('Temperature', style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: 2800,
              max: 6500,
              divisions: 37,
              value: s.wbKelvin.toDouble().clamp(2800.0, 6500.0),
              label: '${s.wbKelvin}K',
              onChanged: (double v) => client.setWbTemp(v.round()),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${s.wbKelvin}K',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorSlider(BuildContext ctx, String label, int value,
      void Function(int) onChanged,
      {required int resetTo, required VoidCallback onReset}) {
    final theme = Theme.of(ctx);
    final isDefault = value == resetTo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: 0,
              max: 100,
              divisions: 100,
              value: value.toDouble().clamp(0, 100),
              onChanged: (double v) => onChanged(v.round()),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            iconSize: 14,
            tooltip: 'Reset to $resetTo',
            color: isDefault ? theme.colorScheme.outline : theme.colorScheme.primary,
            icon: const Icon(Icons.restart_alt),
            onPressed: isDefault ? null : onReset,
          ),
        ],
      ),
    );
  }

  /// 2-per-row image-toggle button (HDR / Face / Flip / Auto WB).
  ///
  /// PR Q migrated this from `FilledButton` (Material) to `FButton.raw`
  /// (forui) so the on/off state uses forui's variant system instead of
  /// hand-rolled `colorScheme` overrides. `selected` switches the
  /// variant to `.primary` (brand red), unselected stays `.outline`.
  ///
  /// The child is a Flexible+Text with `maxLines: 2` + ellipsis so the
  /// button does not push the Row past its slot — protects against the
  /// 3-per-row narrow-width overflow seen pre-fix at 360 px.
  Widget _toggleBtn(BuildContext c, String label, bool on, VoidCallback t) {
    return SizedBox(
      height: 48,
      child: FButton.raw(
        onPress: t,
        variant: on ? FButtonVariant.primary : FButtonVariant.outline,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ),
    );
  }
}
