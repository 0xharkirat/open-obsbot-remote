import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';

/// Connects the bridge UI to its own C++ subprocess over the same
/// WebSocket API the phone uses, so the Mac window renders real
/// per-camera state instead of scraping log lines.
///
/// Auth: this process OWNS auth.json (the supervisor writes/reset it),
/// so we read the first issued token directly. If no token exists yet
/// (fresh install, nothing paired), we pair with our own PIN - the
/// bridge trusts localhost exactly as much as it trusts a phone that
/// knows the PIN, and we know the PIN because we can read the file.
///
/// Reconnects with backoff: the subprocess restarts on camera errors,
/// pairing resets, and user action, and each restart drops the socket.
class LocalBridgeClient extends ChangeNotifier {
  LocalBridgeClient({this.port = 8765});

  final int port;

  BridgeState _state = BridgeState.empty;
  bool _connected = false;
  bool _disposed = false;
  ObsbotApiClient? _api;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retry;

  BridgeState get state => _state;
  bool get connected => _connected;

  static String get _authPath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/Application Support/Open OBSBOT Bridge/auth.json';
  }

  /// Token first; PIN as fallback for the never-paired case.
  static ({String? token, String? pin}) _readAuth() {
    try {
      final j =
          jsonDecode(File(_authPath).readAsStringSync())
              as Map<String, dynamic>;
      final tokens = (j['tokens'] as List<dynamic>?) ?? const <dynamic>[];
      return (
        token: tokens.isNotEmpty ? tokens.first as String : null,
        pin: j['pin'] as String?,
      );
    } on Object {
      return (token: null, pin: null);
    }
  }

  void start() => _connect();

  Future<void> _connect() async {
    if (_disposed) return;
    _retry?.cancel();
    await _teardown();

    try {
      final api = ObsbotApiClient(
        uri: Uri.parse('ws://127.0.0.1:$port/v1'),
        timeout: const Duration(seconds: 5),
      );
      _api = api;
      _sub = api.events.listen(_onFrame, onDone: _onDrop, onError: (_) {});

      final auth = _readAuth();
      try {
        await api.send(<String, dynamic>{
          'action': 'hello',
          if (auth.token != null) 'token': auth.token,
        });
      } on ApiActionException catch (e) {
        // Token missing or revoked: pair with our own PIN.
        if (e.code != 'auth_required' || auth.pin == null) rethrow;
        await api.send(<String, dynamic>{'action': 'pair', 'pin': auth.pin});
      }
      await api.send(<String, dynamic>{'action': 'subscribe'});

      _connected = true;
      notifyListeners();
    } on Object {
      _onDrop();
    }
  }

  void _onFrame(Map<String, dynamic> frame) {
    if (frame['event'] != 'state') return;
    _state = BridgeState.fromEvent(frame);
    notifyListeners();
  }

  void _onDrop() {
    if (_disposed) return;
    _connected = false;
    notifyListeners();
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), _connect);
  }

  Future<void> setActive(String deviceId) => _send(<String, dynamic>{
    'action': 'device.set_active',
    'device_id': deviceId,
  });

  Future<void> rename(String deviceId, String name) => _send(<String, dynamic>{
    'action': 'device.rename',
    'device_id': deviceId,
    'name': name,
  });

  Future<void> _send(Map<String, dynamic> action) async {
    final api = _api;
    if (api == null || !_connected) return;
    try {
      await api.send(action);
    } on ApiException {
      // The next state event (or reconnect) corrects the UI; the bridge
      // window is a monitor, not the primary control surface.
    }
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    await _api?.close();
    _api = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _teardown();
    super.dispose();
  }
}
