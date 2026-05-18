import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'footer.dart';
import 'move_duration_icons.dart';
import 'preview_widget.dart';
import 'sequencer_screen.dart';
import 'widgets/app_bar_actions.dart';
import 'ws_client.dart';

/// Performer-mode UI: live preview at the top + a grid of named preset
/// tiles. Big tap targets, no sliders, no PTZ pad. Optional running
/// sequence overlay below presets.
class SimpleModeScreen extends StatefulWidget {
  final WsClient client;
  final VoidCallback onSwitchAdvanced;

  const SimpleModeScreen({
    super.key,
    required this.client,
    required this.onSwitchAdvanced,
  });

  @override
  State<SimpleModeScreen> createState() => _SimpleModeScreenState();
}

class _SimpleModeScreenState extends State<SimpleModeScreen> {
  WsClient get client => widget.client;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext context, _) {
        final s = client.state;
        return Scaffold(
          appBar: AppBar(
            // Title is constant ("OBSBOT Remote") + logo. Camera
            // model + status moved into the overflow menu (was eating
            // top-bar real estate and was redundant with the live
            // preview).
            title: const AppBarTitle(),
            // Standard 4 icons + overflow: mesh / sequencer / mode / speed.
            actions: <Widget>[
              GridOverlayMenu(client: client),
              IconButton(
                tooltip: s.sequence.running ? 'Sequence running' : 'Sequence',
                icon: Icon(
                  s.sequence.running
                      ? Icons.multiline_chart
                      : Icons.timeline,
                ),
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SequencerScreen(client: client),
                  ));
                },
              ),
              IconButton(
                tooltip: 'Advanced mode',
                icon: const Icon(Icons.tune),
                onPressed: widget.onSwitchAdvanced,
              ),
              _speedMenu(context),
              AppBarOverflowMenu(client: client),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (BuildContext c, BoxConstraints cc) {
                final landscape = cc.maxWidth > cc.maxHeight;
                return landscape ? _landscape(context, s) : _portrait(context, s);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _portrait(BuildContext ctx, CameraState s) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(8),
          child: PreviewWidget(
            client: client,
            showCrosshair: client.gridCrosshair,
            showCenterLines: client.gridCenterLines,
            showThirds: client.gridThirds,
            showReadout: client.gridReadout,
          ),
        ),
        if (s.sequence.running) _seqBar(ctx, s),
        Expanded(child: _presetGrid(ctx, s, columns: 2)),
        const AppFooter(),
      ],
    );
  }

  Widget _landscape(BuildContext ctx, CameraState s) {
    return Column(children: <Widget>[
      Expanded(child: _landscapeRow(ctx, s)),
      const AppFooter(),
    ]);
  }

  Widget _landscapeRow(BuildContext ctx, CameraState s) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: <Widget>[
              Expanded(
                child: PreviewWidget(
                  client: client,
                  showCrosshair: client.gridCrosshair,
                  showCenterLines: client.gridCenterLines,
                  showThirds: client.gridThirds,
                  showReadout: client.gridReadout,
                ),
              ),
              if (s.sequence.running) _seqBar(ctx, s),
            ]),
          ),
        ),
        Expanded(
          flex: 4,
          child: _presetGrid(ctx, s, columns: 2),
        ),
      ],
    );
  }

  Widget _seqBar(BuildContext ctx, CameraState s) {
    final theme = Theme.of(ctx);
    final pct = s.sequence.totalS == 0
        ? 0.0
        : (s.sequence.elapsedS / s.sequence.totalS).clamp(0.0, 1.0);
    final remaining = (s.sequence.totalS - s.sequence.elapsedS).clamp(0, 9999);
    final mm = (remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (remaining % 60).toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: <Widget>[
        const Icon(Icons.timer, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Sequence — step ${s.sequence.stepIndex + 1}',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: pct, minHeight: 6),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text('$mm:$ss',
            style: const TextStyle(
                fontFamily: 'Menlo', fontWeight: FontWeight.w700)),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Stop',
          icon: const Icon(Icons.stop_circle),
          onPressed: client.sequenceStop,
        ),
      ]),
    );
  }

  Widget _presetGrid(BuildContext ctx, CameraState s, {required int columns}) {
    // Build 6 tiles regardless: existing presets fill first, empty slots after.
    const slots = 6;
    final byId = <int, PresetEntry>{
      for (final p in s.presets) p.id: p,
    };
    final tiles = <Widget>[];
    for (int i = 0; i < slots; i++) {
      final entry = byId[i];
      tiles.add(_presetTile(ctx, i, entry, s.activePresetId == i));
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.count(
        crossAxisCount: columns,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.6,
        children: tiles,
      ),
    );
  }

  Widget _presetTile(BuildContext ctx, int id, PresetEntry? entry, bool active) {
    final theme = Theme.of(ctx);
    final hasPreset = entry != null;
    final label = hasPreset && entry.name.isNotEmpty
        ? entry.name
        : 'P${id + 1}';
    final bg = active
        ? theme.colorScheme.primary
        : (hasPreset
            ? theme.colorScheme.surfaceContainerHigh
            : theme.colorScheme.surfaceContainerLowest);
    final fg = active
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: hasPreset
          ? () {
              HapticFeedback.lightImpact();
              client.presetRecall(id);  // uses client.moveDuration default
            }
          : null,
      onLongPress: () async {
        HapticFeedback.heavyImpact();
        final name = await _promptName(ctx, initial: entry?.name ?? 'P${id + 1}');
        if (name == null) return;
        client.presetSave(id, name);
      },
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
            width: active ? 0 : 1,
          ),
        ),
        child: Stack(children: <Widget>[
          Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: hasPreset ? 22 : 18,
                  fontWeight: FontWeight.w700,
                  color: hasPreset ? fg : theme.colorScheme.outline,
                ),
              ),
            ),
          ),
          if (active)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(Icons.check_circle, size: 16, color: fg),
            ),
          Positioned(
            bottom: 4,
            left: 8,
            child: Text(
              hasPreset ? 'P${id + 1} • hold to rename' : 'hold to save here',
              style: TextStyle(
                fontSize: 10,
                color: (active ? fg : theme.colorScheme.outline).withValues(alpha: 0.7),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _speedMenu(BuildContext ctx) {
    final cur = client.moveDuration;
    return PopupMenuButton<Duration>(
      tooltip: 'Move duration',
      icon: Icon(iconForMoveDuration(cur)),
      onSelected: (d) => client.setMoveDuration(d),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<Duration>>[
        for (final p in kMoveDurationPresets)
          CheckedPopupMenuItem<Duration>(
            value: p.duration,
            checked: p.duration == cur,
            child: Row(children: <Widget>[
              Icon(iconForMoveDuration(p.duration), size: 16),
              const SizedBox(width: 8),
              Text(p.label),
            ]),
          ),
      ],
    );
  }

  Future<String?> _promptName(BuildContext ctx,
      {required String initial}) async {
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
            hintText: 'e.g. Vocalist, GGS, Audience',
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(c).pop(null),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
              child: const Text('Save current pose')),
        ],
      ),
    );
  }
}
