import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ws_client.dart';

/// Edit a sequence of preset+duration steps and start/stop it.
/// Sequence runs on the bridge so it survives phone disconnect.
class SequencerScreen extends StatefulWidget {
  final WsClient client;
  const SequencerScreen({super.key, required this.client});

  @override
  State<SequencerScreen> createState() => _SequencerScreenState();
}

class _SequencerScreenState extends State<SequencerScreen> {
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
        '${s.steps.map((e) => "${e.presetId}/${e.seconds}/${moveSpeedToWire(e.speed)}").join(",")}';
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
      // Bridge already has a scratch / loaded sequence — show it.
      for (final src in seq.steps) {
        _steps.add(_EditStep(
          presetId: src.presetId,
          seconds: src.seconds,
          speed: src.speed,
        ));
      }
      _mode = loopModeFromWire(seq.mode);
    } else {
      // Brand new — seed with one default step.
      final firstId = s.presets.isNotEmpty ? s.presets.first.id : 0;
      _steps.add(_EditStep(presetId: firstId, seconds: 60));
      _mode = LoopMode.forward;
    }
    _lastHydratedFrom = '${seq.loaded}::${seq.mode}::${seq.steps.length}::'
        '${seq.steps.map((e) => "${e.presetId}/${e.seconds}/${moveSpeedToWire(e.speed)}").join(",")}';
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
            speed: e.speed,
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
            speed: e.speed,
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
        return Scaffold(
          appBar: AppBar(
            title: Text(
              s.sequence.loaded.isEmpty ? 'Sequence' : s.sequence.loaded,
            ),
            actions: <Widget>[
              IconButton(
                tooltip: 'Save sequence as…',
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: () => _saveAs(context),
              ),
              if (running)
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop_circle),
                  onPressed: _stop,
                )
              else
                IconButton(
                  tooltip: 'Start',
                  icon: const Icon(Icons.play_circle),
                  onPressed: _steps.isEmpty ? null : _start,
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                _libraryBar(context, s),
                if (running) _runningBar(context, s),
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
                            return _stepRow(
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
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                'No saved sequences yet — tap the bookmark to save this one.',
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
  /// not the steps list per se — so we tolerate "load triggered" by
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

  Widget _runningBar(BuildContext ctx, CameraState s) {
    final theme = Theme.of(ctx);
    final pct = s.sequence.totalS == 0
        ? 0.0
        : (s.sequence.elapsedS / s.sequence.totalS).clamp(0.0, 1.0);
    final remaining = (s.sequence.totalS - s.sequence.elapsedS).clamp(0, 9999);
    return Container(
      padding: const EdgeInsets.all(12),
      color: theme.colorScheme.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Step ${s.sequence.stepIndex + 1} of ${_steps.length} — ${remaining}s left',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: pct, minHeight: 6),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(
    BuildContext ctx,
    int idx,
    List<PresetEntry> presets, {
    required Key key,
  }) {
    final step = _steps[idx];
    return ListTile(
      key: key,
      leading: ReorderableDragStartListener(
        index: idx,
        child: const Icon(Icons.drag_handle),
      ),
      title: DropdownButton<int>(
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
      subtitle: Row(
        children: <Widget>[
          const Text('Hold for '),
          SizedBox(
            width: 80,
            child: TextField(
              // KEY: stable controller per step, so cursor doesn't get
              // wiped on every parent rebuild.
              controller: step.secondsCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(
                isDense: true,
                suffixText: 's',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 3 && n <= 36000) step.seconds = n;
              },
            ),
          ),
          const SizedBox(width: 12),
          const Text('move '),
          DropdownButton<MoveSpeed>(
            value: step.speed,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: <DropdownMenuItem<MoveSpeed>>[
              for (final s in MoveSpeed.values)
                DropdownMenuItem<MoveSpeed>(
                  value: s,
                  child: Text(moveSpeedLabel(s).toLowerCase()),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => step.speed = v);
            },
          ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () {
          setState(() {
            _steps[idx].secondsCtrl.dispose();
            _steps.removeAt(idx);
          });
        },
      ),
    );
  }

  String _presetLabel(int id, List<PresetEntry> presets) {
    final match = presets.where((p) => p.id == id);
    if (match.isEmpty) return 'P${id + 1} (empty)';
    final name = match.first.name;
    return name.isEmpty ? 'P${id + 1}' : name;
  }
}

class _EditStep {
  int presetId;
  int seconds;
  MoveSpeed speed;
  late TextEditingController secondsCtrl;
  _EditStep({
    required this.presetId,
    required this.seconds,
    this.speed = MoveSpeed.medium,
  }) {
    secondsCtrl = TextEditingController(text: '$seconds');
  }
}
