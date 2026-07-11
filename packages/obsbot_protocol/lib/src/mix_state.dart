import 'package:meta/meta.dart';

/// One cue of a cross-camera MIX sequence (the P3 mixer).
///
/// A cue names which camera goes on air ([cameraSn] -> program) and what shot
/// it takes ([presetId]). There is deliberately NO on-air movement lock: when
/// a cue recalls a preset on the program camera, that camera moves LIVE on air
/// - a real-cameraman push/pan is the whole point of a PTZ. [presetId] < 0
/// means "hold the current shot" (cut to the camera without moving it); slots
/// 0..5 are real presets P1..P6.
///
/// [meanwhile] (via [mwSn]) optionally pre-positions a SECOND camera to a
/// preset while this cue holds, so it is framed before a later cue cuts to it.
@immutable
class MixCue {
  const MixCue({
    required this.cameraSn,
    this.presetId = -1,
    this.moveMs = 0,
    this.holdS = 10,
    this.transition = 'cut',
    this.mwSn,
    this.mwPresetId = 0,
    this.mwMoveMs = 0,
  });

  /// Program camera for this cue.
  final String cameraSn;

  /// Preset to recall on the program camera. < 0 = hold current shot.
  /// Slots 0..5 (P1..P6) are all real presets, so the hold sentinel is
  /// negative, not 0.
  final int presetId;

  /// True when this cue moves the program camera to a preset (vs. hold).
  bool get hasPreset => presetId >= 0;

  /// Live move duration in ms (0 = instant snap).
  final int moveMs;

  /// Seconds to dwell after the move lands.
  final int holdS;

  /// Transition to the NEXT cue: "cut" now, "fade" arrives in P4.
  final String transition;

  /// Meanwhile: pre-position this second camera (null = no pre-position).
  final String? mwSn;
  final int mwPresetId;
  final int mwMoveMs;

  bool get hasMeanwhile => mwSn != null && mwSn!.isNotEmpty;

  factory MixCue.fromJson(Map<String, dynamic> j) {
    final mw = j['meanwhile'];
    return MixCue(
      cameraSn: j['camera_sn'] as String? ?? '',
      presetId: (j['preset_id'] as num?)?.toInt() ?? -1,
      moveMs: (j['move_ms'] as num?)?.toInt() ?? 0,
      holdS: (j['hold_s'] as num?)?.toInt() ?? 10,
      transition: j['transition'] as String? ?? 'cut',
      mwSn: mw is Map<String, dynamic> ? mw['camera_sn'] as String? : null,
      mwPresetId: mw is Map<String, dynamic>
          ? (mw['preset_id'] as num?)?.toInt() ?? 0
          : 0,
      mwMoveMs: mw is Map<String, dynamic>
          ? (mw['move_ms'] as num?)?.toInt() ?? 0
          : 0,
    );
  }

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{
      'camera_sn': cameraSn,
      'preset_id': presetId,
      'move_ms': moveMs,
      'hold_s': holdS,
      'transition': transition,
    };
    if (hasMeanwhile) {
      j['meanwhile'] = <String, dynamic>{
        'camera_sn': mwSn,
        'preset_id': mwPresetId,
        'move_ms': mwMoveMs,
      };
    }
    return j;
  }

  MixCue copyWith({
    String? cameraSn,
    int? presetId,
    int? moveMs,
    int? holdS,
    String? transition,
    String? mwSn,
    int? mwPresetId,
    int? mwMoveMs,
    bool clearMeanwhile = false,
  }) {
    return MixCue(
      cameraSn: cameraSn ?? this.cameraSn,
      presetId: presetId ?? this.presetId,
      moveMs: moveMs ?? this.moveMs,
      holdS: holdS ?? this.holdS,
      transition: transition ?? this.transition,
      mwSn: clearMeanwhile ? null : (mwSn ?? this.mwSn),
      mwPresetId: clearMeanwhile ? 0 : (mwPresetId ?? this.mwPresetId),
      mwMoveMs: clearMeanwhile ? 0 : (mwMoveMs ?? this.mwMoveMs),
    );
  }
}

/// The `mix` block of a v2 state event: the live status of the cross-camera
/// sequencer plus its scratch cues and saved-library names.
@immutable
class MixState {
  const MixState({
    required this.running,
    required this.cueIndex,
    required this.cueCount,
    required this.phase,
    required this.elapsedS,
    required this.totalS,
    required this.mode,
    required this.loaded,
    required this.cues,
    required this.available,
  });

  /// True while the mix engine is running.
  final bool running;

  /// Index of the cue on air, or -1 when idle.
  final int cueIndex;
  final int cueCount;

  /// "moving" while the live move is in flight, "holding" while dwelling.
  final String phase;
  final int elapsedS;
  final int totalS;

  /// Loop mode: once | forward | ping_pong.
  final String mode;

  /// Name of the loaded library entry, or '' for unsaved scratch.
  final String loaded;

  /// The authored cue list (scratch).
  final List<MixCue> cues;

  /// Saved mix names in the library.
  final List<String> available;

  static const empty = MixState(
    running: false,
    cueIndex: -1,
    cueCount: 0,
    phase: 'holding',
    elapsedS: 0,
    totalS: 0,
    mode: 'forward',
    loaded: '',
    cues: <MixCue>[],
    available: <String>[],
  );

  MixState copyWith({
    bool? running,
    int? cueIndex,
    int? cueCount,
    String? phase,
    int? elapsedS,
    int? totalS,
    String? mode,
    String? loaded,
    List<MixCue>? cues,
    List<String>? available,
  }) {
    return MixState(
      running: running ?? this.running,
      cueIndex: cueIndex ?? this.cueIndex,
      cueCount: cueCount ?? this.cueCount,
      phase: phase ?? this.phase,
      elapsedS: elapsedS ?? this.elapsedS,
      totalS: totalS ?? this.totalS,
      mode: mode ?? this.mode,
      loaded: loaded ?? this.loaded,
      cues: cues ?? this.cues,
      available: available ?? this.available,
    );
  }

  factory MixState.fromJson(Map<String, dynamic> j) {
    final cuesRaw = j['cues'] as List<dynamic>?;
    final availRaw = j['available'] as List<dynamic>?;
    return MixState(
      running: j['running'] as bool? ?? false,
      cueIndex: (j['cue_index'] as num?)?.toInt() ?? -1,
      cueCount: (j['cue_count'] as num?)?.toInt() ?? 0,
      phase: j['phase'] as String? ?? 'holding',
      elapsedS: (j['elapsed_s'] as num?)?.toInt() ?? 0,
      totalS: (j['total_s'] as num?)?.toInt() ?? 0,
      mode: j['mode'] as String? ?? 'forward',
      loaded: j['loaded'] as String? ?? '',
      cues: cuesRaw == null
          ? const <MixCue>[]
          : cuesRaw
              .whereType<Map<String, dynamic>>()
              .map(MixCue.fromJson)
              .toList(growable: false),
      available: availRaw == null
          ? const <String>[]
          : availRaw.whereType<String>().toList(growable: false),
    );
  }
}
