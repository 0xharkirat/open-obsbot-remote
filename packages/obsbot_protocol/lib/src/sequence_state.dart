import 'package:meta/meta.dart';

import 'sequence_step.dart';

/// Sequencer state pushed by the bridge inside the `state` event.
///
/// Mirrors the `sequence` block:
/// ```json
/// {
///   "running": false,
///   "step_index": -1,
///   "elapsed_s": 0,
///   "total_s": 0,
///   "mode": "forward",
///   "phase": "holding",
///   "available": ["Main"],
///   "loaded": "Main",
///   "steps": [{ "preset_id": 0, "seconds": 30, "transition_ms": 5000 }]
/// }
/// ```
@immutable
class SequenceState {
  /// True while the bridge sequence thread is running.
  final bool running;

  /// 0-based index of the current step. `-1` when idle.
  final int stepIndex;

  /// Wall-clock seconds elapsed in the current step.
  final int elapsedS;

  /// Total length of the current step (`seconds + transition_ms / 1000`).
  final int totalS;

  /// Names of saved sequences in the bridge library.
  final List<String> available;

  /// Name of the currently loaded sequence, or empty for an
  /// unsaved scratch.
  final String loaded;

  /// Loop mode wire string (`once` / `forward` / `ping_pong`).
  /// Use `loopModeFromWire` to decode.
  final String mode;

  /// Active sub-phase of the current step. `"moving"` while the
  /// MotionPlanner is physically driving toward the step's pose;
  /// `"holding"` while the stay-timer is counting down. Idle and
  /// instant-transition steps report `"holding"`.
  final String phase;

  /// Active edit list. Mirrored from the bridge so a returning
  /// client can hydrate the editor without re-fetching.
  final List<SequenceStep> steps;

  const SequenceState({
    required this.running,
    required this.stepIndex,
    required this.elapsedS,
    required this.totalS,
    required this.available,
    required this.loaded,
    required this.mode,
    required this.phase,
    required this.steps,
  });

  static const empty = SequenceState(
    running: false,
    stepIndex: -1,
    elapsedS: 0,
    totalS: 0,
    available: <String>[],
    loaded: '',
    mode: 'forward',
    phase: 'holding',
    steps: <SequenceStep>[],
  );

  factory SequenceState.fromJson(Map<String, dynamic> j) {
    final stepsRaw = (j['steps'] as List<dynamic>?) ?? const <dynamic>[];
    final steps = stepsRaw
        .whereType<Map<String, dynamic>>()
        .map(SequenceStep.fromJson)
        .toList(growable: false);
    return SequenceState(
      running: j['running'] as bool? ?? false,
      stepIndex: (j['step_index'] as num?)?.toInt() ?? -1,
      elapsedS: (j['elapsed_s'] as num?)?.toInt() ?? 0,
      totalS: (j['total_s'] as num?)?.toInt() ?? 0,
      available: ((j['available'] as List<dynamic>?) ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      loaded: j['loaded'] as String? ?? '',
      mode: j['mode'] as String? ?? 'forward',
      phase: j['phase'] as String? ?? 'holding',
      steps: steps,
    );
  }
}
