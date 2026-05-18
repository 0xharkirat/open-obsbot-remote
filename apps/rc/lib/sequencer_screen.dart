import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets/sequence_progress_bar.dart';
import 'ws_client.dart';

/// Route wrapper around [SequencerEditor]. Used by Simple Mode and by the
/// v1.2 Sequence tab's "Open as full screen" path. The Sequence tab in
/// `tab_shell.dart` embeds [SequencerEditor] directly without a Scaffold.
class SequencerScreen extends StatelessWidget {
  final WsClient client;
  const SequencerScreen({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final loaded = client.state.sequence.loaded;
        return Scaffold(
          appBar: AppBar(title: Text(loaded.isEmpty ? 'Sequence' : loaded)),
          body: SafeArea(child: SequencerEditor(client: client)),
        );
      },
    );
  }
}

/// Edit a sequence of preset+duration steps and start/stop it.
/// Sequence runs on the bridge so it survives phone disconnect.
///
/// This widget owns the full editor surface: library bar, running bar,
/// reorderable step list, loop-mode selector, Add/Start/Stop/Apply row,
/// and the save-as flow. It is embedded by the v1.2 Sequence tab inside
/// `tab_shell.dart`, and by the [SequencerScreen] route wrapper for
/// Simple Mode.
class SequencerEditor extends StatefulWidget {
  final WsClient client;
  /// When `true`, show an inline top bar with the library dropdown +
  /// save-as button. Defaults to `true`. Route callers can pass `false`
  /// if they already provide an AppBar with those actions.
  final bool showTopBar;
  const SequencerEditor({
    super.key,
    required this.client,
    this.showTopBar = true,
  });

  @override
  State<SequencerEditor> createState() => _SequencerEditorState();
}

class _SequencerEditorState extends State<SequencerEditor> {
  final List<_EditStep> _steps = <_EditStep>[];
  LoopMode _mode = LoopMode.forward;
  String _lastHydratedFrom = '__none__';   // signature of state we last hydrated

  @override
  void initState() {
    super.initState();
    _hydrateFromState();
    widget.client.addListener(_onClientChange);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientChange);
    for (final s in _steps) {
      s.secondsCtrl.dispose();
    }
    super.dispose();
  }

  void _onClientChange() {
    // If the loaded sequence name changed (user picked a different one
    // from the library) OR the state's steps differ from ours, re-hydrate.
    final s = widget.client.state.sequence;
    final sig = '${s.loaded}::${s.mode}::${s.steps.length}::'
        '${s.steps.map((e) => "${e.presetId}/${e.seconds}/${e.transition.inMilliseconds}").join(",")}';
    if (sig != _lastHydratedFrom) {
      _hydrateFromState();
    }
  }

  void _hydrateFromState() {
    final s = widget.client.state;
    final seq = s.sequence;
    // Dispose old controllers before replacing.
    for (final st in _steps) {
      st.secondsCtrl.dispose();
    }
    _steps.clear();
    if (seq.steps.isNotEmpty) {
      // Bridge already has a scratch / loaded sequence  -  show it.
      for (final src in seq.steps) {
        _steps.add(_EditStep(
          presetId: src.presetId,
          seconds: src.seconds,
          transition: src.transition,
        ));
      }
      _mode = loopModeFromWire(seq.mode);
    } else {
      // Brand new  -  seed with one default step.
      final firstId = s.presets.isNotEmpty ? s.presets.first.id : 0;
      _steps.add(_EditStep(presetId: firstId, seconds: 60));
      _mode = LoopMode.forward;
    }
    _lastHydratedFrom = '${seq.loaded}::${seq.mode}::${seq.steps.length}::'
        '${seq.steps.map((e) => "${e.presetId}/${e.seconds}/${e.transition.inMilliseconds}").join(",")}';
    if (mounted) setState(() {});
  }

  void _addStep() {
    setState(() {
      _steps.add(
        _EditStep(
          presetId: _steps.isEmpty ? 0 : _steps.last.presetId,
          seconds: 60,
        ),
      );
    });
  }

  void _save() {
    final list = _steps
        .map(
          (e) => SequenceStep(
            presetId: e.presetId,
            seconds: e.seconds,
            transition: e.transition,
          ),
        )
        .toList();
    widget.client.sequenceSet(list, mode: _mode);
  }

  void _start() {
    _save();
    widget.client.sequenceStart();
  }

  void _stop() => widget.client.sequenceStop();

  Future<void> _saveAs(BuildContext ctx) async {
    final loaded = widget.client.state.sequence.loaded;
    final ctrl = TextEditingController(text: loaded);
    final name = await showDialog<String>(
      context: ctx,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Save sequence'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'e.g. Morning service, Vocalist rehearsal',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(null),
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
    final list = _steps
        .map(
          (e) => SequenceStep(
            presetId: e.presetId,
            seconds: e.seconds,
            transition: e.transition,
          ),
        )
        .toList();
    widget.client.sequenceSaveAs(name, list, mode: _mode);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.client,
      builder: (BuildContext context, _) {
        final s = widget.client.state;
        final running = s.sequence.running;
        return Column(
          children: <Widget>[
            if (widget.showTopBar) _libraryBar(context, s),
            if (running)
              SequenceProgressBar(
                client: widget.client,
              ),
            Expanded(
              child: _steps.isEmpty
                  ? const Center(
                      child: Text('Add steps to build a sequence'),
                    )
                  : ReorderableListView.builder(
                      itemCount: _steps.length,
                      onReorder: (oldI, newI) {
                        setState(() {
                          if (newI > oldI) newI -= 1;
                          final item = _steps.removeAt(oldI);
                          _steps.insert(newI, item);
                        });
                      },
                      itemBuilder: (BuildContext c, int i) {
                        // Stable key based on step identity, not index.
                        return _stepCard(
                          c,
                          i,
                          s.presets,
                          key: ValueKey<_EditStep>(_steps[i]),
                        );
                      },
                    ),
            ),
            _modeSelector(context),
            if (running)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  'Edits while running take effect at the next step boundary.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add step'),
                        onPressed: _addStep,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(running ? Icons.stop : Icons.play_arrow),
                        label: Text(
                          running
                              ? 'Stop'
                              : (s.sequence.running
                                    ? 'Apply changes'
                                    : 'Save & start'),
                        ),
                        onPressed: running
                            ? _stop
                            : (_steps.isEmpty ? null : _start),
                      ),
                    ),
                    if (running) ...<Widget>[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.save),
                          label: const Text('Apply'),
                          onPressed: _save,
                        ),
                      ),
                    ],
                    if (widget.showTopBar) ...<Widget>[
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: 'Save sequence as…',
                        icon: const Icon(Icons.bookmark_add_outlined),
                        onPressed: () => _saveAs(context),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _libraryBar(BuildContext ctx, CameraState s) {
    final theme = Theme.of(ctx);
    final lib = s.sequence.available;
    if (lib.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.bookmark_outline,
              size: 16,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No saved sequences yet  -  tap the bookmark to save this one.',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.bookmark, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              underline: const SizedBox.shrink(),
              value: s.sequence.loaded.isEmpty ? null : s.sequence.loaded,
              hint: const Text('Load saved sequence…'),
              items: <DropdownMenuItem<String>>[
                for (final n in lib)
                  DropdownMenuItem<String>(value: n, child: Text(n)),
              ],
              onChanged: (n) {
                if (n != null) widget.client.sequenceLoad(n);
              },
            ),
          ),
          if (s.sequence.loaded.isNotEmpty)
            IconButton(
              tooltip: 'Delete saved sequence',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (BuildContext c) => AlertDialog(
                    title: Text('Delete "${s.sequence.loaded}"?'),
                    content: const Text(
                      'This removes the saved sequence from the bridge. The current edit stays.',
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(c).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(c).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) widget.client.sequenceDelete(s.sequence.loaded);
              },
            ),
        ],
      ),
    );
  }

  /// On state events that include the loaded-sequence name + steps, sync
  /// the editor view. Called when user picks from the library dropdown.
  /// We compare what's loaded on bridge vs our local _steps; if different,
  /// rebuild from snapshot's presets/steps. The bridge persists the active
  /// scratch in sequence.json, but the LIST of steps comes via state.
  /// Currently the state event ships sequence.{step_index,total_s,...} but
  /// not the steps list per se  -  so we tolerate "load triggered" by
  /// listening for loaded_sequence change and pulling the current snapshot.

  Widget _modeSelector(BuildContext ctx) {
    final theme = Theme.of(ctx);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'When sequence reaches the end…',
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          for (final m in LoopMode.values)
            ListTile(
              dense: true,
              leading: Icon(
                _mode == m
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
              ),
              title: Text(
                loopModeLabel(m),
                style: const TextStyle(fontSize: 13),
              ),
              contentPadding: EdgeInsets.zero,
              onTap: () => setState(() => _mode = m),
            ),
        ],
      ),
    );
  }

  /// One step row in the sequencer editor.
  ///
  /// v1.4 fix B3: timing is split into two labelled fields so the
  /// operator can read move-time and stay-time independently. Pre-v1.4
  /// they shared one collapsed line and users misread "stay 40 s +
  /// move 30 s" as 40 s of wall-clock instead of 70 s. The trailing
  /// `≈ N s total` label gives the operator the wall-clock sum for
  /// the step (move + stay).
  Widget _stepCard(
    BuildContext ctx,
    int idx,
    List<PresetEntry> presets, {
    required Key key,
  }) {
    final step = _steps[idx];
    final theme = Theme.of(ctx);
    final cs = theme.colorScheme;
    final presetLabel = _presetLabel(step.presetId, presets);
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Header: drag handle, "Step N: <preset label>", delete.
              Row(
                children: <Widget>[
                  ReorderableDragStartListener(
                    index: idx,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle, color: cs.outline),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'Step ${idx + 1}: $presetLabel',
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete step',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() {
                        _steps[idx].secondsCtrl.dispose();
                        _steps.removeAt(idx);
                      });
                    },
                  ),
                ],
              ),
              // Preset picker: lets the operator change which preset this
              // step targets. Kept separate from the header text so the
              // header always reflects the resolved label.
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8),
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: step.presetId,
                  underline: const SizedBox.shrink(),
                  items: <DropdownMenuItem<int>>[
                    for (int i = 0; i < 6; i++)
                      DropdownMenuItem<int>(
                        value: i,
                        child: Text(_presetLabel(i, presets)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => step.presetId = v);
                  },
                ),
              ),
              const SizedBox(height: 6),
              // Move row: "Move to P_X over [ duration ]"
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.timeline, size: 14, color: cs.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Move to $presetLabel over',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    DropdownButton<int>(
                      value:
                          _snapTransitionMs(step.transition.inMilliseconds),
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: <DropdownMenuItem<int>>[
                        for (final p in kMoveDurationPresets)
                          DropdownMenuItem<int>(
                            value: p.duration.inMilliseconds,
                            child: Text(p.label.toLowerCase()),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => step.transition =
                              Duration(milliseconds: v));
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // Stay row: "Stay for [ N ] seconds"
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.timer_outlined, size: 14, color: cs.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Stay for',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 72,
                      child: TextField(
                        // KEY: stable controller per step, so cursor
                        // doesn't get wiped on every parent rebuild
                        // (CLAUDE.md note #15).
                        controller: step.secondsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          // Min 3 s (matches bridge contract); accept any
                          // larger value. If the user clears the field or
                          // types something < 3, the in-memory `seconds`
                          // stays at its last valid value, so the trailing
                          // total still reflects what'll be sent.
                          if (n != null && n >= 3 && n <= 36000) {
                            setState(() => step.seconds = n);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('seconds', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // Trailing total: "≈ N s total" (move + stay, wall-clock).
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatStepTotal(step),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.outline,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Format the wall-clock total for a step as an approximate label,
  /// e.g. `≈ 70 s total` or `≈ 250 s total`. Always rendered in
  /// seconds so the operator can mentally cross-check against the two
  /// input fields (Move duration in seconds + Stay seconds). Move
  /// duration is rounded to the nearest second.
  String _formatStepTotal(_EditStep step) {
    final moveS = (step.transition.inMilliseconds / 1000).round();
    final totalS = moveS + step.seconds;
    return '≈ $totalS s total';
  }

  String _presetLabel(int id, List<PresetEntry> presets) {
    final match = presets.where((p) => p.id == id);
    if (match.isEmpty) return 'P${id + 1} (empty)';
    final name = match.first.name;
    return name.isEmpty ? 'P${id + 1}' : name;
  }

  /// The Move-duration dropdown is bound to `kMoveDurationPresets`. Saved
  /// or legacy-migrated values (e.g. 2000 ms from v1.1 default, 22000 ms
  /// from `legacy_speed_to_ms("cinema")`) may not match any preset.
  /// Snap to the closest preset so the dropdown stays valid; the bridge
  /// accepts any ms count.
  int _snapTransitionMs(int ms) {
    int best = kMoveDurationPresets.first.duration.inMilliseconds;
    int bestDiff = (best - ms).abs();
    for (final p in kMoveDurationPresets) {
      final d = (p.duration.inMilliseconds - ms).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = p.duration.inMilliseconds;
      }
    }
    return best;
  }
}

class _EditStep {
  int presetId;
  int seconds;
  Duration transition;
  late TextEditingController secondsCtrl;
  _EditStep({
    required this.presetId,
    required this.seconds,
    this.transition = const Duration(milliseconds: 1000),
  }) {
    secondsCtrl = TextEditingController(text: '$seconds');
  }
}
