import 'package:meta/meta.dart';

import 'record_mode.dart';

/// The bridge's recording status. Bridge-global: one recording at a time,
/// like `active_device_id`.
///
/// Recording is host-side. The Tiny 2 Lite has no storage, and every record
/// method in the SDK is annotated for the Tail Air, so the bridge writes the
/// file. See `docs/RECORDING_PROTOCOL.md`.
///
/// [elapsedS] is authoritative from the bridge rather than counted here. A
/// phone that reconnects mid-take must show the true elapsed time, not start
/// again from zero, and an operator watching the clock is the whole reason
/// the number is on screen.
@immutable
class RecordingState {
  const RecordingState({
    this.active = false,
    this.deviceId = '',
    this.startedAtMs = 0,
    this.elapsedS = 0,
    this.bytes = 0,
    this.path = '',
    this.audio = false,
    this.video = false,
    this.mode = RecordMode.both,
    this.audioAvailable = false,
    this.diskFreeBytes = 0,
    this.error = '',
  });

  factory RecordingState.fromJson(Map<String, dynamic> j) {
    return RecordingState(
      active: j['active'] as bool? ?? false,
      deviceId: j['device_id'] as String? ?? '',
      startedAtMs: (j['started_at_ms'] as num?)?.toInt() ?? 0,
      elapsedS: (j['elapsed_s'] as num?)?.toInt() ?? 0,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      path: j['path'] as String? ?? '',
      audio: j['audio'] as bool? ?? false,
      video: j['video'] as bool? ?? false,
      mode: RecordMode.fromWire(j['mode'] as String?),
      audioAvailable: j['audio_available'] as bool? ?? false,
      diskFreeBytes: (j['disk_free_bytes'] as num?)?.toInt() ?? 0,
      error: j['error'] as String? ?? '',
    );
  }

  /// A bridge that predates recording sends no `recording` block at all.
  static const empty = RecordingState();

  /// True while a file is being written.
  final bool active;

  /// Camera being recorded. Defaults to whatever was on air at start, so it
  /// can differ from the camera this phone has staged.
  final String deviceId;

  /// Wall clock at start, so a client that joins late can still show when
  /// the take began rather than only how long it has run.
  final int startedAtMs;

  /// Seconds elapsed, counted by the bridge. Never derive this locally.
  final int elapsedS;

  /// Bytes written so far.
  final int bytes;

  /// Absolute path on the bridge host.
  final String path;

  /// Whether an audio track is actually being written. False after a
  /// downgrade: asking for audio when the camera exposes no capture device
  /// starts a silent recording rather than refusing the take.
  final bool audio;

  /// Whether THIS take is writing a video track.
  final bool video;

  /// What the NEXT take will capture. The operator's preference, set by
  /// `record.set_mode`, distinct from [video] and [audio] which are what the
  /// current take is actually doing. They disagree after a downgrade:
  /// [RecordMode.both] with no microphone gives `video: true, audio: false`.
  ///
  /// Deliberately not a camera setting and deliberately not per-device.
  /// `cameraSetAudioCtrlStateU` looks like a microphone control and is not:
  /// its enum is voice commands, so it configures what the camera does when
  /// spoken to. There is no way to mute this microphone through the SDK, so
  /// the only honest meaning is what the recorder writes, and the recorder is
  /// bridge-global.
  final RecordMode mode;

  /// Whether a microphone exists at all. False makes the audio control
  /// inert rather than absent: a control that vanishes leaves the operator
  /// wondering whether they missed it.
  final bool audioAvailable;

  /// Free space on the volume holding [path].
  final int diskFreeBytes;

  /// Non-empty means the recording died mid-take. Sticky until the next
  /// start, because a take that stopped silently is the worst outcome here
  /// and a message that clears itself is a message nobody read.
  final String error;

  /// True when the last take ended badly and nothing has started since.
  bool get failed => !active && error.isNotEmpty;

  /// `1:04:12` past an hour, `04:12` below it. Padded so the digits do not
  /// change width as the take runs.
  String get elapsedLabel {
    final s = elapsedS < 0 ? 0 : elapsedS;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  RecordingState copyWith({
    bool? active,
    String? deviceId,
    int? startedAtMs,
    int? elapsedS,
    int? bytes,
    String? path,
    bool? audio,
    bool? video,
    RecordMode? mode,
    bool? audioAvailable,
    int? diskFreeBytes,
    String? error,
  }) {
    return RecordingState(
      active: active ?? this.active,
      deviceId: deviceId ?? this.deviceId,
      startedAtMs: startedAtMs ?? this.startedAtMs,
      elapsedS: elapsedS ?? this.elapsedS,
      bytes: bytes ?? this.bytes,
      path: path ?? this.path,
      audio: audio ?? this.audio,
      video: video ?? this.video,
      mode: mode ?? this.mode,
      audioAvailable: audioAvailable ?? this.audioAvailable,
      diskFreeBytes: diskFreeBytes ?? this.diskFreeBytes,
      error: error ?? this.error,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'active': active,
    'device_id': deviceId,
    'started_at_ms': startedAtMs,
    'elapsed_s': elapsedS,
    'bytes': bytes,
    'path': path,
    'audio': audio,
    'video': video,
    'mode': mode.wire,
    'audio_available': audioAvailable,
    'disk_free_bytes': diskFreeBytes,
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is RecordingState &&
      other.active == active &&
      other.deviceId == deviceId &&
      other.startedAtMs == startedAtMs &&
      other.elapsedS == elapsedS &&
      other.bytes == bytes &&
      other.path == path &&
      other.audio == audio &&
      other.video == video &&
      other.mode == mode &&
      other.audioAvailable == audioAvailable &&
      other.diskFreeBytes == diskFreeBytes &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    active,
    deviceId,
    startedAtMs,
    elapsedS,
    bytes,
    path,
    audio,
    video,
    mode,
    audioAvailable,
    diskFreeBytes,
    error,
  );
}
