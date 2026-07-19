import 'package:meta/meta.dart';

/// One cue of a cross-camera MIX sequence: a SHOT, and how long to hold it.
///
/// As of 2.1 the camera is DERIVED, not authored. A crossfade dissolves between
/// two camera feeds, so every crossfade swaps which camera is live, so two
/// consecutive cues can never use the same camera. The bridge solves that (it is
/// graph 2-colouring) and hands back a [PlannedCue] per enabled cue.
///
/// The "meanwhile" - walking an idle camera to the shot it will next need - is
/// derived too. It was always exactly "the next cue that needs the other
/// camera", a pointer the operator was retyping on every single cue.
///
/// [pinSn] is the escape hatch: pin a cue to a camera and the solver colours
/// around it. It is also why pre-2.1 saved sequences still work - they named a
/// camera on every cue, so they arrive fully pinned and run verbatim.
@immutable
class MixCue {
  const MixCue({
    required this.presetId,
    this.holdS = 10,
    this.enabled = true,
    this.fadeMs = -1,
    this.moveMs = 0,
    this.pinSn,
  });

  factory MixCue.fromJson(Map<String, dynamic> j) {
    final sn = j['camera_sn'] as String?;
    return MixCue(
      presetId: (j['preset_id'] as num?)?.toInt() ?? -1,
      holdS: (j['hold_s'] as num?)?.toInt() ?? 10,
      enabled: j['enabled'] as bool? ?? true,
      fadeMs: (j['fade_ms'] as num?)?.toInt() ?? -1,
      moveMs: (j['move_ms'] as num?)?.toInt() ?? 0,
      pinSn: (sn == null || sn.isEmpty) ? null : sn,
    );
  }

  /// The shot. Slots 0..5 are P1..P6. A value < 0 holds the current framing.
  final int presetId;

  /// Seconds to dwell on the shot.
  final int holdS;

  /// A disabled cue is dropped from the plan entirely. The colouring and every
  /// derived meanwhile close over the hole - there is nothing to re-link.
  final bool enabled;

  /// Crossfade duration on arrival. Below 0 inherits the sequence default, 0 is
  /// a hard cut. Ignored where the solver had to make this an on-air pan: there
  /// is no second feed to dissolve into when the camera does not change.
  final int fadeMs;

  /// Pan duration, used only when a move lands on air.
  final int moveMs;

  /// Optional camera pin. Null or empty means "derive it".
  final String? pinSn;

  bool get hasPreset => presetId >= 0;
  bool get isPinned => pinSn != null && pinSn!.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'preset_id': presetId,
        'hold_s': holdS,
        'enabled': enabled,
        'fade_ms': fadeMs,
        'move_ms': moveMs,
        // A derived cue carries NO serial. That is what makes a saved sequence
        // portable: export it, import it elsewhere, and it still runs.
        if (isPinned) 'camera_sn': pinSn,
      };

  MixCue copyWith({
    int? presetId,
    int? holdS,
    bool? enabled,
    int? fadeMs,
    int? moveMs,
    String? pinSn,
    bool clearPin = false,
  }) {
    return MixCue(
      presetId: presetId ?? this.presetId,
      holdS: holdS ?? this.holdS,
      enabled: enabled ?? this.enabled,
      fadeMs: fadeMs ?? this.fadeMs,
      moveMs: moveMs ?? this.moveMs,
      pinSn: clearPin ? null : (pinSn ?? this.pinSn),
    );
  }
}

/// An idle camera being walked, off air, to the shot it will next be live on.
@immutable
class MeanwhileTarget {
  const MeanwhileTarget({required this.cameraSn, required this.presetId});

  factory MeanwhileTarget.fromJson(Map<String, dynamic> j) => MeanwhileTarget(
        cameraSn: j['camera_sn'] as String? ?? '',
        presetId: (j['preset_id'] as num?)?.toInt() ?? -1,
      );

  final String cameraSn;
  final int presetId;
}

/// What the bridge will actually DO for one enabled cue, after solving.
@immutable
class PlannedCue {
  const PlannedCue({
    required this.cueIndex,
    required this.cameraSn,
    required this.presetId,
    this.holdS = 10,
    this.fadeMs = 0,
    this.onAirMove = false,
    this.moveMs = 0,
    this.meanwhile = const <MeanwhileTarget>[],
  });

  factory PlannedCue.fromJson(Map<String, dynamic> j) {
    final mw = j['meanwhile'] as List<dynamic>?;
    return PlannedCue(
      cueIndex: (j['cue_index'] as num?)?.toInt() ?? -1,
      cameraSn: j['camera_sn'] as String? ?? '',
      presetId: (j['preset_id'] as num?)?.toInt() ?? -1,
      holdS: (j['hold_s'] as num?)?.toInt() ?? 10,
      fadeMs: (j['fade_ms'] as num?)?.toInt() ?? 0,
      onAirMove: j['on_air_move'] as bool? ?? false,
      moveMs: (j['move_ms'] as num?)?.toInt() ?? 0,
      meanwhile: mw == null
          ? const <MeanwhileTarget>[]
          : mw
              .whereType<Map<String, dynamic>>()
              .map(MeanwhileTarget.fromJson)
              .toList(growable: false),
    );
  }

  /// Index back into the AUTHORED cue list, so the UI can highlight the right
  /// card. With a disabled cue present this is NOT the plan index.
  final int cueIndex;

  /// The camera the solver picked, or the pin.
  final String cameraSn;
  final int presetId;
  final int holdS;
  final int fadeMs;

  /// True when the previous cue used the SAME camera, so there is no second feed
  /// to dissolve into and this move happens live, on air. In a two-camera
  /// forward loop that can only happen when the enabled cue count is ODD.
  final bool onAirMove;
  final int moveMs;

  /// One target per idle camera. Three cameras means two entries.
  final List<MeanwhileTarget> meanwhile;
}

/// The `mix` block of a v2 state event: live status, the authored cues, and the
/// SOLVED plan.
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
    this.plan = const <PlannedCue>[],
    this.planIndex = -1,
    this.forcedMoveAt = -1,
    this.forcedReason = '',
    this.warnings = const <String>[],
  });

  factory MixState.fromJson(Map<String, dynamic> j) {
    final cuesRaw = j['cues'] as List<dynamic>?;
    final planRaw = j['plan'] as List<dynamic>?;
    final availRaw = j['available'] as List<dynamic>?;
    final warnRaw = j['warnings'] as List<dynamic>?;
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
      plan: planRaw == null
          ? const <PlannedCue>[]
          : planRaw
              .whereType<Map<String, dynamic>>()
              .map(PlannedCue.fromJson)
              .toList(growable: false),
      planIndex: (j['plan_index'] as num?)?.toInt() ?? -1,
      forcedMoveAt: (j['forced_move_at'] as num?)?.toInt() ?? -1,
      forcedReason: j['forced_reason'] as String? ?? '',
      warnings: warnRaw == null
          ? const <String>[]
          : warnRaw.whereType<String>().toList(growable: false),
      available: availRaw == null
          ? const <String>[]
          : availRaw.whereType<String>().toList(growable: false),
    );
  }

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

  final bool running;

  /// Index of the AUTHORED cue currently on air, or -1 when idle.
  final int cueIndex;
  final int cueCount;

  /// "moving" while a live pan is in flight, "holding" while dwelling.
  final String phase;
  final int elapsedS;
  final int totalS;

  /// Loop mode: once | forward | ping_pong. Only `forward` wraps, so only
  /// `forward` is a cycle - which is exactly why ping-pong escapes the
  /// odd-cue-count problem.
  final String mode;

  /// Name of the loaded library entry, or '' for unsaved scratch.
  final String loaded;

  /// The authored cue list: shots and holds.
  final List<MixCue> cues;

  /// The solved plan: one entry per ENABLED cue, with the camera derived.
  final List<PlannedCue> plan;

  /// The raw run cursor into [plan] (enabled cues only), or -1 when idle.
  /// [cueIndex] is this mapped back to the authored list.
  final int planIndex;

  /// Index into [plan] whose arrival is a forced on-air pan, or -1 when the
  /// whole sequence is clean.
  final int forcedMoveAt;

  /// Plain-English reason the engine had to force that pan.
  final String forcedReason;

  /// Anything the operator should know before going live.
  final List<String> warnings;

  /// Saved mix names in the library.
  final List<String> available;

  /// True when every transition is a crossfade and nothing moves on screen.
  bool get isClean => forcedMoveAt < 0;

  /// The plan entry for an authored cue, or null when that cue is disabled.
  PlannedCue? planFor(int authoredIndex) {
    for (final p in plan) {
      if (p.cueIndex == authoredIndex) return p;
    }
    return null;
  }

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
    List<PlannedCue>? plan,
    int? planIndex,
    int? forcedMoveAt,
    String? forcedReason,
    List<String>? warnings,
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
      plan: plan ?? this.plan,
      planIndex: planIndex ?? this.planIndex,
      forcedMoveAt: forcedMoveAt ?? this.forcedMoveAt,
      forcedReason: forcedReason ?? this.forcedReason,
      warnings: warnings ?? this.warnings,
      available: available ?? this.available,
    );
  }
}
