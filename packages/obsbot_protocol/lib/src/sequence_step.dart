import 'package:meta/meta.dart';

/// One step in a sequence.
///
/// The bridge holds at the preset for [seconds] then animates the
/// gimbal + zoom to the next step's preset over [transition] (the
/// motion planner's `duration_ms`).
///
/// Wire format on `sequence.set` / `sequence.save_as`:
/// ```json
/// { "preset_id": 1, "seconds": 30, "transition_ms": 5000 }
/// ```
///
/// The bridge clamps `seconds` to a minimum of 3. The legacy v1.1
/// `speed: "instant" / "slow" / "medium" / "fast" / "cinema"` field
/// is still accepted on read for back-compat (mapped via
/// `legacy_speed_to_ms()` on the bridge side); new writers should
/// always emit `transition_ms`.
@immutable
class SequenceStep {
  /// Preset slot id (0..5 on Tiny 2 Lite).
  final int presetId;

  /// How long the camera holds at the preset before moving on.
  /// Minimum 3.
  final int seconds;

  /// How long the gimbal + zoom take to *reach* this step's preset
  /// from the previous step. `Duration.zero` means instant.
  final Duration transition;

  const SequenceStep({
    required this.presetId,
    required this.seconds,
    this.transition = const Duration(milliseconds: 2000),
  });

  factory SequenceStep.fromJson(Map<String, dynamic> j) => SequenceStep(
        presetId: (j['preset_id'] as num?)?.toInt() ?? 0,
        seconds: (j['seconds'] as num?)?.toInt() ?? 60,
        transition: Duration(
            milliseconds: (j['transition_ms'] as num?)?.toInt() ?? 0),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'preset_id': presetId,
        'seconds': seconds,
        'transition_ms': transition.inMilliseconds,
      };

  SequenceStep copyWith({
    int? presetId,
    int? seconds,
    Duration? transition,
  }) =>
      SequenceStep(
        presetId: presetId ?? this.presetId,
        seconds: seconds ?? this.seconds,
        transition: transition ?? this.transition,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SequenceStep &&
          presetId == other.presetId &&
          seconds == other.seconds &&
          transition == other.transition;

  @override
  int get hashCode => Object.hash(presetId, seconds, transition);
}
