import 'package:meta/meta.dart';

/// A camera's microphone, per device.
///
/// Three states, not two. [available] is whether the camera exposes a capture
/// device at all; [enabled] is the SDK setting. A UI that collapses these into
/// one switch has to either lie about a camera with no microphone or hide the
/// control, and a control that vanishes is worse than one that explains itself.
///
/// `cameraSetAudioCtrlStateU` and `cameraSetAudioAutoGainU` are both tagged
/// `tiny2 series` in the SDK header, so these do work on the tested model. The
/// video path carries no audio, so a recording with sound means the bridge
/// captures the camera's USB audio interface separately and muxes it.
@immutable
class AudioState {
  const AudioState({
    this.available = false,
    this.enabled = false,
    this.autoGain = true,
  });

  factory AudioState.fromJson(Map<String, dynamic> j) {
    return AudioState(
      available: j['available'] as bool? ?? false,
      enabled: j['enabled'] as bool? ?? false,
      autoGain: j['auto_gain'] as bool? ?? true,
    );
  }

  /// What a bridge that predates the audio block reports: no microphone
  /// known, so the control renders disabled rather than falsely on.
  static const empty = AudioState();

  /// The camera exposes a capture device.
  final bool available;

  /// SDK audio state. Meaningless while [available] is false.
  final bool enabled;

  /// Automatic gain control.
  final bool autoGain;

  /// True only when the microphone exists and is on, which is the single
  /// condition under which a recording will carry sound.
  bool get capturing => available && enabled;

  AudioState copyWith({bool? available, bool? enabled, bool? autoGain}) {
    return AudioState(
      available: available ?? this.available,
      enabled: enabled ?? this.enabled,
      autoGain: autoGain ?? this.autoGain,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'available': available,
    'enabled': enabled,
    'auto_gain': autoGain,
  };

  @override
  bool operator ==(Object other) =>
      other is AudioState &&
      other.available == available &&
      other.enabled == enabled &&
      other.autoGain == autoGain;

  @override
  int get hashCode => Object.hash(available, enabled, autoGain);
}
