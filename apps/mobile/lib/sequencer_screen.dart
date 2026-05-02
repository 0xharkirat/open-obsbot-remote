import 'package:flutter/material.dart';

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
  bool _loop = true;

  @override
  void initState() {
    super.initState();
    // Seed with one default step pointing at first preset if any.
    final s = widget.client.state;
    if (s.presets.isNotEmpty) {
      _steps.add(_EditStep(presetId: s.presets.first.id, seconds: 60));
    } else {
      _steps.add(_EditStep(presetId: 0, seconds: 60));
    }
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
    widget.client.sequenceSet(list, loop: _loop);
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
                          return _stepRow(c, i, s.presets, key: ValueKey(i.hashCode ^ _steps[i].hashCode));
                        },
                      ),
              ),
              SwitchListTile(
                title: const Text('Loop'),
                subtitle: const Text('Restart from step 1 when the last finishes'),
                value: _loop,
                onChanged: (v) => setState(() => _loop = v),
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
                        label: Text(running ? 'Stop' : 'Save & start'),
                        onPressed: running
                            ? _stop
                            : (_steps.isEmpty ? null : _start),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        );
      },
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
              child: Text(
                presets.where((p) => p.id == i).isNotEmpty
                    ? '${presets.firstWhere((p) => p.id == i).name.isEmpty ? "P${i + 1}" : presets.firstWhere((p) => p.id == i).name}'
                    : 'P${i + 1} (empty)',
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => step.presetId = v);
        },
      ),
      subtitle: Row(children: <Widget>[
        const Text('Hold for '),
        SizedBox(
          width: 70,
          child: TextField(
            controller: TextEditingController(text: '${step.seconds}'),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              suffixText: 's',
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
        onPressed: () => setState(() => _steps.removeAt(idx)),
      ),
    );
  }
}

class _EditStep {
  int presetId;
  int seconds;
  MoveSpeed speed;
  _EditStep({
    required this.presetId,
    required this.seconds,
    this.speed = MoveSpeed.medium,
  });
}
