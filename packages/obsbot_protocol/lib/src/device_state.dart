import 'package:meta/meta.dart';

import 'audio_state.dart';
import 'preset_entry.dart';
import 'sequence_state.dart';

/// Decoded per-camera snapshot. One [DeviceState] per attached camera,
/// addressed by [deviceId] (the camera's stable serial number).
///
/// v1.x called this `CameraState` and assumed a single camera per
/// bridge. v2 splits multi-cam concerns out into [BridgeState] which
/// owns the list of these.
///
/// Default values match an un-connected camera; real values arrive in
/// the state event broadcast after `subscribe`.
@immutable
class DeviceState {
  /// Stable identifier (the camera's serial number, e.g. "RMOW1234").
  /// Used as the `device_id` field on every action + state event.
  /// Survives unplug + replug to a different USB port.
  final String deviceId;

  /// What this device is: `"obsbot"` (full DeviceSession - PTZ, presets,
  /// image, AI, sequencer) or `"video"` (a generic session-less source
  /// added via `source.add` - preview + TAKE only). Old bridges omit the
  /// field, so the default keeps every OBSBOT camera parsing unchanged.
  final String kind;

  // ---- Device identity / lifecycle ----
  /// Same value as [deviceId]. Kept as a separate field so the
  /// existing UI code that reads `state.sn` keeps working.
  final String sn;
  final String modelDisplay;
  final String firmware;
  final bool connected;

  /// `"run"` / `"sleep"` / `"privacy"` / `"unknown"`.
  final String runStatus;

  /// Operator-assigned friendly name ("Vocal", "GGS"). Empty if the
  /// user hasn't renamed - UI falls back to [modelDisplay] in that
  /// case. Persisted bridge-side keyed by [deviceId] so it survives
  /// reconnect.
  final String friendlyName;

  // ---- PTZ ----
  /// Pan in degrees. Positive = camera pointed right in viewer frame.
  final double yaw;

  /// Tilt in degrees. Positive = camera pointed up.
  final double pitch;

  /// Roll in degrees. Positive = gimbal rotated clockwise from
  /// operator point-of-view.
  final double roll;

  // ---- Zoom ----
  final double zoom;
  final double zoomMin;
  final double zoomMax;

  // ---- AI ----
  /// `"none"` / `"human"` / `"hand"` / `"group"` / `"whiteboard"` / `"desk"`.
  final String aiMode;

  /// Human-track sub-mode: `"normal"` / `"upper_body"` / `"close_up"`
  /// / `"head_hide"` / `"lower_body"`.
  final String aiSubMode;

  final bool aiEnabled;

  // ---- Image ----
  final bool hdr;
  final int fov;
  final int brightness;
  final int contrast;
  final int saturation;
  final int sharpness;
  final bool faceAe;
  final bool faceFocus;
  final bool autoFocus;
  final int manualFocus;
  final bool flipH;

  // ---- v1.2: exposure / anti-flicker / WB ----
  /// `"auto"` / `"manual"`. Best-effort on Tiny 2 Lite; the bridge
  /// reports `unsupported` if the firmware rejects.
  final String exposureMode;

  /// -3.0..+3.0 EV (1/3 stops on the SDK wire). Best-effort on
  /// Tiny 2 Lite per the same caveat as [exposureMode].
  final double evBias;

  /// `"off"` / `"50"` / `"60"` / `"auto"` (50/60 Hz line frequency).
  final String antiFlicker;

  final bool wbAuto;

  /// 2800..6500 K (manual white balance temperature, when [wbAuto]
  /// is false).
  final int wbKelvin;

  // ---- Presets + sequence (per-device) ----
  /// Presets are scoped to this device. v1.x stored a single flat
  /// list on the bridge; v2 keys the file by [deviceId] so each cam
  /// owns its P1..P6 independently.
  final List<PresetEntry> presets;

  /// The preset id last recalled on THIS device. `-1` after any
  /// manual PTZ command.
  final int activePresetId;

  /// Sequence running on THIS device. v2.0 keeps sequences per-device;
  /// cross-camera sequences are planned for v2.1+ and will live on
  /// [BridgeState] instead.
  final SequenceState sequence;

  /// This camera's microphone. [AudioState.empty] on a bridge that
  /// predates the audio block, which reads as "no microphone known" and
  /// renders the control disabled rather than falsely on.
  final AudioState audio;

  /// True for a generic session-less video source: the UI shows preview
  /// and TAKE only and must not render PTZ / preset / image / AI /
  /// sequencer affordances for it.
  bool get isVideoSource => kind == 'video';

  const DeviceState({
    required this.deviceId,
    this.kind = 'obsbot',
    required this.sn,
    required this.modelDisplay,
    required this.firmware,
    required this.connected,
    required this.runStatus,
    required this.friendlyName,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.zoom,
    required this.zoomMin,
    required this.zoomMax,
    required this.aiMode,
    required this.aiSubMode,
    required this.aiEnabled,
    required this.hdr,
    required this.fov,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.sharpness,
    required this.faceAe,
    required this.faceFocus,
    required this.autoFocus,
    required this.manualFocus,
    required this.flipH,
    required this.exposureMode,
    required this.evBias,
    required this.antiFlicker,
    required this.wbAuto,
    required this.wbKelvin,
    required this.presets,
    required this.activePresetId,
    required this.sequence,
    this.audio = AudioState.empty,
  });

  /// Placeholder for "no device yet" - used by [BridgeState.activeDevice]
  /// when no camera is attached. UI code reading from this should
  /// guard with `BridgeState.devices.isEmpty` first.
  static const empty = DeviceState(
    deviceId: '',
    sn: '',
    modelDisplay: '',
    firmware: '',
    connected: false,
    runStatus: 'unknown',
    friendlyName: '',
    yaw: 0,
    pitch: 0,
    roll: 0,
    zoom: 1,
    zoomMin: 1,
    zoomMax: 2,
    aiMode: 'none',
    aiSubMode: 'normal',
    aiEnabled: false,
    hdr: false,
    fov: 86,
    brightness: 50,
    contrast: 50,
    saturation: 50,
    sharpness: 50,
    faceAe: false,
    faceFocus: false,
    autoFocus: true,
    manualFocus: 50,
    flipH: false,
    exposureMode: 'auto',
    evBias: 0.0,
    antiFlicker: 'off',
    wbAuto: true,
    wbKelvin: 4700,
    presets: <PresetEntry>[],
    activePresetId: -1,
    sequence: SequenceState.empty,
  );

  /// Parses one device-entry from the v2 state event's `devices` array.
  ///
  /// Expected shape:
  /// ```json
  /// {
  ///   "device_id": "RMOW1234",
  ///   "device": {sn, model_display, firmware, connected, run_status, friendly_name},
  ///   "ptz": {yaw, pitch, roll},
  ///   "zoom": {value, min, max},
  ///   "ai": {mode, sub_mode, enabled},
  ///   "image": {hdr, fov, ...},
  ///   "presets": [...],
  ///   "active_preset_id": -1,
  ///   "sequence": {...}
  /// }
  /// ```
  factory DeviceState.fromEvent(Map<String, dynamic> j) {
    final dev =
        (j['device'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ptz = (j['ptz'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final zoom =
        (j['zoom'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ai = (j['ai'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final img =
        (j['image'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final seq =
        (j['sequence'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final aud = j['audio'];

    double d(Object? v, [double def = 0]) => v is num ? v.toDouble() : def;
    int i(Object? v, [int def = 0]) => v is num ? v.toInt() : def;

    final List<dynamic> pl =
        (j['presets'] as List<dynamic>?) ?? const <dynamic>[];
    final List<PresetEntry> presets = pl
        .whereType<Map<String, dynamic>>()
        .map(PresetEntry.fromJson)
        .toList(growable: false);

    // device_id at the top level is canonical; fall back to dev.sn
    // for bridges that omit it (transitional).
    final sn = dev['sn'] as String? ?? '';
    final deviceId = j['device_id'] as String? ?? sn;

    return DeviceState(
      deviceId: deviceId,
      kind: j['kind'] as String? ?? 'obsbot',
      sn: sn,
      modelDisplay: dev['model_display'] as String? ?? '',
      firmware: dev['firmware'] as String? ?? '',
      connected: dev['connected'] as bool? ?? false,
      runStatus: dev['run_status'] as String? ?? 'unknown',
      friendlyName: dev['friendly_name'] as String? ?? '',
      yaw: d(ptz['yaw']),
      pitch: d(ptz['pitch']),
      roll: d(ptz['roll']),
      zoom: d(zoom['value'], 1),
      zoomMin: d(zoom['min'], 1),
      zoomMax: d(zoom['max'], 2),
      aiMode: ai['mode'] as String? ?? 'none',
      aiSubMode: ai['sub_mode'] as String? ?? 'normal',
      aiEnabled: ai['enabled'] as bool? ?? false,
      hdr: img['hdr'] as bool? ?? false,
      fov: i(img['fov'], 86),
      brightness: i(img['brightness'], 50),
      contrast: i(img['contrast'], 50),
      saturation: i(img['saturation'], 50),
      sharpness: i(img['sharpness'], 50),
      faceAe: img['face_ae'] as bool? ?? false,
      faceFocus: img['face_focus'] as bool? ?? false,
      autoFocus: img['auto_focus'] as bool? ?? true,
      manualFocus: i(img['manual_focus'], 50),
      flipH: img['flip_h'] as bool? ?? false,
      exposureMode: img['exposure_mode'] as String? ?? 'auto',
      evBias: d(img['ev_bias']),
      antiFlicker: img['anti_flicker'] as String? ?? 'off',
      wbAuto: img['wb_auto'] as bool? ?? true,
      wbKelvin: i(img['wb_kelvin'], 4700),
      presets: presets,
      activePresetId: i(j['active_preset_id'], -1),
      sequence: SequenceState.fromJson(seq),
      audio: aud is Map<String, dynamic>
          ? AudioState.fromJson(aud)
          : AudioState.empty,
    );
  }

  /// The label shown in pickers / breadcrumbs. Friendly name when set,
  /// model + last-4-of-SN otherwise. Never empty unless this is
  /// [DeviceState.empty].
  String get displayName {
    if (friendlyName.isNotEmpty) return friendlyName;
    if (modelDisplay.isEmpty) return deviceId;
    final tail = sn.length >= 4 ? sn.substring(sn.length - 4) : sn;
    return tail.isEmpty ? modelDisplay : '$modelDisplay ($tail)';
  }

  /// Returns a copy of this state with the given fields overridden.
  /// Used by `WsClient` for optimistic UI - the chosen value is snapped
  /// into local state the instant the user taps so the button shows
  /// its new selected state without waiting for the bridge round-trip.
  /// The next real state event overwrites the optimistic value (and
  /// corrects it if the camera clamped or rejected).
  DeviceState copyWith({
    String? deviceId,
    String? kind,
    String? sn,
    String? modelDisplay,
    String? firmware,
    bool? connected,
    String? runStatus,
    String? friendlyName,
    double? yaw,
    double? pitch,
    double? roll,
    double? zoom,
    double? zoomMin,
    double? zoomMax,
    String? aiMode,
    String? aiSubMode,
    bool? aiEnabled,
    bool? hdr,
    int? fov,
    int? brightness,
    int? contrast,
    int? saturation,
    int? sharpness,
    bool? faceAe,
    bool? faceFocus,
    bool? autoFocus,
    int? manualFocus,
    bool? flipH,
    String? exposureMode,
    double? evBias,
    String? antiFlicker,
    bool? wbAuto,
    int? wbKelvin,
    List<PresetEntry>? presets,
    int? activePresetId,
    SequenceState? sequence,
    AudioState? audio,
  }) {
    return DeviceState(
      deviceId: deviceId ?? this.deviceId,
      kind: kind ?? this.kind,
      sn: sn ?? this.sn,
      modelDisplay: modelDisplay ?? this.modelDisplay,
      firmware: firmware ?? this.firmware,
      connected: connected ?? this.connected,
      runStatus: runStatus ?? this.runStatus,
      friendlyName: friendlyName ?? this.friendlyName,
      yaw: yaw ?? this.yaw,
      pitch: pitch ?? this.pitch,
      roll: roll ?? this.roll,
      zoom: zoom ?? this.zoom,
      zoomMin: zoomMin ?? this.zoomMin,
      zoomMax: zoomMax ?? this.zoomMax,
      aiMode: aiMode ?? this.aiMode,
      aiSubMode: aiSubMode ?? this.aiSubMode,
      aiEnabled: aiEnabled ?? this.aiEnabled,
      hdr: hdr ?? this.hdr,
      fov: fov ?? this.fov,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      sharpness: sharpness ?? this.sharpness,
      faceAe: faceAe ?? this.faceAe,
      faceFocus: faceFocus ?? this.faceFocus,
      autoFocus: autoFocus ?? this.autoFocus,
      manualFocus: manualFocus ?? this.manualFocus,
      flipH: flipH ?? this.flipH,
      exposureMode: exposureMode ?? this.exposureMode,
      evBias: evBias ?? this.evBias,
      antiFlicker: antiFlicker ?? this.antiFlicker,
      wbAuto: wbAuto ?? this.wbAuto,
      wbKelvin: wbKelvin ?? this.wbKelvin,
      presets: presets ?? this.presets,
      activePresetId: activePresetId ?? this.activePresetId,
      sequence: sequence ?? this.sequence,
      audio: audio ?? this.audio,
    );
  }
}
