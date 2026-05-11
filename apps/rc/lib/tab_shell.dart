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
// Tab 2 — Buttons: 4-way hold pad + recenter/sleep/wake.
// (PR C will rebuild this as an 8-way pad with a speed slider.)
// ---------------------------------------------------------------------------

class _ButtonsTab extends StatelessWidget {
  final WsClient client;
  const _ButtonsTab({required this.client});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(
              child: HoldDirBtn(
                icon: Icons.keyboard_arrow_left,
                label: 'Left',
                client: client,
                yawSpeed: -80,
                pitchSpeed: 0,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HoldDirBtn(
                icon: Icons.keyboard_arrow_up,
                label: 'Up',
                client: client,
                yawSpeed: 0,
                pitchSpeed: 40,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HoldDirBtn(
                icon: Icons.keyboard_arrow_down,
                label: 'Down',
                client: client,
                yawSpeed: 0,
                pitchSpeed: -40,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HoldDirBtn(
                icon: Icons.keyboard_arrow_right,
                label: 'Right',
                client: client,
                yawSpeed: 80,
                pitchSpeed: 0,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: <Widget>[
            Expanded(child: _flatBtn(context, 'Recenter',
                Icons.center_focus_strong, () => client.ptzRecenter())),
            const SizedBox(width: 8),
            Expanded(child: _flatBtn(context, 'Sleep', Icons.bedtime,
                () => client.runStatus('sleep'))),
            const SizedBox(width: 8),
            Expanded(child: _flatBtn(context, 'Wake', Icons.wb_sunny,
                () => client.runStatus('run'))),
          ]),
        ],
      ),
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
// Tab 3 — Presets: existing 4 preset buttons.
// (PR D will expand to 6 cards in a 2×3 grid with thumbnails.)
// ---------------------------------------------------------------------------

class _PresetsTab extends StatelessWidget {
  final WsClient client;
  const _PresetsTab({required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.4,
            children: <Widget>[
              for (int i = 0; i < 4; i++)
                _PresetButton(
                    client: client, id: i, label: 'P${i + 1}'),
            ],
          ),
        );
      },
    );
  }
}

class _PresetButton extends StatelessWidget {
  final WsClient client;
  final int id;
  final String label;
  const _PresetButton({
    required this.client,
    required this.id,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () {
        client.presetSave(id, label);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved $label at current position'),
            duration: const Duration(milliseconds: 800),
          ),
        );
      },
      child: FilledButton.tonal(
        onPressed: () => client.presetRecall(id),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(label,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700)),
            const Text('hold to save', style: TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 4 — Sequence: embeds SequencerScreen's body (no nested Scaffold/AppBar).
// PR E will swap this for a timeline card layout.
// ---------------------------------------------------------------------------

class _SequenceTab extends StatelessWidget {
  final WsClient client;
  const _SequenceTab({required this.client});

  @override
  Widget build(BuildContext context) {
    // SequencerScreen already supplies its own Scaffold, so we present a
    // button that opens it via a route push. PR E will inline this into
    // a tab-native layout.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.timeline, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Sequence editor',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Build a timed pan between presets.\nTab-native timeline lands in PR E.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.edit),
              label: const Text('Open sequence editor'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SequencerScreen(client: client),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
