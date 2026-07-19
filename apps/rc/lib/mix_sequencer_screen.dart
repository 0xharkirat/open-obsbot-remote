import 'dart:async';

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

/// An editable cue: a SHOT and a HOLD. That is all you author.
///
/// The camera and the "meanwhile" are DERIVED by the bridge's solver and come
/// back in `mix.plan`, so there is nothing here to type for either. The
/// meanwhile was only ever "the next cue that needs the other camera", which is
/// a pointer the engine already knows.
///
/// The hold-seconds controller is stable per cue: recreating it on every parent
/// rebuild kills the cursor (the sequencer's trap #15).
class _CueEdit {
  _CueEdit({
    this.presetId = -1,
    this.holdS = 15,
    this.enabled = true,
    this.fadeMs = 500,
    this.moveMs = 0,
    this.pinSn,
  }) : holdCtrl = TextEditingController(text: '$holdS'),
       cardKey = GlobalKey();

  factory _CueEdit.from(MixCue c) => _CueEdit(
    presetId: c.presetId,
    holdS: c.holdS,
    enabled: c.enabled,
    fadeMs: c.fadeMs,
    moveMs: c.moveMs,
    pinSn: c.pinSn,
  );

  int presetId; // < 0 = hold current shot
  int holdS;
  bool enabled; // disabled = dropped from the plan; the colouring re-solves
  int fadeMs; // crossfade on arrival. < 0 = default, 0 = hard cut.
  int moveMs; // only reachable on a forced on-air pan
  String? pinSn; // optional camera pin. null = derive.
  final TextEditingController holdCtrl;
  final GlobalKey cardKey;

  MixCue toCue() => MixCue(
    presetId: presetId,
    holdS: holdS,
    enabled: enabled,
    fadeMs: fadeMs,
    moveMs: moveMs,
    pinSn: pinSn,
  );

  void dispose() => holdCtrl.dispose();
}

/// Crossfade duration on ARRIVING at a cue. Per cue now: 500ms used to be the
/// only option in the whole engine.
const List<(String, int)> _fadeChoices = <(String, int)>[
  ('Cut', 0),
  ('0.3s', 300),
  ('0.5s', 500),
  ('1s', 1000),
  ('2s', 2000),
  ('3s', 3000),
];

/// On-air PAN duration. Only ever reachable on a cue the solver was forced to
/// make an on-air move, because everywhere else the camera was already walked
/// into place off air, so there is nothing to move.
///
/// Note this used to be labelled "Cut", which collided with the "In: Cut"
/// transition on the very same card. Two different meanings of one word.
const List<(String, int)> _moveChoices = <(String, int)>[
  ('Instant', 0),
  ('2s', 2000),
  ('5s', 5000),
  ('10s', 10000),
  ('30s', 30000),
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

  // Hold-seconds is debounced. Pushing a mix.set on every keystroke made the
  // bridge echo one state event per keypress, and _hydratedSig only remembers
  // the LATEST claim - so the echo for an earlier keystroke no longer matched,
  // tripped _hydrate(), and disposed the TextEditingController mid-typing. The
  // keyboard closed and reopened on every character (trap #15, second helping).
  // It also rewrote mix.json to disk once per keypress.
  Timer? _holdDebounce;

  @override
  void initState() {
    super.initState();
    _hydrate();
    widget.client.addListener(_onChange);
  }

  @override
  void dispose() {
    _holdDebounce?.cancel();
    widget.client.removeListener(_onChange);
    for (final c in _cues) {
      c.dispose();
    }
    super.dispose();
  }

  String _sigOf(List<MixCue> cues, String mode, String loaded) =>
      '$loaded::$mode::${cues.length}::'
      '${cues.map((c) => "${c.presetId}/${c.holdS}/${c.enabled}/${c.fadeMs}/${c.moveMs}/${c.pinSn ?? ''}").join(",")}';

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
    for (final src in m.cues) {
      _cues.add(_CueEdit.from(src));
    }
    // Sync mode unconditionally: with an empty cue list, leaving _mode stale
    // then adding the first cue would push the stale mode back over the bridge.
    _mode = m.mode;
    _hydratedSig = _sigOf(m.cues, m.mode, m.loaded);
    if (mounted) setState(() {});
  }

  List<MixCue> get _asCues => _cues.map((c) => c.toCue()).toList();

  void _apply() {
    // Claim the signature of what we're about to push so this local edit's
    // OWN state-event echo is recognised as ours and does NOT trigger a
    // _hydrate() - which would dispose the hold-seconds controller mid-keystroke
    // (trap #15). mix.set clears `loaded` to scratch, so anticipate loaded=''.
    _hydratedSig = _sigOf(_asCues, _mode, '');
    widget.client.mixSet(_asCues, _mode);
  }

  /// Coalesce a burst of keystrokes into a single push. See [_holdDebounce].
  void _applyDebounced() {
    _holdDebounce?.cancel();
    _holdDebounce = Timer(const Duration(milliseconds: 400), () {
      _holdDebounce = null;
      _apply();
    });
  }

  /// Cancel any debounced keystroke push and apply right now. Must run before
  /// anything that reads the cue list back from the BRIDGE (Run): the local
  /// list is ahead of the server until the debounce fires, and a stale timer
  /// left armed would otherwise push a mix.set into an already-running mix.
  void _flushPending() {
    _holdDebounce?.cancel();
    _holdDebounce = null;
    _apply();
  }

  void _addCue() {
    // No camera to pick: it is derived. You author a shot, the solver assigns
    // the camera so no two neighbours share one.
    setState(() => _cues.add(_CueEdit()));
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
    try {
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
    } finally {
      ctrl.dispose();
    }
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
    final mix = widget.client.mix;
    final onAir = mix.running && mix.cueIndex == i;

    // The solved view of this cue. null means it is disabled and therefore
    // absent from the plan entirely - the sequence steps straight over it.
    final PlannedCue? plan = mix.planFor(i);
    final DeviceState? derivedCam = plan == null
        ? null
        : widget.client.bridge.deviceById(plan.cameraSn);
    final bool forced = plan != null && plan.onAirMove;

    // Preset labels for the Shot dropdown. Prefer the camera the solver picked
    // (its names are the ones that will actually show), else any connected one:
    // every camera can reach every shot, and the slots are named alike.
    final presetSource =
        derivedCam ?? (devices.isNotEmpty ? devices.first : null);
    final presets = presetSource?.presets ?? const <PresetEntry>[];

    final Color border = onAir
        ? theme.colorScheme.primary
        : forced
        ? theme.colorScheme.tertiary
        : theme.colorScheme.outlineVariant;

    return Semantics(
      container: true,
      label: onAir
          ? 'On air'
          : cue.enabled
          ? null
          : 'Disabled, skipped',
      child: Opacity(
        opacity: cue.enabled ? 1 : 0.5,
        child: Card(
          key: cue.cardKey,
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: border, width: onAir ? 2 : 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Row 1: index + enable + DERIVED camera + reorder + delete.
                Row(
                  children: <Widget>[
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: onAir
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHighest,
                      child: Text(
                        '${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: onAir ? theme.colorScheme.onPrimary : null,
                        ),
                      ),
                    ),
                    // The enable toggle. A disabled cue is dropped from the run;
                    // the solver re-colours around the hole by itself.
                    Checkbox(
                      value: cue.enabled,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) {
                        setState(() => cue.enabled = v ?? true);
                        _apply();
                      },
                    ),
                    Expanded(
                      child: _derivedCameraChip(context, cue, plan, forced),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: i > 0 ? () => _move(i, -1) : null,
                      icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                      tooltip: 'Move up',
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: i < _cues.length - 1
                          ? () => _move(i, 1)
                          : null,
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
                // Row 2: shot (preset or hold).
                Row(
                  children: <Widget>[
                    _fieldLabel(context, 'Shot'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value:
                            (cue.presetId < 0 ||
                                presets.any((p) => p.id == cue.presetId))
                            ? cue.presetId
                            : -1,
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
                const SizedBox(height: 6),
                // Row 3: hold seconds, then EITHER the crossfade duration (the
                // normal case) OR the on-air pan duration (only when the solver
                // was forced to move this cue live - there is no crossfade then).
                Row(
                  children: <Widget>[
                    _fieldLabel(context, 'Hold'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 60,
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
                          _applyDebounced();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    _fieldLabel(context, forced ? 'Pan' : 'Fade'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: forced
                          ? _chips(_moveChoices, cue.moveMs, (v) {
                              setState(() => cue.moveMs = v);
                              _apply();
                            })
                          : _chips(
                              _fadeChoices,
                              cue.fadeMs < 0 ? 500 : cue.fadeMs,
                              (v) {
                                setState(() => cue.fadeMs = v);
                                _apply();
                              },
                            ),
                    ),
                  ],
                ),
                if (forced) _forcedNote(context, mix),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A read-only chip showing the camera the solver assigned, plus the derived
  /// meanwhile ("while this holds, the other camera walks to X"). This is the
  /// pointer the operator used to type by hand - now it is just reported.
  Widget _derivedCameraChip(
    BuildContext context,
    _CueEdit cue,
    PlannedCue? plan,
    bool forced,
  ) {
    final theme = Theme.of(context);
    if (!cue.enabled) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          'Skipped',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }
    final camName = plan == null
        ? 'camera pending'
        : (widget.client.bridge.deviceById(plan.cameraSn)?.displayName ??
              plan.cameraSn);
    String sub = '';
    if (plan != null && plan.meanwhile.isNotEmpty) {
      final names = plan.meanwhile
          .map((m) {
            final d = widget.client.bridge.deviceById(m.cameraSn);
            return d?.displayName ?? m.cameraSn;
          })
          .join(', ');
      sub = 'meanwhile $names repositions';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                forced ? Icons.pan_tool_alt : Icons.videocam,
                size: 15,
                color: forced
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  camName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'auto',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          if (sub.isNotEmpty)
            Text(
              sub,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
    );
  }

  /// A small selectable-chip row. Shared by Fade and Pan duration.
  Widget _chips(
    List<(String, int)> choices,
    int value,
    ValueChanged<int> onPick,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      children: <Widget>[
        for (final c in choices)
          ChoiceChip(
            label: Text(c.$1),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            selected: value == c.$2,
            onSelected: (_) => onPick(c.$2),
          ),
      ],
    );
  }

  /// The banner an odd loop earns: the solver had to make one transition an
  /// on-air pan, and it says so instead of quietly showing a move.
  Widget _forcedNote(BuildContext context, MixState mix) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.pan_tool_alt,
            size: 16,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This one pans on air. An odd number of steps cannot alternate '
              'two cameras, so one move must show. Switch to ping-pong, or '
              'add/disable a step, to hide it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
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
                        _flushPending();
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
                      // Guard against another client deleting the loaded mix:
                      // a `loaded` absent from `available` would assert.
                      value: mix.available.contains(mix.loaded)
                          ? mix.loaded
                          : null,
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
    // "Now" and "next" come from the SOLVED plan (which carries the derived
    // camera), not the authored cues (which no longer name one). mix.cueIndex
    // is the authored index of the live cue, so find its position in the plan.
    final plan = mix.plan;
    int pos = -1;
    for (int k = 0; k < plan.length; k++) {
      if (plan[k].cueIndex == mix.cueIndex) {
        pos = k;
        break;
      }
    }
    final now = (pos >= 0) ? plan[pos] : null;
    final next = plan.isEmpty ? null : plan[(pos + 1) % plan.length];
    final moving = mix.phase == 'moving';
    final progress = mix.totalS > 0
        ? (mix.elapsedS / mix.totalS).clamp(0.0, 1.0)
        : 0.0;

    String label(PlannedCue? c) {
      if (c == null) return '-';
      final cam = client.bridge.deviceById(c.cameraSn)?.displayName ?? 'Camera';
      if (c.presetId < 0) return '$cam - hold';
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

    // liveRegion so a screen reader announces the cut when the program
    // switches cameras or the phase flips to "moving on air".
    return Semantics(
      liveRegion: true,
      child: Material(
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
                    // Position within the PLAN (enabled cues), clamped so the
                    // transient start window never shows "cue 0/0".
                    'cue ${pos < 0 ? 1 : pos + 1}/${plan.length}',
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
      ),
    );
  }
}
