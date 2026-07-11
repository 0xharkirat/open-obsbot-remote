import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ws_client.dart';

/// The cross-camera MIX sequencer (P3): an authored timeline of cues that
/// switch the program between cameras and move them - LIVE, on air, no lock.
///
/// This is a distinct surface from the per-camera sequencer: a cue names which
/// camera goes on air and what shot it takes, and the whole thing runs on the
/// bridge so it survives a phone disconnect.
class MixSequencerScreen extends StatelessWidget {
  const MixSequencerScreen({super.key, required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final loaded = client.mix.loaded;
        return Scaffold(
          appBar: AppBar(title: Text(loaded.isEmpty ? 'Mix' : loaded)),
          body: SafeArea(child: MixEditor(client: client)),
        );
      },
    );
  }
}

/// Editable cue with a stable hold-seconds controller (recreating the
/// controller each rebuild kills the cursor - the sequencer's trap #15).
class _CueEdit {
  _CueEdit({
    required this.cameraSn,
    this.presetId = -1,
    this.moveMs = 800,
    this.holdS = 10,
    this.transition = 'cut',
    this.mwSn,
    this.mwPresetId = 0,
    this.mwMoveMs = 800,
  }) : holdCtrl = TextEditingController(text: '$holdS'),
       cardKey = GlobalKey();

  String cameraSn;
  int presetId; // < 0 = hold current shot
  int moveMs;
  int holdS;
  String transition;
  String? mwSn; // null = no meanwhile pre-position
  int mwPresetId;
  int mwMoveMs;
  final TextEditingController holdCtrl;
  final GlobalKey cardKey;

  bool get hasMeanwhile => mwSn != null && mwSn!.isNotEmpty;

  MixCue toCue() => MixCue(
    cameraSn: cameraSn,
    presetId: presetId,
    moveMs: moveMs,
    holdS: holdS,
    transition: transition,
    mwSn: hasMeanwhile ? mwSn : null,
    mwPresetId: mwPresetId,
    mwMoveMs: mwMoveMs,
  );

  void dispose() => holdCtrl.dispose();
}

const List<(String, int)> _moveChoices = <(String, int)>[
  ('Cut', 0),
  ('0.8s', 800),
  ('2s', 2000),
  ('5s', 5000),
];

class MixEditor extends StatefulWidget {
  const MixEditor({super.key, required this.client});
  final WsClient client;

  @override
  State<MixEditor> createState() => _MixEditorState();
}

class _MixEditorState extends State<MixEditor> {
  final List<_CueEdit> _cues = <_CueEdit>[];
  String _mode = 'forward';
  String _hydratedSig = '__none__';

  @override
  void initState() {
    super.initState();
    _hydrate();
    widget.client.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChange);
    for (final c in _cues) {
      c.dispose();
    }
    super.dispose();
  }

  String _sigOf(List<MixCue> cues, String mode, String loaded) =>
      '$loaded::$mode::${cues.length}::'
      '${cues.map((c) => "${c.cameraSn}/${c.presetId}/${c.moveMs}/${c.holdS}/${c.mwSn ?? ''}${c.mwPresetId}").join(",")}';

  void _onChange() {
    final m = widget.client.mix;
    final sig = _sigOf(m.cues, m.mode, m.loaded);
    if (sig != _hydratedSig) _hydrate();
  }

  void _hydrate() {
    final m = widget.client.mix;
    for (final c in _cues) {
      c.dispose();
    }
    _cues.clear();
    if (m.cues.isNotEmpty) {
      for (final src in m.cues) {
        _cues.add(
          _CueEdit(
            cameraSn: src.cameraSn,
            presetId: src.presetId,
            moveMs: src.moveMs,
            holdS: src.holdS,
            transition: src.transition,
            mwSn: src.hasMeanwhile ? src.mwSn : null,
            mwPresetId: src.mwPresetId,
            mwMoveMs: src.mwMoveMs,
          ),
        );
      }
      _mode = m.mode;
    }
    _hydratedSig = _sigOf(m.cues, m.mode, m.loaded);
    if (mounted) setState(() {});
  }

  List<MixCue> get _asCues => _cues.map((c) => c.toCue()).toList();

  void _apply() => widget.client.mixSet(_asCues, _mode);

  void _addCue() {
    final devices = widget.client.bridge.devices;
    final sn = _cues.isNotEmpty
        ? _cues.last.cameraSn
        : (devices.isNotEmpty ? devices.first.deviceId : '');
    setState(() => _cues.add(_CueEdit(cameraSn: sn)));
    _apply();
  }

  void _removeAt(int i) {
    setState(() => _cues.removeAt(i).dispose());
    _apply();
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _cues.length) return;
    setState(() {
      final c = _cues.removeAt(i);
      _cues.insert(j, c);
    });
    _apply();
  }

  Future<void> _saveAs() async {
    final loaded = widget.client.mix.loaded;
    final ctrl = TextEditingController(text: loaded);
    final name = await showDialog<String>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Save mix as'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'e.g. Sunday diwan'),
          onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    widget.client.mixSaveAs(name, _asCues, _mode);
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.client.bridge.devices;
    final mix = widget.client.mix;
    if (devices.length < 2) {
      return _needsTwoCameras(context);
    }
    return Column(
      children: <Widget>[
        _LibraryBar(
          client: widget.client,
          onSaveAs: _saveAs,
          onLoad: (name) => widget.client.mixLoad(name),
          onDelete: (name) => widget.client.mixDelete(name),
        ),
        if (mix.running) MixRunBar(client: widget.client),
        Expanded(
          child: _cues.isEmpty
              ? _empty(context)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: _cues.length,
                  itemBuilder: (BuildContext c, int i) =>
                      _cueCard(c, i, devices),
                ),
        ),
        _bottomBar(context, mix),
      ],
    );
  }

  Widget _cueCard(BuildContext context, int i, List<DeviceState> devices) {
    final cue = _cues[i];
    final theme = Theme.of(context);
    final onAir = widget.client.mix.running && widget.client.mix.cueIndex == i;
    final cam = widget.client.bridge.deviceById(cue.cameraSn);
    final presets = cam?.presets ?? const <PresetEntry>[];
    return Card(
      key: cue.cardKey,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: onAir
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: onAir ? 2 : 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Row 1: index + program camera + reorder + delete.
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 12,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Text('${i + 1}', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.videocam,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: devices.any((d) => d.deviceId == cue.cameraSn)
                        ? cue.cameraSn
                        : devices.first.deviceId,
                    underline: const SizedBox.shrink(),
                    items: <DropdownMenuItem<String>>[
                      for (final d in devices)
                        DropdownMenuItem<String>(
                          value: d.deviceId,
                          child: Text(
                            d.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => cue.cameraSn = v);
                      _apply();
                    },
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: i > 0 ? () => _move(i, -1) : null,
                  icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                  tooltip: 'Move up',
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: i < _cues.length - 1 ? () => _move(i, 1) : null,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  tooltip: 'Move down',
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _removeAt(i),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove cue',
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Row 2: shot (preset or hold).
            Row(
              children: <Widget>[
                _fieldLabel(context, 'Shot'),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: cue.presetId,
                    underline: const SizedBox.shrink(),
                    items: <DropdownMenuItem<int>>[
                      const DropdownMenuItem<int>(
                        value: -1,
                        child: Text('Hold current shot'),
                      ),
                      for (final p in presets)
                        DropdownMenuItem<int>(
                          value: p.id,
                          child: Text(
                            'P${p.id + 1}${p.name.isEmpty ? '' : '  ${p.name}'}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => cue.presetId = v);
                      _apply();
                    },
                  ),
                ),
              ],
            ),
            // Row 3: move duration (only meaningful when moving to a preset).
            if (cue.presetId >= 0) ...<Widget>[
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  _fieldLabel(context, 'Move'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      children: <Widget>[
                        for (final choice in _moveChoices)
                          ChoiceChip(
                            label: Text(choice.$1),
                            visualDensity: VisualDensity.compact,
                            selected: cue.moveMs == choice.$2,
                            onSelected: (_) {
                              setState(() => cue.moveMs = choice.$2);
                              _apply();
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            // Row 4: hold seconds + transition.
            Row(
              children: <Widget>[
                _fieldLabel(context, 'Hold'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  child: TextField(
                    controller: cue.holdCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: const InputDecoration(
                      isDense: true,
                      suffixText: 's',
                    ),
                    onChanged: (t) {
                      final v = int.tryParse(t) ?? cue.holdS;
                      cue.holdS = v < 1 ? 1 : v;
                      _apply();
                    },
                  ),
                ),
                const Spacer(),
                _fieldLabel(context, 'Then'),
                const SizedBox(width: 8),
                _TransitionToggle(
                  value: cue.transition,
                  onChanged: (v) {
                    setState(() => cue.transition = v);
                    _apply();
                  },
                ),
              ],
            ),
            // Meanwhile (optional pre-position).
            _MeanwhileRow(
              cue: cue,
              devices: devices,
              client: widget.client,
              onChanged: () {
                setState(() {});
                _apply();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context, MixState mix) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          children: <Widget>[
            // Left cluster scrolls if cramped so the primary Run/Stop button
            // on the right is always reachable, even at 360px.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _addCue,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add cue'),
                    ),
                    const SizedBox(width: 8),
                    _ModeButton(
                      mode: _mode,
                      onChanged: (m) {
                        setState(() => _mode = m);
                        _apply();
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (mix.running)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onErrorContainer,
                ),
                onPressed: widget.client.mixStop,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stop'),
              )
            else
              FilledButton.icon(
                onPressed: _cues.isEmpty
                    ? null
                    : () {
                        _apply();
                        widget.client.mixStart();
                      },
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.movie_filter_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            'Build a cross-camera show',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Add cues to switch cameras and move them on air, hands-free.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );

  Widget _needsTwoCameras(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.videocam_off_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            'Mix needs two cameras',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Connect a second camera to build a cross-camera sequence. '
            'For one camera, use the per-camera sequence instead.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );

  Widget _fieldLabel(BuildContext context, String text) => SizedBox(
    width: 44,
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Cut / Fade selector. Fade is P4 - shown but disabled so the shape is
/// discoverable now and lights up when the bridge crossfade lands.
class _TransitionToggle extends StatelessWidget {
  const _TransitionToggle({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const <ButtonSegment<String>>[
        ButtonSegment<String>(value: 'cut', label: Text('Cut')),
        ButtonSegment<String>(
          value: 'fade',
          label: Text('Fade'),
          enabled: false,
        ),
      ],
      selected: <String>{value == 'fade' ? 'cut' : value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.onChanged});
  final String mode;
  final ValueChanged<String> onChanged;

  static const Map<String, (IconData, String)> _labels =
      <String, (IconData, String)>{
        'once': (Icons.looks_one_outlined, 'Once'),
        'forward': (Icons.repeat, 'Loop'),
        'ping_pong': (Icons.swap_horiz, 'Bounce'),
      };

  @override
  Widget build(BuildContext context) {
    final entry = _labels[mode] ?? _labels['forward']!;
    return OutlinedButton.icon(
      onPressed: () {
        const order = <String>['forward', 'once', 'ping_pong'];
        final next = order[(order.indexOf(mode) + 1) % order.length];
        onChanged(next);
      },
      icon: Icon(entry.$1, size: 18),
      label: Text(entry.$2),
    );
  }
}

class _MeanwhileRow extends StatelessWidget {
  const _MeanwhileRow({
    required this.cue,
    required this.devices,
    required this.client,
    required this.onChanged,
  });
  final _CueEdit cue;
  final List<DeviceState> devices;
  final WsClient client;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!cue.hasMeanwhile) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          onPressed: () {
            final other = devices.firstWhere(
              (d) => d.deviceId != cue.cameraSn,
              orElse: () => devices.first,
            );
            cue.mwSn = other.deviceId;
            cue.mwPresetId = 0;
            onChanged();
          },
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Pre-position another camera'),
        ),
      );
    }
    final mwCam = client.bridge.deviceById(cue.mwSn ?? '');
    final presets = mwCam?.presets ?? const <PresetEntry>[];
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.schedule,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text('Meanwhile', style: theme.textTheme.labelMedium),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              isDense: true,
              value: devices.any((d) => d.deviceId == cue.mwSn)
                  ? cue.mwSn
                  : devices.first.deviceId,
              underline: const SizedBox.shrink(),
              items: <DropdownMenuItem<String>>[
                for (final d in devices)
                  DropdownMenuItem<String>(
                    value: d.deviceId,
                    child: Text(d.displayName, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                cue.mwSn = v;
                onChanged();
              },
            ),
          ),
          const SizedBox(width: 6),
          DropdownButton<int>(
            isDense: true,
            value: cue.mwPresetId,
            underline: const SizedBox.shrink(),
            items: <DropdownMenuItem<int>>[
              for (final p in presets)
                DropdownMenuItem<int>(value: p.id, child: Text('P${p.id + 1}')),
            ],
            onChanged: (v) {
              if (v == null) return;
              cue.mwPresetId = v;
              onChanged();
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () {
              cue.mwSn = null;
              onChanged();
            },
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Remove pre-position',
          ),
        ],
      ),
    );
  }
}

class _LibraryBar extends StatelessWidget {
  const _LibraryBar({
    required this.client,
    required this.onSaveAs,
    required this.onLoad,
    required this.onDelete,
  });
  final WsClient client;
  final VoidCallback onSaveAs;
  final ValueChanged<String> onLoad;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final mix = client.mix;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.folder_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: mix.available.isEmpty
                  ? Text(
                      'No saved mixes',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : DropdownButton<String>(
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      hint: const Text('Load a mix'),
                      value: mix.loaded.isEmpty ? null : mix.loaded,
                      items: <DropdownMenuItem<String>>[
                        for (final name in mix.available)
                          DropdownMenuItem<String>(
                            value: name,
                            child: Text(name, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) onLoad(v);
                      },
                    ),
            ),
            if (mix.loaded.isNotEmpty)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: "Delete '${mix.loaded}'",
                onPressed: () => onDelete(mix.loaded),
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            TextButton.icon(
              onPressed: onSaveAs,
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('Save as'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Service-time run bar: the NOW cue, a progress bar, the NEXT cue, and Stop.
/// Glanceable - meant to sit at the top of the editor while the show runs.
class MixRunBar extends StatelessWidget {
  const MixRunBar({super.key, required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mix = client.mix;
    final idx = mix.cueIndex;
    final now = (idx >= 0 && idx < mix.cues.length) ? mix.cues[idx] : null;
    final nextIdx = mix.cues.isEmpty ? -1 : (idx + 1) % mix.cues.length;
    final next = (nextIdx >= 0 && nextIdx < mix.cues.length)
        ? mix.cues[nextIdx]
        : null;
    final moving = mix.phase == 'moving';
    final progress = mix.totalS > 0
        ? (mix.elapsedS / mix.totalS).clamp(0.0, 1.0)
        : 0.0;

    String label(MixCue? c) {
      if (c == null) return '-';
      final cam = client.bridge.deviceById(c.cameraSn)?.displayName ?? 'Camera';
      if (!c.hasPreset) return '$cam - hold';
      final p = client.bridge
          .deviceById(c.cameraSn)
          ?.presets
          .where((e) => e.id == c.presetId)
          .toList();
      final pname = (p != null && p.isNotEmpty && p.first.name.isNotEmpty)
          ? p.first.name
          : 'P${c.presetId + 1}';
      return '$cam - $pname';
    }

    return Material(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.28),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'ON AIR',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label(now),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  'cue ${idx + 1}/${mix.cueCount}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: moving ? null : progress,
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Icon(
                  moving ? Icons.open_with : Icons.timer_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  moving ? 'moving on air' : 'next: ${label(next)}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: client.mixStop,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
