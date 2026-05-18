import 'package:meta/meta.dart';

import 'preset_entry.dart';
import 'sequence_state.dart';

/// Decoded device snapshot pushed by the bridge in every `state`
/// event. See `docs/PROTOCOL.md` for the full wire format.
///
/// Default values match an un-connected camera; real values arrive
/// in the state event broadcast after `subscribe`.
@immutable
class CameraState {
  // ---- Device identity / lifecycle ----
  final String sn;
  final String modelDisplay;
  final String firmware;
  final bool connected;

  /// `"run"` / `"sleep"` / `"privacy"` / `"unknown"`.
  final String runStatus;

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
  /// Tiny 2 Lite per the same caveat as `exposureMode`.
  final double evBias;

  /// `"off"` / `"50"` / `"60"` / `"auto"` (50/60 Hz line frequency).
  final String antiFlicker;

  final bool wbAuto;

  /// 2800..6500 K (manual white balance temperature, when `wbAuto`
  /// is false).
  final int wbKelvin;

  // ---- Presets + sequence ----
  final List<PresetEntry> presets;

  /// The preset id last recalled. `-1` after any manual PTZ command.
  final int activePresetId;

  final SequenceState sequence;

  const CameraState({
    required this.sn,
    required this.modelDisplay,
    required this.firmware,
    required this.connected,
    required this.runStatus,
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
  });

  static const empty = CameraState(
    sn: '',
    modelDisplay: '',
    firmware: '',
    connected: false,
    runStatus: 'unknown',
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

  factory CameraState.fromEvent(Map<String, dynamic> j) {
    final dev =
        (j['device'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ptz =
        (j['ptz'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final zoom =
        (j['zoom'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ai = (j['ai'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final img =
        (j['image'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final seq =
        (j['sequence'] ?? const <String, dynamic>{}) as Map<String, dynamic>;

    double d(Object? v, [double def = 0]) =>
        v is num ? v.toDouble() : def;
    int i(Object? v, [int def = 0]) => v is num ? v.toInt() : def;

    final List<dynamic> pl =
        (j['presets'] as List<dynamic>?) ?? const <dynamic>[];
    final List<PresetEntry> presets = pl
        .whereType<Map<String, dynamic>>()
        .map(PresetEntry.fromJson)
        .toList(growable: false);

    return CameraState(
      sn: dev['sn'] as String? ?? '',
      modelDisplay: dev['model_display'] as String? ?? '',
      firmware: dev['firmware'] as String? ?? '',
      connected: dev['connected'] as bool? ?? false,
      runStatus: dev['run_status'] as String? ?? 'unknown',
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
    );
  }

  /// Returns a copy of this state with the given fields overridden.
  /// Used by [WsClient] for optimistic UI - we snap the chosen value
  /// into local state the instant the user taps so the segmented /
  /// toggle button shows its new selected state without waiting for
  /// the bridge round-trip. The next real state event from the bridge
  /// overwrites the optimistic value (and corrects it if the camera
  /// clamped or rejected).
  CameraState copyWith({
    String? sn,
    String? modelDisplay,
    String? firmware,
    bool? connected,
    String? runStatus,
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
  }) {
    return CameraState(
      sn: sn ?? this.sn,
      modelDisplay: modelDisplay ?? this.modelDisplay,
      firmware: firmware ?? this.firmware,
      connected: connected ?? this.connected,
      runStatus: runStatus ?? this.runStatus,
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
    );
  }
}
