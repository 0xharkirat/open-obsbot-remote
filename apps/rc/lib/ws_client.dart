import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
              speed: moveSpeedFromWire(e['speed'] as String? ?? 'medium'),
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

/// Move-to-preset transition speed.
enum MoveSpeed { instant, slow, medium, fast }

String moveSpeedToWire(MoveSpeed s) => switch (s) {
  MoveSpeed.instant => 'instant',
  MoveSpeed.slow => 'slow',
  MoveSpeed.medium => 'medium',
  MoveSpeed.fast => 'fast',
};

MoveSpeed moveSpeedFromWire(String s) => switch (s) {
  'instant' => MoveSpeed.instant,
  'slow' => MoveSpeed.slow,
  'fast' => MoveSpeed.fast,
  _ => MoveSpeed.medium,
};

String moveSpeedLabel(MoveSpeed s) => switch (s) {
  MoveSpeed.instant => 'Instant',
  MoveSpeed.slow => 'Slow',
  MoveSpeed.medium => 'Medium',
  MoveSpeed.fast => 'Fast',
};

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
  final MoveSpeed speed;
  const SequenceStep({
    required this.presetId,
    required this.seconds,
    this.speed = MoveSpeed.medium,
  });
  Map<String, dynamic> toJson() => <String, dynamic>{
    'preset_id': presetId,
    'seconds': seconds,
    'speed': moveSpeedToWire(speed),
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
  MoveSpeed _moveSpeed = MoveSpeed.medium;

  WsClient() {
    SharedPreferences.getInstance().then((p) {
      final s = p.getString('move_speed');
      if (s != null) {
        _moveSpeed = moveSpeedFromWire(s);
        notifyListeners();
      }
    });
  }

  MoveSpeed get moveSpeed => _moveSpeed;
  Future<void> setMoveSpeed(MoveSpeed s) async {
    _moveSpeed = s;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString('move_speed', moveSpeedToWire(s));
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

  void ptzAngle({required double yaw, required double pitch}) =>
      _send({'action': 'ptz.angle', 'id': _id(), 'yaw': yaw, 'pitch': pitch});

  void ptzVelocity({double yawSpeed = 0, double pitchSpeed = 0}) => _send({
    'action': 'ptz.velocity',
    'id': _id(),
    'yaw_speed': yawSpeed,
    'pitch_speed': pitchSpeed,
    'roll_speed': 0,
  });

  void ptzStop() => _send({'action': 'ptz.stop', 'id': _id()});
  void ptzRecenter() => _send({'action': 'ptz.recenter', 'id': _id()});

  void zoomSet(double value) =>
      _send({'action': 'zoom.set', 'id': _id(), 'value': value});

  void aiSetMode(String mode, [String sub = 'normal']) => _send({
    'action': 'ai.set_mode',
    'id': _id(),
    'mode': mode,
    'sub_mode': sub,
  });

  void hdr(bool e) =>
      _send({'action': 'image.set_hdr', 'id': _id(), 'enabled': e});

  void fov(int f) => _send({'action': 'image.set_fov', 'id': _id(), 'fov': f});

  void presetSave(int id, String name) => _send({
    'action': 'preset.save',
    'id': _id(),
    'preset_id': id,
    'name': name,
  });

  void presetRecall(int id, {MoveSpeed? speed}) => _send({
    'action': 'preset.recall',
    'id': _id(),
    'preset_id': id,
    'speed': moveSpeedToWire(speed ?? _moveSpeed),
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
