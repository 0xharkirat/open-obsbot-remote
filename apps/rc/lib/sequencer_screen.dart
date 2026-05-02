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

  @override
  void initState() {
    super.initState();
    final s = widget.client.state;
    if (s.presets.isNotEmpty) {
      _steps.add(_EditStep(presetId: s.presets.first.id, seconds: 60));
    } else {
      _steps.add(_EditStep(presetId: 0, seconds: 60));
    }
  }

  @override
  void dispose() {
    for (final s in _steps) {
      s.secondsCtrl.dispose();
    }
    super.dispose();
  }

  void _addStep() {
    setState(() {
      _steps.add(_EditStep(
        presetId: _steps.isEmpty ? 0 : _steps.last.presetId,
        seconds: 60,
      ));
    });
  }

  void _save() {
    final list = _steps
        .map((e) => SequenceStep(
              presetId: e.presetId,
              seconds: e.seconds,
              speed: e.speed,
            ))
        .toList();
    widget.client.sequenceSet(list, mode: _mode);
  }

  void _start() {
    _save();
    widget.client.sequenceStart();
  }

  void _stop() => widget.client.sequenceStop();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.client,
      builder: (BuildContext context, _) {
        final s = widget.client.state;
        final running = s.sequence.running;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Sequence'),
            actions: <Widget>[
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
            child: Column(children: <Widget>[
              if (running) _runningBar(context, s),
              Expanded(
                child: _steps.isEmpty
                    ? const Center(
                        child: Text('Add steps to build a sequence'))
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
                          return _stepRow(c, i, s.presets,
                              key: ValueKey<_EditStep>(_steps[i]));
                        },
                      ),
              ),
              _modeSelector(context),
              if (running)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                  child: Row(children: <Widget>[
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
                        label: Text(running
                            ? 'Stop'
                            : (s.sequence.running
                                ? 'Apply changes'
                                : 'Save & start')),
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
                  ]),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

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
          Text('When sequence reaches the end…',
              style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          for (final m in LoopMode.values)
            RadioListTile<LoopMode>(
              dense: true,
              value: m,
              groupValue: _mode,
              onChanged: (v) {
                if (v != null) setState(() => _mode = v);
              },
              title: Text(loopModeLabel(m), style: const TextStyle(fontSize: 13)),
              contentPadding: EdgeInsets.zero,
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
          Text('Step ${s.sequence.stepIndex + 1} of ${_steps.length} — ${remaining}s left',
              style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: pct, minHeight: 6),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(BuildContext ctx, int idx, List<PresetEntry> presets,
      {required Key key}) {
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
      subtitle: Row(children: <Widget>[
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
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
      ]),
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
