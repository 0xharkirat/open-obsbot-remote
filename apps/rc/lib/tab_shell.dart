import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cache_menu.dart';
import 'control_screen.dart';
import 'move_duration_icons.dart';
import 'preview_widget.dart';
import 'sequencer_screen.dart';
import 'widgets/collapsible_section.dart';
import 'widgets/preset_options_sheet.dart';
import 'ws_client.dart';

/// v1.4 W6 redesign - OBSBOT Center-inspired 3-tab shell:
///   - **Drive**: presets, joystick OR 8-way button pad, zoom, FOV,
///     move pacing, AI tracking. Top of the page has a sticky
///     `_QuickActions` row (Recenter / Sleep / Wake) so it's always
///     reachable while scrolling through the deeper controls below.
///     Control style toggle (joystick vs buttons) lives at the bottom
///     of View & Gimbal so the operator can switch on the spot.
///   - **Image**: tone / exposure / anti-flicker / WB / color, each
///     wrapped in a `CollapsibleSection`. Same body as v1.4 W6 phase 2,
///     minus FOV + Auto-track which moved to Drive.
///   - **More**: device info, sequence library, grid overlay toggles,
///     connection (server URL + disconnect + cache), about (version +
///     mode switch + log instructions). Replaces the v1.2 AppBar
///     actions (grid menu, simple-mode toggle, disconnect, cache).
///
/// Layout choices are driven by `LayoutBuilder.maxWidth`, not device
/// class (see the `flutter-build-responsive-layout` skill):
///
///   • <600  px wide  → preview pinned on top (16:9), tabs below.
///   • ≥600  px wide  → preview pinned on the left (50%), tabs on the right.
///
/// Pre-v1.4-W6 the shell was Joystick / Buttons / Image - the two
/// PTZ tabs were redundant (same surface, swap control widget).
/// Folding into one Drive page recovers a tab slot for More and lets
/// the operator switch joystick<->buttons without losing context.
class TabShell extends StatefulWidget {
  final WsClient client;
  final VoidCallback? onSwitchSimple;
  const TabShell({super.key, required this.client, this.onSwitchSimple});

  @override
  State<TabShell> createState() => _TabShellState();
}

class _TabShellState extends State<TabShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  static const _tabs = <Tab>[
    Tab(icon: Icon(Icons.gamepad), text: 'Drive'),
    Tab(icon: Icon(Icons.image), text: 'Image'),
    Tab(icon: Icon(Icons.more_horiz), text: 'More'),
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

  // v1.5 W3 fix: forui's `FThemes.zinc.dark` defines `colors.primary`
  // as near-white (#E4E4E7), which is shadcn's "inverted primary"
  // convention - the primary surface on dark themes is light. The v1.2.1
  // `_toggleBtn` / `ForSegmented` migration to `FButton.raw` with
  // `variant: FButtonVariant.primary` assumed primary meant OBSBOT
  // brand red (matching the Material `ColorScheme.primary` set in
  // `main.dart`). It does NOT - the two theme systems are independent.
  //
  // Symptom: Image-tab Face exposure / Face focus toggles render as
  // a white slab when ON, while HDR / Flip stay outlined when OFF.
  // The white slab is correct forui rendering against the wrong
  // primary color. Same applies to selected `ForSegmented` pills.
  //
  // Fix: build a customized `FThemeData` whose `colors.primary` is the
  // OBSBOT brand red (matches Material `colorScheme.primary` from
  // `main.dart`) and `primaryForeground` is white. All `variant:
  // primary` call sites in this file inherit the correct brand color
  // without touching individual buttons.
  static final FThemeData _obsbotForTheme = FThemeData(
    touch: true,
    colors: FThemes.zinc.dark.touch.colors.copyWith(
      primary: const Color(0xFFFF3B30),
      primaryForeground: const Color(0xFFFFFFFF),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: _obsbotForTheme,
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
        _DriveTab(client: widget.client),
        _ImageTab(client: widget.client),
        _MoreTab(client: widget.client, onSwitchSimple: widget.onSwitchSimple),
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

  // A slot is "saved" the moment the bridge has stored a pose for it,
  // regardless of whether the user gave it a name. Previously this
  // required a non-empty name, which meant unnamed presets fell back
  // to the empty-slot branch and tap-to-recall silently became
  // tap-to-save. Live report: "if I tap or hold, it saves the preset
  //  -  tap should be to change to that preset."
  bool get _saved => entry != null;
  String get _label =>
      (entry != null && entry!.name.isNotEmpty) ? entry!.name : 'P${id + 1}';

  /// One-step save used for EMPTY slots only. Long-press on a saved
  /// slot now goes through `showPresetOptions` (v1.4 W4) instead of
  /// silently overwriting.
  void _save(BuildContext ctx) {
    HapticFeedback.heavyImpact();
    client.presetSave(id, _label);
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('Saved $_label at current position'),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  Future<void> _openOptions(BuildContext ctx) async {
    HapticFeedback.heavyImpact();
    await showPresetOptions(
      ctx,
      client,
      id,
      entry!,
      onRename: () => showPresetRenameDialog(
        ctx,
        initial: entry!.name.isNotEmpty ? entry!.name : 'P${id + 1}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPress: () =>
          _saved ? _openOptions(context) : _save(context),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      color: _saved ? cs.onPrimaryContainer : cs.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _saved ? 'tap • hold for menu' : 'hold to save',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
/// chips. User review pointed out the redundancy  -  slider scaled live
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
// Tab 1  -  Drive
// ===========================================================================
//
// v1.4 W6 consolidation: folds the old Joystick + Buttons tabs into one
// scrollable Drive page. Layout:
//
//   - Top sticky `_QuickActions` row (Recenter / Sleep / Wake), never
//     scrolls so the operator's most-used emergency actions stay one
//     tap away no matter how deep they scroll.
//   - Presets (default open) - inline P1..P6 row.
//   - View & Gimbal (default open) - fixed-height control area: 8-way
//     button pad (v1.5 default) OR PtzPad joystick (based on
//     `client.driveControlStyle`) beside a vertical ZoomSlider, then
//     FOV pills (moved from Image) + a "Switch to joystick / buttons"
//     toggle. Buttons are the default because the discrete 8 directions
//     are unambiguous - operators new to the app land on the clearer
//     surface; joystick stays a one-tap toggle away.
//   - Move pacing (default open) - the existing duration chip strip.
//   - AI tracking (default open) - mode segmented (Off / Person /
//     Group) PLUS the v1.4 sub-mode picker (Normal / Upper-body /
//     Close-up / Headless / Lower-body). Sub-mode pills appear only
//     when mode = `human`.
//
// The PtzPad joystick sits inside a fixed-height pinned section so it
// has a stable size and the outer ScrollView won't claim its pointer
// events (CLAUDE.md note #24).

class _DriveTab extends StatelessWidget {
  final WsClient client;
  const _DriveTab({required this.client});

  /// Default FOV that the View & Gimbal reset button restores to.
  static const int _defaultFov = 86;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Sticky top - never scrolls.
              _QuickActions(client: client),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      CollapsibleSection(
                        id: 'drive_presets',
                        label: 'Presets',
                        child: _InlinePresetRow(client: client),
                      ),
                      CollapsibleSection(
                        id: 'drive_view_gimbal',
                        label: 'View & Gimbal',
                        child: _ViewAndGimbalBody(
                          client: client,
                          state: s,
                          defaultFov: _defaultFov,
                        ),
                      ),
                      CollapsibleSection(
                        id: 'drive_move_pacing',
                        label: 'Move pacing',
                        tooltip:
                            'Sets how long the camera takes to drive to '
                            'a preset or angle. Affects ptz.angle and '
                            'preset recall.',
                        child: _BottomControls(client: client),
                      ),
                      CollapsibleSection(
                        id: 'drive_ai',
                        label: 'AI tracking',
                        tooltip:
                            'AI owns the gimbal while on. Off lets you '
                            'manually drive again.',
                        child: _AiSection(client: client, state: s),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// View & Gimbal body for the Drive page. Renders the active control
/// surface (PtzPad or 8-way buttons) inside a fixed-height SizedBox so
/// the outer SingleChildScrollView never claims the PtzPad pointer.
/// FOV and the control-style toggle live below the pad.
class _ViewAndGimbalBody extends StatelessWidget {
  final WsClient client;
  final CameraState state;
  final int defaultFov;
  const _ViewAndGimbalBody({
    required this.client,
    required this.state,
    required this.defaultFov,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Fixed-height control area so the joystick has a stable
        // bounding box and outer ScrollView never steals its pointer.
        SizedBox(
          height: 260,
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: client.driveControlStyle == 'buttons'
                    ? _DriveButtonPad(client: client)
                    : PtzPad(client: client),
              ),
              SizedBox(
                width: 80,
                child: ZoomSlider(client: client, state: state),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: Text(
            'Field of view',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ForSegmented<int>(
          values: const <int>[86, 78, 65],
          labels: const <String>['Wide', 'Normal', 'Narrow'],
          selected: state.fov,
          onChanged: client.fov,
        ),
        const SizedBox(height: 8),
        // Control-style toggle. Use a Wrap so at 320 px the pills wrap
        // beneath the label instead of overflowing the row.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.tune,
                    size: 14, color: theme.colorScheme.outline),
                const SizedBox(width: 6),
                Text('Control style',
                    style: theme.textTheme.bodySmall),
              ],
            ),
            // Compact 2-segment picker. ForSegmented is overkill at 2
            // values + needs its own row; a tiny inline pair reads as
            // a setting on the same line as its label.
            Wrap(
              spacing: 6,
              children: <Widget>[
                _StylePillBtn(
                  label: 'Joystick',
                  icon: Icons.gamepad,
                  selected: client.driveControlStyle == 'joystick',
                  onTap: () => client.setDriveControlStyle('joystick'),
                ),
                _StylePillBtn(
                  label: 'Buttons',
                  icon: Icons.touch_app,
                  selected: client.driveControlStyle == 'buttons',
                  onTap: () => client.setDriveControlStyle('buttons'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              foregroundColor: theme.colorScheme.outline,
            ),
            icon: const Icon(Icons.restart_alt, size: 14),
            label: const Text('Reset FOV',
                style: TextStyle(fontSize: 11)),
            onPressed: () => client.fov(defaultFov),
          ),
        ),
      ],
    );
  }
}

/// Tiny pill toggle for the control-style switch on the Drive page.
/// Two side-by-side instances form a mini segmented control without
/// pulling in ForSegmented (which spans full width).
class _StylePillBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _StylePillBtn({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primary : cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon,
                  size: 14,
                  color: selected ? cs.onPrimary : cs.onSurface),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? cs.onPrimary : cs.onSurface,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

/// 8-way press-and-hold direction pad for the Drive page's buttons
/// style. Same widget tree as the old _ButtonsTab inner column, but
/// without its surrounding tab chrome - now rendered inside View &
/// Gimbal's fixed-height pinned area.
class _DriveButtonPad extends StatelessWidget {
  // Hold-button velocities in deg/s - matches v1.2 ButtonsTab.
  final WsClient client;
  static const double _yaw = 80;
  static const double _pit = 40;
  const _DriveButtonPad({required this.client});

  @override
  Widget build(BuildContext context) {
    final c = client;
    return Column(
      children: <Widget>[
        Expanded(
          child: _padRow(<Widget>[
            HoldDirBtn(
                icon: Icons.north_west,
                label: 'Up-Left',
                client: c,
                yawSpeed: -_yaw,
                pitchSpeed: _pit),
            HoldDirBtn(
                icon: Icons.north,
                label: 'Up',
                client: c,
                yawSpeed: 0,
                pitchSpeed: _pit),
            HoldDirBtn(
                icon: Icons.north_east,
                label: 'Up-Right',
                client: c,
                yawSpeed: _yaw,
                pitchSpeed: _pit),
          ]),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _padRow(<Widget>[
            HoldDirBtn(
                icon: Icons.west,
                label: 'Left',
                client: c,
                yawSpeed: -_yaw,
                pitchSpeed: 0),
            const SizedBox.shrink(),
            HoldDirBtn(
                icon: Icons.east,
                label: 'Right',
                client: c,
                yawSpeed: _yaw,
                pitchSpeed: 0),
          ]),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _padRow(<Widget>[
            HoldDirBtn(
                icon: Icons.south_west,
                label: 'Down-Left',
                client: c,
                yawSpeed: -_yaw,
                pitchSpeed: -_pit),
            HoldDirBtn(
                icon: Icons.south,
                label: 'Down',
                client: c,
                yawSpeed: 0,
                pitchSpeed: -_pit),
            HoldDirBtn(
                icon: Icons.south_east,
                label: 'Down-Right',
                client: c,
                yawSpeed: _yaw,
                pitchSpeed: -_pit),
          ]),
        ),
      ],
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
}

/// AI tracking section body. Top row is the mode picker
/// (Off / Person / Group). When mode = `human`, a sub-mode picker
/// (Normal / Upper-body / Close-up / Headless / Lower-body) appears
/// below. Sub-modes are wired via `client.aiSetMode(mode, subMode)`.
class _AiSection extends StatelessWidget {
  final WsClient client;
  final CameraState state;
  const _AiSection({required this.client, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ForSegmented<String>(
          values: const <String>['none', 'human', 'group'],
          labels: const <String>['Off', 'Person', 'Group'],
          icons: const <IconData?>[null, Icons.person, Icons.groups],
          selected: state.aiMode,
          onChanged: (String v) => client.aiSetMode(v, state.aiSubMode),
        ),
        if (state.aiMode == 'human') ...<Widget>[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              'Framing',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 5 sub-modes won't fit cleanly in a single row at 320 px;
          // a Wrap with small pills handles overflow gracefully and
          // keeps the surface scan-friendly.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final s in const <({String wire, String label})>[
                (wire: 'normal', label: 'Normal'),
                (wire: 'upper_body', label: 'Upper-body'),
                (wire: 'close_up', label: 'Close-up'),
                (wire: 'head_hide', label: 'Headless'),
                (wire: 'lower_body', label: 'Lower-body'),
              ])
                _StylePillBtn(
                  label: s.label,
                  icon: Icons.crop_free,
                  selected: state.aiSubMode == s.wire,
                  onTap: () => client.aiSetMode('human', s.wire),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ===========================================================================
// Tab 3  -  More (device, sequence library, grid overlay, connection, about)
// ===========================================================================

/// Consolidates the v1.2 AppBar overflow + extra surfaces into a tab:
///   - Device: model / SN / firmware / latency (read-only).
///   - Sequence library: tap a saved sequence to load + start, or
///     open the full editor.
///   - Grid overlay: 4 toggles (crosshair / attitude / thirds / readout)
///     that drive the preview overlay across all tabs.
///   - Connection: server URL, paired count, disconnect, cache clear.
///   - About: version, simple-mode switch, link to bridge log notes.
class _MoreTab extends StatelessWidget {
  final WsClient client;
  final VoidCallback? onSwitchSimple;
  const _MoreTab({required this.client, this.onSwitchSimple});

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
              CollapsibleSection(
                id: 'more_device',
                label: 'Device',
                child: _DeviceInfoBody(client: client, state: s),
              ),
              CollapsibleSection(
                id: 'more_sequence_library',
                label: 'Sequence library',
                child: _SequenceLibraryBody(client: client, state: s),
              ),
              CollapsibleSection(
                id: 'more_grid_overlay',
                label: 'Grid overlay',
                tooltip:
                    'Overlays painted on the live preview - not '
                    'recorded by the camera.',
                child: _GridOverlayBody(client: client),
              ),
              CollapsibleSection(
                id: 'more_connection',
                label: 'Connection',
                child: _ConnectionBody(client: client, state: s),
              ),
              CollapsibleSection(
                id: 'more_about',
                label: 'About',
                child: _AboutBody(onSwitchSimple: onSwitchSimple),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DeviceInfoBody extends StatelessWidget {
  final WsClient client;
  final CameraState state;
  const _DeviceInfoBody({required this.client, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _kvRow(context, 'Model',
            state.modelDisplay.isEmpty ? '...' : state.modelDisplay),
        _kvRow(context, 'Serial',
            state.sn.isEmpty ? '...' : state.sn),
        _kvRow(context, 'Firmware',
            state.firmware.isEmpty ? '...' : state.firmware),
        _kvRow(context, 'Latency', '${client.lastLatencyMs} ms'),
        _kvRow(context, 'Status', _statusLabel(state)),
      ],
    );
  }

  String _statusLabel(CameraState s) {
    if (!s.connected) return 'Not connected';
    switch (s.runStatus) {
      case 'run':
        return 'Running';
      case 'sleep':
        return 'Sleeping';
      case 'privacy':
        return 'Privacy mode';
      default:
        return s.runStatus;
    }
  }

  Widget _kvRow(BuildContext ctx, String k, String v) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(k,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline)),
          ),
          Expanded(
            child: Text(
              v,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _SequenceLibraryBody extends StatelessWidget {
  final WsClient client;
  final CameraState state;
  const _SequenceLibraryBody({required this.client, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lib = state.sequence.available;
    final running = state.sequence.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (lib.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No saved sequences yet. Open the editor to create one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          for (final name in lib)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Material(
                color: theme.colorScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side:
                      BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    client.sequenceLoad(name);
                    if (!running) client.sequenceStart();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Loaded "$name"'),
                        duration: const Duration(milliseconds: 900),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          state.sequence.loaded == name
                              ? Icons.bookmark
                              : Icons.bookmark_outline,
                          size: 16,
                          color: state.sequence.loaded == name
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(name,
                              style: theme.textTheme.bodyMedium,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (state.sequence.loaded == name && running)
                          Icon(Icons.play_arrow,
                              size: 16,
                              color: theme.colorScheme.primary),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: FButton.raw(
            variant: FButtonVariant.outline,
            onPress: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SequencerScreen(client: client),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.edit_note, size: 16),
                  SizedBox(width: 6),
                  Text('Open editor'),
                ],
              ),
            ),
          ),
        ),
        if (running) ...<Widget>[
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            child: FButton.raw(
              variant: FButtonVariant.outline,
              onPress: client.sequenceStop,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.stop, size: 16),
                    SizedBox(width: 6),
                    Text('Stop sequence'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _GridOverlayBody extends StatelessWidget {
  final WsClient client;
  const _GridOverlayBody({required this.client});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Center crosshair'),
          value: client.gridCrosshair,
          onChanged: client.setGridCrosshair,
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Attitude indicator'),
          subtitle: const Text('Steers with the gimbal like an airplane HUD'),
          value: client.gridCenterLines,
          onChanged: client.setGridCenterLines,
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Rule of thirds'),
          value: client.gridThirds,
          onChanged: client.setGridThirds,
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Pan / Tilt readout'),
          value: client.gridReadout,
          onChanged: client.setGridReadout,
        ),
      ],
    );
  }
}

class _ConnectionBody extends StatelessWidget {
  final WsClient client;
  final CameraState state;
  const _ConnectionBody({required this.client, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 96,
                child: Text('Server',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline)),
              ),
              Expanded(
                child: Text(
                  client.serverUri.isEmpty ? '-' : client.serverUri,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: SizedBox(
                height: 40,
                child: FButton.raw(
                  variant: FButtonVariant.outline,
                  onPress: () => client.close(),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.logout, size: 16),
                        SizedBox(width: 6),
                        Text('Disconnect'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // CacheMenu uses a PopupMenuButton internally. Render it
            // inline as a tappable surface so the visual weight matches
            // the Disconnect button.
            CacheMenu(onCleared: () => client.close()),
          ],
        ),
      ],
    );
  }
}

class _AboutBody extends StatelessWidget {
  final VoidCallback? onSwitchSimple;
  const _AboutBody({this.onSwitchSimple});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 96,
                child: Text('Version',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline)),
              ),
              Expanded(
                child: Text(
                  '1.4.0-dev',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Bridge logs:\n~/Library/Logs/Open OBSBOT Bridge/bridge.log\n\n'
            'Quit the Bridge from its menubar icon, not the dock.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Tappable link to the project site / docs - opens in browser.
        TextButton.icon(
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          icon: const Icon(Icons.open_in_new, size: 14),
          label: const Text('Open project README'),
          onPressed: () => launchUrl(
            Uri.parse('https://github.com/0xharkirat/obsbot.workspace'),
            mode: LaunchMode.externalApplication,
          ),
        ),
        if (onSwitchSimple != null) ...<Widget>[
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: FButton.raw(
              variant: FButtonVariant.outline,
              onPress: onSwitchSimple,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.dashboard_customize, size: 16),
                    SizedBox(width: 6),
                    Text('Switch to Simple mode'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}


// ===========================================================================
// Tab 3  -  Image (HDR / FOV / face / flip / color + Exposure / Anti-flicker
// / WB, each with a reset-to-default button per section)
// ===========================================================================

class _ImageTab extends StatelessWidget {
  final WsClient client;
  const _ImageTab({required this.client});

  // Per-setting defaults that the Reset buttons restore to.
  // _defaultFov moved to _DriveTab in v1.4 W6 phase 3 with the FOV
  // controls.
  static const int _defaultColor = 50;
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
              // v1.4 W6 OBSBOT-Center pass: each section is wrapped in
              // CollapsibleSection so the operator can hide groups they
              // don't currently use (most users tweak Tone + WB once,
              // then never reopen Color / Anti-flicker). Open state is
              // persisted per section id.
              //
              // Auto-track + View (FOV) moved to the Drive page in v1.4
              // W6 phase 3 - this page now stays focused on per-frame
              // image quality (tone / exposure / WB / color).
              CollapsibleSection(
                id: 'image_tone',
                label: 'Tone',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
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
                  ],
                ),
              ),
              CollapsibleSection(
                id: 'image_exposure',
                label: 'Exposure',
                tooltip:
                    'Auto adapts exposure to scene brightness. EV bias '
                    'nudges brighter (+) or darker (-).',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _exposureSegmented(ctx, s),
                    if (s.exposureMode == 'auto') _evBiasSlider(ctx, s),
                    _inlineReset(
                      ctx,
                      onPressed: () {
                        client.setExposureMode(_defaultExposureMode);
                        client.setEvBias(_defaultEvBias);
                      },
                    ),
                  ],
                ),
              ),
              CollapsibleSection(
                id: 'image_anti_flicker',
                label: 'Anti-flicker',
                tooltip:
                    'Suppress fluorescent-light flicker. 50 Hz in IN/EU, '
                    '60 Hz in NA/JP.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _flickerSegmented(ctx, s),
                    _inlineReset(
                      ctx,
                      onPressed: () =>
                          client.setAntiFlicker(_defaultAntiFlicker),
                    ),
                  ],
                ),
              ),
              CollapsibleSection(
                id: 'image_wb',
                label: 'White balance',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _toggleBtn(ctx, 'Auto WB', s.wbAuto,
                              () => client.setWbAuto(!s.wbAuto)),
                        ),
                      ],
                    ),
                    if (!s.wbAuto) _wbTempSlider(ctx, s),
                    _inlineReset(
                      ctx,
                      onPressed: () {
                        client.setWbAuto(true);
                        client.setWbTemp(_defaultWbKelvin);
                      },
                    ),
                  ],
                ),
              ),
              CollapsibleSection(
                id: 'image_color',
                label: 'Color',
                // Color sliders are the least-touched group on this page
                // (most rooms have one decent lighting setup the user
                // tunes once). Start collapsed so the page is shorter
                // by default.
                defaultOpen: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _colorSlider(ctx, 'Brightness', s.brightness,
                        (v) => client.colorSet(brightness: v),
                        resetTo: _defaultColor,
                        onReset: () =>
                            client.colorSet(brightness: _defaultColor)),
                    _colorSlider(ctx, 'Contrast', s.contrast,
                        (v) => client.colorSet(contrast: v),
                        resetTo: _defaultColor,
                        onReset: () =>
                            client.colorSet(contrast: _defaultColor)),
                    _colorSlider(ctx, 'Saturation', s.saturation,
                        (v) => client.colorSet(saturation: v),
                        resetTo: _defaultColor,
                        onReset: () =>
                            client.colorSet(saturation: _defaultColor)),
                    _colorSlider(ctx, 'Sharpness', s.sharpness,
                        (v) => client.colorSet(sharpness: v),
                        resetTo: _defaultColor,
                        onReset: () =>
                            client.colorSet(sharpness: _defaultColor)),
                    _inlineReset(
                      ctx,
                      label: 'Reset all',
                      onPressed: () => client.colorSet(
                        brightness: _defaultColor,
                        contrast: _defaultColor,
                        saturation: _defaultColor,
                        sharpness: _defaultColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Subtle full-width reset action rendered at the bottom of a
  /// CollapsibleSection body. Replaces the old per-header "Reset" pill
  /// so the header chrome stays clean - the reset is still one tap
  /// away when the section is open, and out of the way when collapsed.
  Widget _inlineReset(
    BuildContext ctx, {
    String label = 'Reset',
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            foregroundColor: theme.colorScheme.outline,
          ),
          icon: const Icon(Icons.restart_alt, size: 14),
          label: Text(label, style: const TextStyle(fontSize: 11)),
          onPressed: onPressed,
        ),
      ),
    );
  }

  // _aiSegmented + _fovSegmented removed in v1.4 W6 phase 3 -
  // Auto-track and View (FOV) moved to the Drive page's AI section
  // and View & Gimbal section respectively.

  Widget _exposureSegmented(BuildContext ctx, CameraState s) {
    return ForSegmented<String>(
      values: const <String>['auto', 'manual'],
      labels: const <String>['Auto', 'Manual'],
      selected: s.exposureMode,
      onChanged: client.setExposureMode,
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
    return ForSegmented<String>(
      values: const <String>['off', '50', '60'],
      labels: const <String>['Off', '50 Hz', '60 Hz'],
      selected: s.antiFlicker,
      onChanged: client.setAntiFlicker,
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
  /// button does not push the Row past its slot  -  protects against the
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

/// forui-styled segmented control: a row of `FButton.raw` where the
/// selected value uses `variant: FButtonVariant.primary` (brand red)
/// and the others use `FButtonVariant.outline`.
///
/// PR v1.3 migration target: the Image tab's four
/// Material `SegmentedButton`s  -  Auto-track, View (FOV), Exposure
/// mode, Anti-flicker. Replacing in a single helper rather than
/// per-call-site so the visual treatment, overflow guards
/// (Flexible + ellipsis), and Semantics labelling stay in sync.
///
/// Why FButton row instead of FTabs or FSelectGroup:
///   - FTabs swaps body content per tab; we just want a one-of-N
///     picker.
///   - FSelectGroup is checkbox/radio-shaped; doesn't render as a
///     pill-style segmented control.
///   - FButton row reads as a segmented control to sighted users and
///     wraps each option in a Semantics radio role so screen readers
///     announce position + selection state correctly.
class ForSegmented<T> extends StatelessWidget {
  final List<T> values;
  final List<String> labels;
  /// Optional leading icons; pass `null` to omit an icon for a given
  /// option (icons drop out below ~110 px per button anyway, see
  /// note in `_QuickActions` about the v1.2.1 320 px overflow fix).
  final List<IconData?>? icons;
  final T selected;
  final ValueChanged<T> onChanged;
  /// Optional semantic group label (e.g. "Auto-track mode"). Falls
  /// back to no group label if not provided.
  final String? semanticsLabel;

  const ForSegmented({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.icons,
    this.semanticsLabel,
  })  : assert(values.length == labels.length,
            'values and labels must be the same length'),
        assert(icons == null || icons.length == values.length,
            'icons must be null or the same length as values');

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (int i = 0; i < values.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 6));
      final v = values[i];
      final label = labels[i];
      final icon = icons?[i];
      final isSelected = v == selected;
      children.add(Expanded(
        child: Semantics(
          inMutuallyExclusiveGroup: true,
          selected: isSelected,
          button: true,
          label: label,
          child: FButton.raw(
            onPress: () => onChanged(v),
            variant: isSelected
                ? FButtonVariant.primary
                : FButtonVariant.outline,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 14),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
    }
    final row = Row(children: children);
    if (semanticsLabel != null) {
      return Semantics(
        label: semanticsLabel,
        container: true,
        child: row,
      );
    }
    return row;
  }
}
