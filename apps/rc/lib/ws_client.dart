import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One saved preset on the camera (mirrored from the bridge state).
class PresetEntry {
  final int id;
  final String name;
  final double yaw, pitch, roll, zoom;
  const PresetEntry({
    required this.id,
    required this.name,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.zoom,
  });
  factory PresetEntry.fromJson(Map<String, dynamic> j) => PresetEntry(
    id: (j['id'] as num?)?.toInt() ?? 0,
    name: j['name'] as String? ?? '',
    yaw: (j['yaw'] as num?)?.toDouble() ?? 0,
    pitch: (j['pitch'] as num?)?.toDouble() ?? 0,
    roll: (j['roll'] as num?)?.toDouble() ?? 0,
    zoom: (j['zoom'] as num?)?.toDouble() ?? 1,
  );
}

/// Sequencer state pushed by the bridge.
class SequenceState {
  final bool running;
  final int stepIndex;
  final int elapsedS;
  final int totalS;
  final List<String> available;
  final String loaded;
  final String mode;                 // forward | once | ping_pong
  final List<SequenceStep> steps;    // active scratch — editor hydrates from this
  const SequenceState({
    required this.running,
    required this.stepIndex,
    required this.elapsedS,
    required this.totalS,
    required this.available,
    required this.loaded,
    required this.mode,
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
    steps: <SequenceStep>[],
  );
  factory SequenceState.fromJson(Map<String, dynamic> j) {
    final stepsRaw = (j['steps'] as List<dynamic>?) ?? const <dynamic>[];
    final steps = stepsRaw
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> e) => SequenceStep(
              presetId: (e['preset_id'] as num?)?.toInt() ?? 0,
              seconds: (e['seconds'] as num?)?.toInt() ?? 60,
              transition: Duration(
                  milliseconds: (e['transition_ms'] as num?)?.toInt() ?? 0),
            ))
        .toList();
    return SequenceState(
      running: j['running'] as bool? ?? false,
      stepIndex: (j['step_index'] as num?)?.toInt() ?? -1,
      elapsedS: (j['elapsed_s'] as num?)?.toInt() ?? 0,
      totalS: (j['total_s'] as num?)?.toInt() ?? 0,
      available: ((j['available'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList(),
      loaded: j['loaded'] as String? ?? '',
      mode: j['mode'] as String? ?? 'forward',
      steps: steps,
    );
  }
}

/// Duration-based move presets for the speed selector.
///
/// User picks how long the camera should take to reach the target —
/// from snap (Duration.zero / instant) up to several minutes for
/// cinematographic slow pans. Bridge `MotionPlanner` honors any
/// duration; these are just the well-known chip values.
class MoveDurationPreset {
  final String label;
  final Duration duration;
  final IconData icon;
  const MoveDurationPreset(this.label, this.duration, this.icon);
}

const List<MoveDurationPreset> kMoveDurationPresets = <MoveDurationPreset>[
  MoveDurationPreset('Instant', Duration.zero,                     Icons.flash_on),
  MoveDurationPreset('1 sec',   Duration(milliseconds: 1000),       Icons.bolt),
  MoveDurationPreset('5 sec',   Duration(milliseconds: 5000),       Icons.directions_run),
  MoveDurationPreset('15 sec',  Duration(milliseconds: 15000),      Icons.directions_walk),
  MoveDurationPreset('30 sec',  Duration(milliseconds: 30000),      Icons.movie_creation_outlined),
  MoveDurationPreset('1 min',   Duration(milliseconds: 60000),      Icons.hourglass_bottom),
  MoveDurationPreset('3 min',   Duration(milliseconds: 180000),     Icons.hourglass_top),
  MoveDurationPreset('5 min',   Duration(milliseconds: 300000),     Icons.hourglass_empty),
];

String formatMoveDuration(Duration d) {
  if (d == Duration.zero) return 'Instant';
  if (d.inMinutes >= 1) {
    final m = d.inMinutes;
    final s = d.inSeconds - m * 60;
    return s == 0 ? '$m min' : '${m}m ${s}s';
  }
  return '${(d.inMilliseconds / 1000).toStringAsFixed(d.inMilliseconds % 1000 == 0 ? 0 : 1)} sec';
}

/// How a sequence loops once it finishes its last step.
enum LoopMode {
  /// Play once and stop.
  once,

  /// Restart at step 1 (P1→P2→P3→P1→P2→P3…).
  forward,

  /// Reverse direction at each end (P1→P2→P3→P2→P1→P2→P3…).
  /// Useful when P3→P1 is a long, ugly move you want to skip.
  pingPong,
}

String loopModeToWire(LoopMode m) => switch (m) {
  LoopMode.once => 'once',
  LoopMode.forward => 'forward',
  LoopMode.pingPong => 'ping_pong',
};

LoopMode loopModeFromWire(String s) => switch (s) {
  'once' => LoopMode.once,
  'ping_pong' => LoopMode.pingPong,
  _ => LoopMode.forward,
};

String loopModeLabel(LoopMode m) => switch (m) {
  LoopMode.once => 'Once (stop at end)',
  LoopMode.forward => 'Loop forward (P1→P2→P3→P1…)',
  LoopMode.pingPong => 'Ping-pong (P1→P2→P3→P2→P1…)',
};

/// One step in a sequence sent to the bridge.
class SequenceStep {
  final int presetId;
  final int seconds;
  /// How long the camera takes to *reach* this step's preset.
  /// Duration.zero = instant. Defaults to 2 seconds (medium).
  final Duration transition;
  const SequenceStep({
    required this.presetId,
    required this.seconds,
    this.transition = const Duration(milliseconds: 2000),
  });
  Map<String, dynamic> toJson() => <String, dynamic>{
    'preset_id': presetId,
    'seconds': seconds,
    'transition_ms': transition.inMilliseconds,
  };
}

/// Decoded device snapshot pushed by the bridge.
class CameraState {
  final String sn;
  final String modelDisplay;
  final String firmware;
  final bool connected;
  final String runStatus;

  final double yaw;
  final double pitch;
  final double roll;

  final double zoom;
  final double zoomMin;
  final double zoomMax;

  final String aiMode;
  final String aiSubMode;
  final bool aiEnabled;

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

  /// v1.2 PR G — exposure / anti-flicker / WB. Defaults match an
  /// un-connected camera; real values arrive in the state event.
  final String exposureMode; // "auto" | "manual"
  final double evBias;       // -3.0..+3.0 (1/3 stops)
  final String antiFlicker;  // "off" | "50" | "60" | "auto"
  final bool wbAuto;
  final int wbKelvin;        // 2800..6500

  final List<PresetEntry> presets;
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
    final ptz = (j['ptz'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final zoom =
        (j['zoom'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ai = (j['ai'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final img =
        (j['image'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    double d(dynamic v, [double def = 0]) => v is num ? v.toDouble() : def;
    int i(dynamic v, [int def = 0]) => v is num ? v.toInt() : def;
    final List<dynamic> pl =
        (j['presets'] as List<dynamic>?) ?? const <dynamic>[];
    final List<PresetEntry> presets = pl
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> e) => PresetEntry.fromJson(e))
        .toList();
    final seqJson =
        (j['sequence'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
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
      evBias: d(img['ev_bias'], 0.0),
      antiFlicker: img['anti_flicker'] as String? ?? 'off',
      wbAuto: img['wb_auto'] as bool? ?? true,
      wbKelvin: i(img['wb_kelvin'], 4700),
      presets: presets,
      activePresetId: i(j['active_preset_id'], -1),
      sequence: SequenceState.fromJson(seqJson),
    );
  }
}

class WsClient extends ChangeNotifier {
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  int _msgId = 0;
  bool _connected = false;
  bool _connecting = false;
  bool _needsPairing = false; // true after auth_required response
  String _serverUri = '';
  CameraState _state = CameraState.empty;
  String? _lastError;
  String? _lastAuthError;
  int _lastLatencyMs = 0;
  DateTime? _lastPingSent;
  String? _token; // bearer token after pairing
  /// Default move duration applied to ptzAngle / presetRecall / zoomSet
  /// when the caller doesn't pass one explicitly. Persisted across app
  /// launches via SharedPreferences key `move_duration_ms`.
  Duration _moveDuration = const Duration(milliseconds: 2000);

  /// Grid overlay preferences (mirrored to SharedPreferences keys
  /// `grid_crosshair`, `grid_center_lines`, `grid_thirds`, `grid_readout`).
  bool _gridCrosshair = true;
  bool _gridCenterLines = false;
  bool _gridThirds = false;
  bool _gridReadout = true;

  /// Live-velocity multiplier (0.1 .. 1.0) applied to both the joystick
  /// pad's analog deflection AND the 8-way hold buttons. Persisted as
  /// `velocity_scale`. Defaults to 1.0 (full speed) so existing users
  /// don't get a surprise slowdown on first launch.
  double _velocityScale = 1.0;

  WsClient() {
    SharedPreferences.getInstance().then((p) {
      final ms = p.getInt('move_duration_ms');
      if (ms != null) _moveDuration = Duration(milliseconds: ms);
      _gridCrosshair = p.getBool('grid_crosshair') ?? _gridCrosshair;
      _gridCenterLines = p.getBool('grid_center_lines') ?? _gridCenterLines;
      _gridThirds = p.getBool('grid_thirds') ?? _gridThirds;
      _gridReadout = p.getBool('grid_readout') ?? _gridReadout;
      final vs = p.getDouble('velocity_scale');
      if (vs != null) _velocityScale = vs.clamp(0.1, 1.0);
      notifyListeners();
    });
  }

  double get velocityScale => _velocityScale;
  Future<void> setVelocityScale(double v) async {
    _velocityScale = v.clamp(0.1, 1.0);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setDouble('velocity_scale', _velocityScale);
  }

  bool get gridCrosshair => _gridCrosshair;
  bool get gridCenterLines => _gridCenterLines;
  bool get gridThirds => _gridThirds;
  bool get gridReadout => _gridReadout;

  Future<void> setGridCrosshair(bool v) async {
    _gridCrosshair = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('grid_crosshair', v);
  }

  Future<void> setGridCenterLines(bool v) async {
    _gridCenterLines = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('grid_center_lines', v);
  }

  Future<void> setGridThirds(bool v) async {
    _gridThirds = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('grid_thirds', v);
  }

  Future<void> setGridReadout(bool v) async {
    _gridReadout = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('grid_readout', v);
  }

  Duration get moveDuration => _moveDuration;
  Future<void> setMoveDuration(Duration d) async {
    _moveDuration = d;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt('move_duration_ms', d.inMilliseconds);
  }

  bool get connected => _connected && _state.connected;
  bool get socketOpen => _connected;
  bool get connecting => _connecting;
  bool get needsPairing => _needsPairing;
  String get serverUri => _serverUri;
  String? get token => _token;
  CameraState get state => _state;
  String? get lastError => _lastError;
  String? get lastAuthError => _lastAuthError;
  int get lastLatencyMs => _lastLatencyMs;

  String _tokenKey(String hostPort) => 'token::$hostPort';

  Future<String?> loadLastServer() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getString('last_server');
  }

  Future<void> _saveLastServer(String uri) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString('last_server', uri);
  }

  Future<String?> _loadToken(String hostPort) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getString(_tokenKey(hostPort));
  }

  Future<void> _saveToken(String hostPort, String tok) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(_tokenKey(hostPort), tok);
  }

  Future<void> _clearToken(String hostPort) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_tokenKey(hostPort));
  }

  Future<void> connect(String hostPort) async {
    await close();
    final uri = Uri.parse('ws://$hostPort/v1');
    _serverUri = hostPort;
    _connecting = true;
    _lastError = null;
    _lastAuthError = null;
    _needsPairing = false;
    _token = await _loadToken(hostPort);
    notifyListeners();
    try {
      final ch = WebSocketChannel.connect(uri);
      _ch = ch;
      _sub = ch.stream.listen(
        _onMessage,
        onError: (Object e) {
          _lastError = 'connection error: $e';
          _connected = false;
          _connecting = false;
          notifyListeners();
        },
        onDone: () {
          _connected = false;
          _connecting = false;
          _lastError ??=
              'disconnected — bridge closed the socket or it was unreachable';
          notifyListeners();
        },
      );
      try {
        await ch.ready.timeout(const Duration(seconds: 6));
      } on TimeoutException {
        _lastError = 'timed out — could not reach $hostPort.';
        _connecting = false;
        notifyListeners();
        await close();
        return;
      } catch (e) {
        _lastError = 'connect failed: $e';
        _connecting = false;
        notifyListeners();
        await close();
        return;
      }
      _connected = true;
      _connecting = false;
      // hello carries the token if we have one. If not, server will
      // reply with auth_required and the UI prompts for the PIN.
      _send({
        'action': 'hello',
        'id': _id(),
        if (_token != null) 'token': _token,
        'client': {'name': 'Open OBSBOT Remote', 'version': '1.0.0'},
      });
      _send({'action': 'subscribe', 'id': _id()});
      await _saveLastServer(hostPort);
      notifyListeners();
    } catch (e) {
      _lastError = 'connect failed: $e';
      _connected = false;
      _connecting = false;
      notifyListeners();
    }
  }

  // Pending pair() promise resolved by _onMessage when the matching ack
  // lands. We keep a single WS subscription for the lifetime of the
  // connection so we never miss messages mid-handler-swap.
  Completer<bool>? _pendingPair;
  String? _pendingPairId;

  /// Pair using the 6-digit PIN displayed in the bridge UI.
  /// Returns true on success, false on wrong PIN.
  Future<bool> pair(String pin) async {
    if (_ch == null) return false;
    // Cancel any earlier in-flight pair to keep state clean.
    if (_pendingPair != null && !_pendingPair!.isCompleted) {
      _pendingPair!.complete(false);
    }
    _pendingPair = Completer<bool>();
    _pendingPairId = _id();
    _send({'action': 'pair', 'id': _pendingPairId, 'pin': pin});

    Timer(const Duration(seconds: 6), () {
      if (_pendingPair != null && !_pendingPair!.isCompleted) {
        _lastAuthError = 'timed out waiting for pair response';
        _pendingPair!.complete(false);
        notifyListeners();
      }
    });
    return _pendingPair!.future;
  }

  Future<void> forgetToken() async {
    await _clearToken(_serverUri);
    _token = null;
    _needsPairing = true;
    notifyListeners();
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _ch?.sink.close();
    _ch = null;
    _connected = false;
    notifyListeners();
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;

      // Pair-ack (matched by id) — resolves any in-flight pair() future.
      if (j['type'] == 'ack' &&
          _pendingPair != null &&
          !_pendingPair!.isCompleted &&
          j['id'] == _pendingPairId) {
        if (j['ok'] == true && j['token'] is String) {
          _token = j['token'] as String;
          _saveToken(_serverUri, _token!);
          _needsPairing = false;
          _lastAuthError = null;
          // re-send subscribe so we get a state snapshot now that we're authed
          _send({'action': 'subscribe', 'id': _id()});
          _pendingPair!.complete(true);
        } else {
          _lastAuthError = j['msg'] as String? ?? 'wrong PIN';
          _pendingPair!.complete(false);
        }
        _pendingPair = null;
        _pendingPairId = null;
        notifyListeners();
        return;
      }

      if (j['event'] == 'state') {
        _state = CameraState.fromEvent(j);
        notifyListeners();
      } else if (j['type'] == 'pong') {
        if (_lastPingSent != null) {
          _lastLatencyMs = DateTime.now()
              .difference(_lastPingSent!)
              .inMilliseconds;
          _lastPingSent = null;
          notifyListeners();
        }
      } else if (j['type'] == 'ack' && j['err'] == 'auth_required') {
        _needsPairing = true;
        _lastAuthError = j['msg'] as String?;
        notifyListeners();
      } else if (j['type'] == 'ack' && j['ok'] == false) {
        final msg = j['msg'];
        final err = j['err'];
        _lastError = msg is String
            ? msg
            : err is String
            ? err
            : 'command failed';
        notifyListeners();
      }
    } catch (_) {}
  }

  String _id() => '${++_msgId}';

  void _send(Map<String, dynamic> m) {
    final ch = _ch;
    if (ch == null) return;
    ch.sink.add(jsonEncode(m));
  }

  // ---- commands ----
  void ping() {
    _lastPingSent = DateTime.now();
    _send({'action': 'ping', 'id': _id()});
  }

  void ptzAngle({required double yaw, required double pitch, Duration? duration}) =>
      _send({
        'action': 'ptz.angle', 'id': _id(),
        'yaw': yaw, 'pitch': pitch,
        'duration_ms': (duration ?? _moveDuration).inMilliseconds,
      });

  /// Velocity is rate-based; client should multiply its own deflection
  /// by whatever speed-factor the user chose before calling this.
  void ptzVelocity({double yawSpeed = 0, double pitchSpeed = 0}) => _send({
    'action': 'ptz.velocity',
    'id': _id(),
    'yaw_speed': yawSpeed,
    'pitch_speed': pitchSpeed,
    'roll_speed': 0,
  });

  void ptzStop() => _send({'action': 'ptz.stop', 'id': _id()});
  void ptzRecenter() => _send({'action': 'ptz.recenter', 'id': _id()});

  /// Zoom to absolute value. `terminal: true` on slider drag-end so the
  /// bridge bypasses mid-drag coalesce. `duration` controls how long
  /// the lens motor takes — Duration.zero = snap, larger = pro slow zoom.
  void zoomSet(double value, {bool terminal = false, Duration? duration}) => _send({
    'action': 'zoom.set',
    'id': _id(),
    'value': value,
    if (terminal) 'final': true,
    'duration_ms': (duration ?? Duration.zero).inMilliseconds,
  });

  void aiSetMode(String mode, [String sub = 'normal']) => _send({
    'action': 'ai.set_mode',
    'id': _id(),
    'mode': mode,
    'sub_mode': sub,
  });

  void hdr(bool e) =>
      _send({'action': 'image.set_hdr', 'id': _id(), 'enabled': e});

  void fov(int f) => _send({'action': 'image.set_fov', 'id': _id(), 'fov': f});

  /// Camera face-detection-driven auto-exposure. Off by default per the
  /// v1.1 "auto-exposure makes scene dark" finding.
  void faceAe(bool e) =>
      _send({'action': 'image.set_face_ae', 'id': _id(), 'enabled': e});

  /// Bias auto-focus to detected faces.
  void faceFocus(bool e) =>
      _send({'action': 'image.set_face_focus', 'id': _id(), 'enabled': e});

  /// Mirror the image horizontally (useful for selfie / monitor setups).
  void flipH(bool e) =>
      _send({'action': 'image.set_flip_h', 'id': _id(), 'enabled': e});

  /// Update one or more color sliders (0..100). Only fields you pass are
  /// sent; unset fields are left untouched on the camera.
  void colorSet({int? brightness, int? contrast, int? saturation, int? sharpness}) {
    final Map<String, dynamic> msg = <String, dynamic>{
      'action': 'image.set_color',
      'id': _id(),
    };
    if (brightness != null) msg['brightness'] = brightness;
    if (contrast != null) msg['contrast'] = contrast;
    if (saturation != null) msg['saturation'] = saturation;
    if (sharpness != null) msg['sharpness'] = sharpness;
    _send(msg);
  }

  // v1.2 PR G — exposure / anti-flicker / white balance.
  // Empirical probe on Tiny 2 Lite firmware 6.2.8.1 (PR P, 2026-05-12)
  // confirmed every exposure_mode + ev_bias variant returns r=0 — the
  // "tail air" tag in the SDK headers is misleading. All controls work.

  void setExposureMode(String mode) => _send({
        'action': 'image.set_exposure_mode',
        'id': _id(),
        'mode': mode, // "auto" | "manual"
      });

  void setEvBias(double bias) => _send({
        'action': 'image.set_ev_bias',
        'id': _id(),
        'bias': bias, // -3.0 .. +3.0 (1/3 stops). Snapped server-side.
      });

  void setAntiFlicker(String mode) => _send({
        'action': 'image.set_anti_flicker',
        'id': _id(),
        'mode': mode, // "off" | "50" | "60" | "auto"
      });

  void setWbAuto(bool enabled) => _send({
        'action': 'image.set_wb_auto',
        'id': _id(),
        'enabled': enabled,
      });

  /// Ask the bridge to re-read live exposure / anti-flicker / WB state
  /// from the camera and stamp its snapshot. Useful when OBSBOT Center
  /// or other tools have changed values out-of-band; without it the UI
  /// shows our last-known state which can drift indefinitely.
  void imageRefresh() => _send({
        'action': 'image.refresh',
        'id': _id(),
      });

  void setWbTemp(int kelvin) => _send({
        'action': 'image.set_wb_temp',
        'id': _id(),
        'kelvin': kelvin, // 2800 .. 6500
      });

  void presetSave(int id, String name) => _send({
    'action': 'preset.save',
    'id': _id(),
    'preset_id': id,
    'name': name,
  });

  void presetRecall(int id, {Duration? duration}) => _send({
    'action': 'preset.recall',
    'id': _id(),
    'preset_id': id,
    'duration_ms': (duration ?? _moveDuration).inMilliseconds,
  });

  void presetDelete(int id) =>
      _send({'action': 'preset.delete', 'id': _id(), 'preset_id': id});

  void runStatus(String s) =>
      _send({'action': 'system.run_status', 'id': _id(), 'status': s});

  // ---- sequencer ----
  void sequenceSet(
    List<SequenceStep> steps, {
    LoopMode mode = LoopMode.forward,
  }) => _send({
    'action': 'sequence.set',
    'id': _id(),
    'steps': steps.map((s) => s.toJson()).toList(),
    'mode': loopModeToWire(mode),
    // legacy field for older bridges
    'loop': mode != LoopMode.once,
  });

  void sequenceStart() => _send({'action': 'sequence.start', 'id': _id()});
  void sequenceStop() => _send({'action': 'sequence.stop', 'id': _id()});

  // Library
  void sequenceSaveAs(
    String name,
    List<SequenceStep> steps, {
    LoopMode mode = LoopMode.forward,
  }) => _send({
    'action': 'sequence.save_as',
    'id': _id(),
    'name': name,
    'mode': loopModeToWire(mode),
    'steps': steps.map((s) => s.toJson()).toList(),
  });
  void sequenceLoad(String name) =>
      _send({'action': 'sequence.load', 'id': _id(), 'name': name});
  void sequenceDelete(String name) =>
      _send({'action': 'sequence.delete', 'id': _id(), 'name': name});
}
