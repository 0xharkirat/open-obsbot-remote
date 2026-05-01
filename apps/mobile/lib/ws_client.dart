import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
    zoomMax: 4,
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
  );

  factory CameraState.fromEvent(Map<String, dynamic> j) {
    final dev = (j['device'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ptz = (j['ptz'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final zoom = (j['zoom'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final ai = (j['ai'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    final img = (j['image'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
    double d(dynamic v, [double def = 0]) => v is num ? v.toDouble() : def;
    int i(dynamic v, [int def = 0]) => v is num ? v.toInt() : def;
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
      zoomMax: d(zoom['max'], 4),
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
    );
  }
}

class WsClient extends ChangeNotifier {
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  int _msgId = 0;
  bool _connected = false;
  String _serverUri = '';
  CameraState _state = CameraState.empty;
  String? _lastError;
  int _lastLatencyMs = 0;
  DateTime? _lastPingSent;

  bool _connecting = false;
  bool get connected => _connected && _state.connected;
  bool get socketOpen => _connected;
  bool get connecting => _connecting;
  String get serverUri => _serverUri;
  CameraState get state => _state;
  String? get lastError => _lastError;
  int get lastLatencyMs => _lastLatencyMs;

  Future<String?> loadLastServer() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getString('last_server');
  }

  Future<void> _saveLastServer(String uri) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString('last_server', uri);
  }

  Future<void> connect(String hostPort) async {
    await close();
    final uri = Uri.parse('ws://$hostPort/v1');
    _serverUri = hostPort;
    _connecting = true;
    _lastError = null;
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
          if (_lastError == null) {
            _lastError = 'disconnected — bridge closed the socket or it was unreachable';
          }
          notifyListeners();
        },
      );
      // wait for the underlying socket to actually be ready, with a timeout
      try {
        await ch.ready.timeout(const Duration(seconds: 6));
      } on TimeoutException {
        _lastError = 'timed out — could not reach $hostPort. Check Mac firewall + IP.';
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
      _send({'action': 'hello', 'id': _id(), 'client': {
        'name': 'OBSBOT Control', 'version': '1.0.0'
      }});
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
      if (j['event'] == 'state') {
        _state = CameraState.fromEvent(j);
        notifyListeners();
      } else if (j['type'] == 'pong') {
        if (_lastPingSent != null) {
          _lastLatencyMs = DateTime.now().difference(_lastPingSent!).inMilliseconds;
          _lastPingSent = null;
          notifyListeners();
        }
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

  void ptzAngle({required double yaw, required double pitch}) {
    _send({'action': 'ptz.angle', 'id': _id(), 'yaw': yaw, 'pitch': pitch});
  }

  void ptzVelocity({double yawSpeed = 0, double pitchSpeed = 0}) {
    _send({
      'action': 'ptz.velocity',
      'id': _id(),
      'yaw_speed': yawSpeed,
      'pitch_speed': pitchSpeed,
      'roll_speed': 0,
    });
  }

  void ptzStop() => _send({'action': 'ptz.stop', 'id': _id()});
  void ptzRecenter() => _send({'action': 'ptz.recenter', 'id': _id()});

  void zoomSet(double value) =>
      _send({'action': 'zoom.set', 'id': _id(), 'value': value});

  void aiSetMode(String mode, [String sub = 'normal']) =>
      _send({'action': 'ai.set_mode', 'id': _id(), 'mode': mode, 'sub_mode': sub});

  void hdr(bool e) =>
      _send({'action': 'image.set_hdr', 'id': _id(), 'enabled': e});

  void fov(int f) =>
      _send({'action': 'image.set_fov', 'id': _id(), 'fov': f});

  void presetSave(int id, String name) =>
      _send({'action': 'preset.save', 'id': _id(), 'preset_id': id, 'name': name});

  void presetRecall(int id) =>
      _send({'action': 'preset.recall', 'id': _id(), 'preset_id': id});

  void runStatus(String s) =>
      _send({'action': 'system.run_status', 'id': _id(), 'status': s});
}
