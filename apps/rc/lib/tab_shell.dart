import 'package:flutter/material.dart';

import 'control_screen.dart';
import 'preview_widget.dart';
import 'sequencer_screen.dart';
import 'ws_client.dart';

/// v1.2 redesign — 5-tab shell below a pinned live preview.
///
/// PR A (`feat/tab-bar-shell`): pure layout. The five tabs each host the
/// existing widgets that already worked in v1.1; subsequent PRs (B–F)
/// refine one tab at a time per `docs/UI_REDESIGN_SPEC.md`.
///
/// Layout choices are driven by `LayoutBuilder.maxWidth`, not device
/// class (see the `flutter-build-responsive-layout` skill):
///
///   • <600  px wide  → preview pinned on top (16:9), tabs below.
///   • ≥600  px wide  → preview pinned on the left (50%), tabs on the right.
///
/// Tabs:
///   1. Joystick — `PtzPad` + `ZoomSlider`.
///   2. Buttons  — 4-way hold-direction pad + recenter/sleep/wake.
///   3. Presets  — preset buttons (2×3 grid lands in PR D).
///   4. Sequence — embedded `SequencerScreen` body.
///   5. Image    — HDR / FOV / AI-track / face / flip toggles.
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
    Tab(icon: Icon(Icons.view_module), text: 'Presets'),
    Tab(icon: Icon(Icons.timeline), text: 'Sequence'),
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
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints c) {
        final wide = c.maxWidth >= 600;
        return wide ? _wide(c) : _narrow();
      },
    );
  }

  Widget _narrow() {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: PreviewWidget(client: widget.client),
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
              child: PreviewWidget(client: widget.client),
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
        // Evenly distribute the 5 tabs across the available width. At
        // narrow phone widths each tab still meets the 44-px touch target
        // (360 / 5 = 72 px); the text label shrinks with overflow.
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
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
        _PresetsTab(client: widget.client),
        _SequenceTab(client: widget.client),
        _ImageTab(client: widget.client),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1 — Joystick (v1.2 PR B refinement).
//
// Layout per docs/UI_REDESIGN_SPEC.md:
//   - Top quick-action row: Recenter / Sleep / Wake.
//   - Middle: large round joystick pad centered + vertical zoom slider
//     pinned to the right (1.0× ↔ 2.0× on Tiny 2 Lite).
//   - Bottom: horizontal chip strip for Move duration
//     (Instant / 1s / 5s / 15s / 30s / 1m / 3m / 5m).
//
// Putting the joystick on its own tab fixes the pre-v1.2 "joystick eats
// scroll" conflict: the surrounding TabBarView swipes horizontally and
// doesn't compete with the joystick's vertical-first pan gestures.
// ---------------------------------------------------------------------------

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
              _quickActions(context),
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
              _durationChips(context),
            ],
          ),
        );
      },
    );
  }

  Widget _quickActions(BuildContext ctx) {
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.center_focus_strong, size: 18),
            label: const Text('Recenter'),
            onPressed: () => client.ptzRecenter(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.bedtime, size: 18),
            label: const Text('Sleep'),
            onPressed: () => client.runStatus('sleep'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.wb_sunny, size: 18),
            label: const Text('Wake'),
            onPressed: () => client.runStatus('run'),
          ),
        ),
      ],
    );
  }

  Widget _durationChips(BuildContext ctx) {
    final cur = client.moveDuration;
    final cs = Theme.of(ctx).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < kMoveDurationPresets.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 6),
            ChoiceChip(
              label: Text(kMoveDurationPresets[i].label),
              avatar: Icon(
                kMoveDurationPresets[i].icon,
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

// ---------------------------------------------------------------------------
// Tab 2 — Buttons (v1.2 PR C refinement).
//
// 8-way hold-button pad (4 cardinal + 4 diagonal) for users who prefer
// discrete directional input over the analog joystick. A "Slow ↔ Fast"
// speed slider scales the underlying gimbal velocity from 0.1× to 1.0×
// of the per-direction defaults (yaw ±80°/s, pitch ±40°/s).
//
// Same Recenter / Sleep / Wake quick-actions as the Joystick tab.
// ---------------------------------------------------------------------------

class _ButtonsTab extends StatefulWidget {
  final WsClient client;
  const _ButtonsTab({required this.client});

  @override
  State<_ButtonsTab> createState() => _ButtonsTabState();
}

class _ButtonsTabState extends State<_ButtonsTab> {
  /// Multiplier applied to the per-direction velocity. 1.0× = full speed
  /// (matches v1.1 behavior); slider lets the user dial down to 0.1×
  /// for slow framing pans.
  double _speed = 1.0;

  static const double _baseYaw = 80;   // °/s
  static const double _basePitch = 40; // °/s

  @override
  Widget build(BuildContext context) {
    final yaw = _baseYaw * _speed;
    final pit = _basePitch * _speed;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _padRow(<Widget>[
            _dir(Icons.north_west, 'Up-Left', -yaw, pit),
            _dir(Icons.north, 'Up', 0, pit),
            _dir(Icons.north_east, 'Up-Right', yaw, pit),
          ]),
          const SizedBox(height: 8),
          _padRow(<Widget>[
            _dir(Icons.west, 'Left', -yaw, 0),
            _center(),
            _dir(Icons.east, 'Right', yaw, 0),
          ]),
          const SizedBox(height: 8),
          _padRow(<Widget>[
            _dir(Icons.south_west, 'Down-Left', -yaw, -pit),
            _dir(Icons.south, 'Down', 0, -pit),
            _dir(Icons.south_east, 'Down-Right', yaw, -pit),
          ]),
          const SizedBox(height: 16),
          _speedSlider(context),
          const SizedBox(height: 16),
          Row(children: <Widget>[
            Expanded(
                child: _flatBtn(context, 'Recenter',
                    Icons.center_focus_strong, () => widget.client.ptzRecenter())),
            const SizedBox(width: 8),
            Expanded(
                child: _flatBtn(context, 'Sleep', Icons.bedtime,
                    () => widget.client.runStatus('sleep'))),
            const SizedBox(width: 8),
            Expanded(
                child: _flatBtn(context, 'Wake', Icons.wb_sunny,
                    () => widget.client.runStatus('run'))),
          ]),
        ],
      ),
    );
  }

  Widget _padRow(List<Widget> children) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: children[i]),
        ],
      ],
    );
  }

  Widget _dir(IconData icon, String label, double yawSpeed, double pitchSpeed) {
    return HoldDirBtn(
      icon: icon,
      label: label,
      client: widget.client,
      yawSpeed: yawSpeed,
      pitchSpeed: pitchSpeed,
    );
  }

  Widget _center() {
    // Empty center cell keeps the 3x3 grid balanced; we use the
    // explicit Recenter button below instead.
    return const SizedBox(height: 56);
  }

  Widget _speedSlider(BuildContext ctx) {
    final theme = Theme.of(ctx);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('Speed', style: theme.textTheme.labelLarge),
            const Spacer(),
            Text('${(_speed * 100).round()}%',
                style: theme.textTheme.labelMedium),
          ],
        ),
        Row(
          children: <Widget>[
            Text('Slow', style: theme.textTheme.bodySmall),
            Expanded(
              child: Slider(
                min: 0.1,
                max: 1.0,
                divisions: 9,
                value: _speed,
                onChanged: (double v) => setState(() => _speed = v),
              ),
            ),
            Text('Fast', style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }

  Widget _flatBtn(BuildContext c, String label, IconData icon, VoidCallback t) {
    return SizedBox(
      height: 56,
      child: FilledButton.tonalIcon(
        onPressed: t,
        icon: Icon(icon),
        label: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3 — Presets (v1.2 PR D refinement).
//
// 6 preset cards (P1..P6) laid out 2×3. Each card surfaces:
//   - "P#" badge + the saved name (or "(empty)" if never saved).
//   - Zoom badge (e.g. "1.7×") when the preset has a captured zoom.
//   - Tap = recall with the current `client.moveDuration`.
//   - Long-press = popup with Save current position / Rename / Recall instant.
//
// Per-preset thumbnails are out of scope for v1.2 (needs a bridge
// `preset.thumbnail` endpoint that snaps the current MJPEG frame).
// ---------------------------------------------------------------------------

class _PresetsTab extends StatelessWidget {
  final WsClient client;
  const _PresetsTab({required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final presets = client.state.presets;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.3,
            children: <Widget>[
              for (int i = 0; i < 6; i++)
                _PresetCard(
                  client: client,
                  id: i,
                  entry: _lookupPreset(presets, i),
                ),
            ],
          ),
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

class _PresetCard extends StatelessWidget {
  final WsClient client;
  final int id;
  final PresetEntry? entry;
  const _PresetCard({
    required this.client,
    required this.id,
    required this.entry,
  });

  String get _badge => 'P${id + 1}';
  bool get _saved => entry != null && entry!.name.isNotEmpty;
  String get _displayName => _saved ? entry!.name : '(empty)';
  String? get _zoomBadge =>
      entry == null ? null : '${entry!.zoom.toStringAsFixed(1)}×';

  Future<void> _showMenu(BuildContext ctx) async {
    final choice = await showModalBottomSheet<String>(
      context: ctx,
      builder: (BuildContext c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: const Text('Save current position'),
              subtitle: Text(
                'Overwrite $_badge with the camera\'s current pan / tilt / zoom.',
              ),
              onTap: () => Navigator.of(c).pop('save'),
            ),
            ListTile(
              leading: const Icon(Icons.flash_on),
              title: const Text('Recall instantly'),
              subtitle: const Text('Ignore Move duration; snap to preset.'),
              enabled: _saved,
              onTap: () => Navigator.of(c).pop('recall_instant'),
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename…'),
              enabled: _saved,
              onTap: () => Navigator.of(c).pop('rename'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'save') {
      // Default save name = preserve existing or fall back to "P#".
      final name = _saved ? entry!.name : _badge;
      client.presetSave(id, name);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text('Saved $_badge at current position'),
            duration: const Duration(milliseconds: 1000),
          ),
        );
      }
    } else if (choice == 'recall_instant') {
      client.presetRecall(id, duration: Duration.zero);
    } else if (choice == 'rename') {
      if (!ctx.mounted) return;
      final ctrl = TextEditingController(text: entry?.name ?? '');
      final newName = await showDialog<String>(
        context: ctx,
        builder: (BuildContext c) => AlertDialog(
          title: Text('Rename $_badge'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(
              hintText: 'e.g. Stage, Vocalist, Lectern',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(c).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      if (newName != null && newName.isNotEmpty) {
        client.presetSave(id, newName);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      elevation: 0,
      color: _saved ? cs.surfaceContainerHigh : cs.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _saved ? () => client.presetRecall(id) : () => _showMenu(context),
        onLongPress: () => _showMenu(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _saved ? cs.primary : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _badge,
                      style: TextStyle(
                        color: _saved ? cs.onPrimary : cs.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_zoomBadge != null)
                    Text(
                      _zoomBadge!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                _displayName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: _saved ? cs.onSurface : cs.outline,
                  fontStyle: _saved ? FontStyle.normal : FontStyle.italic,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                _saved ? 'Tap to recall  •  hold to edit' : 'Hold to save here',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 4 — Sequence (v1.2 PR E refinement).
//
// Embeds the [SequencerEditor] directly: timeline of step cards with
// preset picker + Hold seconds + Move duration, plus the library bar,
// running progress bar, loop-mode selector, and Add / Start / Stop /
// Apply / Save-as toolbar — all inline, no route push.
//
// The route-based SequencerScreen still exists for Simple Mode.
// ---------------------------------------------------------------------------

class _SequenceTab extends StatelessWidget {
  final WsClient client;
  const _SequenceTab({required this.client});

  @override
  Widget build(BuildContext context) {
    return SequencerEditor(client: client);
  }
}

// ---------------------------------------------------------------------------
// Tab 5 — Image: HDR / FOV / AI-track / face / flip-H toggles.
// PR F will round this out (sliders for color); PR G adds exposure controls.
// ---------------------------------------------------------------------------

class _ImageTab extends StatelessWidget {
  final WsClient client;
  const _ImageTab({required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _toggleBtn(
                      context,
                      'Track person',
                      s.aiMode == 'human',
                      () => client.aiSetMode(
                        s.aiMode == 'human' ? 'none' : 'human',
                        'normal',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _toggleBtn(context, 'HDR', s.hdr,
                        () => client.hdr(!s.hdr)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _toggleBtn(
                      context,
                      'View: ${_fovLabel(s.fov)}',
                      false,
                      () {
                        final next =
                            s.fov == 86 ? 78 : (s.fov == 78 ? 65 : 86);
                        client.fov(next);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // PR F lands face-AE / face-focus / flip-H / color sliders.
              Text(
                'Face exposure, focus-on-face, flip-horizontal and color '
                'sliders land in PR F. Exposure mode + EV bias + WB land '
                'in PR G — see docs/EXPOSURE_REFERENCE.md.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _fovLabel(int fov) {
    if (fov == 86) return 'Wide';
    if (fov == 78) return 'Normal';
    if (fov == 65) return 'Narrow';
    return '$fov°';
  }

  Widget _toggleBtn(BuildContext c, String label, bool on, VoidCallback t) {
    final cs = Theme.of(c).colorScheme;
    return SizedBox(
      height: 56,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor:
              on ? cs.primary : cs.surfaceContainerHighest,
          foregroundColor: on ? cs.onPrimary : cs.onSurface,
        ),
        onPressed: t,
        child: Text(label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 2),
      ),
    );
  }
}
