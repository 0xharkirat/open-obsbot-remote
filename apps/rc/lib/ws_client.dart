import 'dart:async';

import 'package:auth_repository/auth_repository.dart';
import 'package:bridge_repository/bridge_repository.dart';
import 'package:device_repository/device_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Re-export the protocol types so existing consumers of this file keep
// seeing PresetEntry, SequenceStep, SequenceState, DeviceState,
// BridgeState, LoopMode, MoveDurationPreset, etc. without an
// import-path change.
export 'package:obsbot_protocol/obsbot_protocol.dart';

/// [AuthStorage] backed by SharedPreferences. Uses the same
/// `token::<host:port>` keys v1 wrote, so an upgrade keeps its pairing.
class SharedPrefsAuthStorage implements AuthStorage {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  @override
  Future<void> delete(String key) async {
    await (await SharedPreferences.getInstance()).remove(key);
  }
}

/// Presentation-layer facade over the v2 packages.
///
/// v1's WsClient was transport + auth + state + optimistic UI in one
/// 578-line ChangeNotifier. v2 moves each concern into its package
/// (`obsbot_api_client`, `auth_repository`, `bridge_repository`,
/// `device_repository`); this class is what remains - connection
/// lifecycle, which-camera-am-I-controlling selection, UI preferences,
/// and ChangeNotifier fan-out so the existing widget tree keeps its
/// AnimatedBuilder idiom.
///
/// Multi-camera model:
///  - [bridge] is the whole-bridge snapshot (all cameras + who is live).
///  - [selectedDeviceId] is the camera THIS phone is controlling.
///    Selection is local to the phone; two phones can control two
///    different cameras at once.
///  - [state] is the selected camera's snapshot. The getter keeps the
///    v1 name so widgets reading `client.state.hdr` etc. survive.
///  - "Live" (which camera OBS sees) is bridge-global: [activeDeviceId]
///    / [makeLive]. Selection and liveness are deliberately separate -
///    the operator lines up a shot on camera B while camera A is live,
///    then cuts.
class WsClient extends ChangeNotifier {
  WsClient() {
    SharedPreferences.getInstance().then((p) {
      final ms = p.getInt('move_duration_ms');
      if (ms != null) _moveDuration = Duration(milliseconds: ms);
      _gridCrosshair = p.getBool('grid_crosshair') ?? _gridCrosshair;
      _gridCenterLines = p.getBool('grid_center_lines') ?? _gridCenterLines;
      _gridThirds = p.getBool('grid_thirds') ?? _gridThirds;
      _gridReadout = p.getBool('grid_readout') ?? _gridReadout;
      _driveControlStyle =
          p.getString('drive_control_style') ?? _driveControlStyle;
      if (!_disposed) notifyListeners();
    });
  }

  /// Guards every notify that can fire from an async continuation
  /// (prefs load, teardown, fire-and-forget action errors) - calling
  /// notifyListeners() after dispose() trips ChangeNotifier's debug
  /// assert and crashes hot-restart + tests.
  bool _disposed = false;

  // ---- layers (built per-connection) ----
  ObsbotApiClient? _api;
  AuthRepository? _auth;
  BridgeRepository? _bridgeRepo;
  DeviceRepository? _deviceRepo;
  StreamSubscription<BridgeState>? _stateSub;
  StreamSubscription<AuthStatus>? _authSub;

  // ---- connection state ----
  bool _connected = false;
  bool _connecting = false;
  bool _needsPairing = false;
  String _serverUri = '';
  String? _lastError;
  String? _lastAuthError;

  // ---- camera state ----
  BridgeState _bridge = BridgeState.empty;
  String _selectedDeviceId = '';

  // ---- UI preferences (presentation state, not repository state) ----
  Duration _moveDuration = const Duration(milliseconds: 2000);
  bool _gridCrosshair = true;
  bool _gridCenterLines = false;
  bool _gridThirds = false;
  bool _gridReadout = true;

  /// Drive page control style: `"joystick"` or `"buttons"` (default).
  String _driveControlStyle = 'buttons';

  // ---------------------------------------------------------------- views

  bool get socketOpen => _connected;
  bool get connecting => _connecting;
  bool get needsPairing => _needsPairing;
  String get serverUri => _serverUri;
  String? get token => _auth?.token;
  String? get lastError => _lastError;
  String? get lastAuthError => _lastAuthError;

  /// Whole-bridge snapshot: every camera + which one is live.
  BridgeState get bridge => _bridge;
  List<DeviceState> get devices => _bridge.devices;

  /// `device_id` of the camera OBS sees (bridge-global).
  String get activeDeviceId => _bridge.activeDeviceId;

  /// The camera THIS phone is controlling. Falls back live -> first
  /// when the sticky selection vanishes (unplug) or was never made.
  String get selectedDeviceId {
    if (_bridge.deviceById(_selectedDeviceId) != null) {
      return _selectedDeviceId;
    }
    if (_bridge.activeDevice != null) return _bridge.activeDeviceId;
    return _bridge.devices.isEmpty ? '' : _bridge.devices.first.deviceId;
  }

  /// Selected camera's snapshot. Keeps the v1 getter name so the widget
  /// tree (`client.state.hdr`, `state.sequence`, ...) needs no rewrite.
  DeviceState get state =>
      _bridge.deviceById(selectedDeviceId) ?? DeviceState.empty;

  bool get connected => _connected && state.connected;

  /// Point this phone's controls at a different camera. Local only -
  /// does NOT change which camera is live in OBS.
  void selectDevice(String deviceId) {
    _selectedDeviceId = deviceId;
    notifyListeners();
  }

  /// Test-only seam: inject a synthetic [BridgeState] without a live
  /// socket. Widget tests use this to render multi-camera states.
  @visibleForTesting
  void debugSetBridge(BridgeState s) {
    _bridge = s;
    notifyListeners();
  }

  /// Route [deviceId] to OBS (bridge-global). The bridge wakes a
  /// sleeping camera before switching.
  Future<void> makeLive(String deviceId) async {
    final repo = _bridgeRepo;
    if (repo == null) return;
    try {
      await repo.setActiveDevice(deviceId);
    } on ApiException catch (e) {
      _fail(e);
    }
  }

  Future<void> renameDevice(String deviceId, String name) async {
    final repo = _bridgeRepo;
    if (repo == null) return;
    try {
      await repo.renameDevice(deviceId, name);
    } on ApiException catch (e) {
      _fail(e);
    }
  }

  /// MJPEG preview URL for [deviceId] (defaults to the selected
  /// camera). Null until connected + authed.
  Uri? previewUri({String? deviceId}) {
    final repo = _bridgeRepo;
    final tok = token;
    if (repo == null || tok == null || _serverUri.isEmpty) return null;
    final parts = _serverUri.split(':');
    final host = parts.first;
    final wsPort = parts.length > 1 ? int.tryParse(parts[1]) ?? 8765 : 8765;
    return repo.previewUri(
      host: host,
      port: wsPort + 1,
      deviceId: deviceId ?? selectedDeviceId,
      token: tok,
    );
  }

  // ------------------------------------------------------- UI preferences

  bool get gridCrosshair => _gridCrosshair;
  bool get gridCenterLines => _gridCenterLines;
  bool get gridThirds => _gridThirds;
  bool get gridReadout => _gridReadout;
  String get driveControlStyle => _driveControlStyle;
  Duration get moveDuration => _moveDuration;

  Future<void> setDriveControlStyle(String style) async {
    if (style != 'joystick' && style != 'buttons') return;
    _driveControlStyle = style;
    notifyListeners();
    await _setPref((p) => p.setString('drive_control_style', style));
  }

  Future<void> setGridCrosshair(bool v) async {
    _gridCrosshair = v;
    notifyListeners();
    await _setPref((p) => p.setBool('grid_crosshair', v));
  }

  Future<void> setGridCenterLines(bool v) async {
    _gridCenterLines = v;
    notifyListeners();
    await _setPref((p) => p.setBool('grid_center_lines', v));
  }

  Future<void> setGridThirds(bool v) async {
    _gridThirds = v;
    notifyListeners();
    await _setPref((p) => p.setBool('grid_thirds', v));
  }

  Future<void> setGridReadout(bool v) async {
    _gridReadout = v;
    notifyListeners();
    await _setPref((p) => p.setBool('grid_readout', v));
  }

  Future<void> setMoveDuration(Duration d) async {
    _moveDuration = d;
    notifyListeners();
    await _setPref((p) => p.setInt('move_duration_ms', d.inMilliseconds));
  }

  Future<void> _setPref(Future<void> Function(SharedPreferences) f) async =>
      f(await SharedPreferences.getInstance());

  Future<String?> loadLastServer() async =>
      (await SharedPreferences.getInstance()).getString('last_server');

  // ---------------------------------------------------------- connection

  /// Bumped by every connect() and by close(). A connect attempt that
  /// is no longer the newest must not touch shared fields from its
  /// continuations - without this, a double-tap on Connect (or
  /// auto-connect racing a manual entry) let the FIRST attempt's error
  /// path tear down the SECOND attempt's freshly-built layers.
  int _connectGen = 0;

  Future<void> connect(String hostPort) async {
    await close();
    final gen = ++_connectGen;
    _serverUri = hostPort;
    _connecting = true;
    _lastError = null;
    _lastAuthError = null;
    _needsPairing = false;
    notifyListeners();

    try {
      final api = ObsbotApiClient(
        uri: Uri.parse('ws://$hostPort/v1'),
        timeout: const Duration(seconds: 6),
      );
      if (gen != _connectGen) {
        // Superseded while constructing: close our own orphan, leave
        // the newer attempt's fields alone.
        await api.close();
        return;
      }
      _api = api;
      final auth = AuthRepository(
        api: api,
        storage: SharedPrefsAuthStorage(),
        hostPort: hostPort,
      );
      _auth = auth;
      final bridgeRepo = BridgeRepository(api: api);
      _bridgeRepo = bridgeRepo;
      final deviceRepo = DeviceRepository(api: api, bridge: bridgeRepo);
      _deviceRepo = deviceRepo;

      // The merged stream: real bridge state + optimistic overlays.
      _stateSub = deviceRepo.state.listen((BridgeState s) {
        _bridge = s;
        notifyListeners();
      });
      _authSub = auth.status.listen((AuthStatus s) {
        _needsPairing = s == AuthStatus.unauthenticated;
        notifyListeners();
      });

      await auth.authenticate();
      if (gen != _connectGen) return; // superseded mid-handshake
      _connected = true;
      _connecting = false;
      if (auth.current == AuthStatus.authenticated) {
        await bridgeRepo.subscribe();
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('last_server', hostPort);
      notifyListeners();
    } on ApiConnectionException catch (e) {
      if (gen != _connectGen) return;
      _lastError = 'could not reach $hostPort  -  ${e.message}';
      await _teardown();
    } on ApiTimeoutException {
      if (gen != _connectGen) return;
      _lastError = 'timed out  -  could not reach $hostPort.';
      await _teardown();
    } on ApiException catch (e) {
      if (gen != _connectGen) return;
      _lastError = 'connect failed: ${e.message}';
      await _teardown();
    }
  }

  /// Pair using the 6-digit PIN shown in the bridge window.
  /// True on success, false on wrong PIN (with friendly copy in
  /// [lastAuthError] - never the bridge's protocol hint).
  Future<bool> pair(String pin) async {
    final auth = _auth;
    if (auth == null) return false;
    try {
      await auth.pair(pin);
      _lastAuthError = null;
      await _bridgeRepo?.subscribe();
      notifyListeners();
      return true;
    } on PairException {
      _lastAuthError =
          "That PIN didn't match. Check the bridge window and try again.";
      notifyListeners();
      return false;
    } on ApiException catch (e) {
      _lastAuthError = 'pairing failed: ${e.message}';
      notifyListeners();
      return false;
    }
  }

  Future<void> forgetToken() async {
    await _auth?.logOut();
    notifyListeners();
  }

  Future<void> close() async {
    _connectGen++; // supersede any in-flight connect attempt
    await _teardown();
  }

  Future<void> _teardown() async {
    await _stateSub?.cancel();
    _stateSub = null;
    await _authSub?.cancel();
    _authSub = null;
    await _auth?.dispose();
    _auth = null;
    await _deviceRepo?.dispose();
    _deviceRepo = null;
    await _bridgeRepo?.dispose();
    _bridgeRepo = null;
    await _api?.close();
    _api = null;
    _connected = false;
    _connecting = false;
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------- actions
  //
  // Fire-and-forget wrappers keeping v1's void signatures. Each injects
  // the selected camera's device_id. Failures land in [lastError];
  // a revoked token (pairing reset on the bridge) flips the app back
  // to the pair screen.

  void _fire(Future<void> Function(DeviceRepository repo, String id) f) {
    final repo = _deviceRepo;
    final id = selectedDeviceId;
    if (repo == null || id.isEmpty) return;
    f(repo, id).catchError((Object e) {
      if (e is ApiException) _fail(e);
    });
  }

  void _fail(ApiException e) {
    if (_disposed) return;
    if (e is ApiActionException && e.code == 'auth_required') {
      _needsPairing = true;
    } else {
      // Machine code over developer message: the `msg` field is a
      // protocol hint, not user copy (CLAUDE.md #41).
      _lastError = e is ApiActionException ? e.code : e.message;
    }
    notifyListeners();
  }

  void ping() {
    _api
        ?.send(<String, dynamic>{'action': 'ping'})
        .catchError((Object _) => <String, dynamic>{});
  }

  void ptzVelocity({double yawSpeed = 0, double pitchSpeed = 0}) => _fire(
    (r, id) =>
        r.ptzVelocity(deviceId: id, yawSpeed: yawSpeed, pitchSpeed: pitchSpeed),
  );

  void ptzStop() => _fire((r, id) => r.ptzStop(deviceId: id));
  void ptzRecenter() => _fire((r, id) => r.recenter(deviceId: id));

  void zoomSet(double value, {bool terminal = false, Duration? duration}) =>
      _fire(
        (r, id) => r.zoomSet(
          deviceId: id,
          value: value,
          terminal: terminal,
          duration: duration ?? Duration.zero,
        ),
      );

  void aiSetMode(String mode, [String sub = 'normal']) =>
      _fire((r, id) => r.aiSetMode(deviceId: id, mode: mode, subMode: sub));

  void hdr(bool e) => _fire((r, id) => r.hdr(deviceId: id, enabled: e));
  void fov(int f) => _fire((r, id) => r.fov(deviceId: id, fov: f));
  void faceAe(bool e) => _fire((r, id) => r.faceAe(deviceId: id, enabled: e));
  void faceFocus(bool e) =>
      _fire((r, id) => r.faceFocus(deviceId: id, enabled: e));
  void flipH(bool e) => _fire((r, id) => r.flipH(deviceId: id, enabled: e));

  void colorSet({
    int? brightness,
    int? contrast,
    int? saturation,
    int? sharpness,
  }) => _fire(
    (r, id) => r.colorSet(
      deviceId: id,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      sharpness: sharpness,
    ),
  );

  void setExposureMode(String mode) =>
      _fire((r, id) => r.setExposureMode(deviceId: id, mode: mode));
  void setEvBias(double bias) =>
      _fire((r, id) => r.setEvBias(deviceId: id, bias: bias));
  void setAntiFlicker(String mode) =>
      _fire((r, id) => r.setAntiFlicker(deviceId: id, mode: mode));
  void setWbAuto(bool enabled) =>
      _fire((r, id) => r.setWbAuto(deviceId: id, enabled: enabled));
  void setWbTemp(int kelvin) =>
      _fire((r, id) => r.setWbTemp(deviceId: id, kelvin: kelvin));
  void imageRefresh() => _fire((r, id) => r.imageRefresh(deviceId: id));

  void presetSave(int id, String name) =>
      _fire((r, dev) => r.presetSave(deviceId: dev, presetId: id, name: name));

  /// Recall with the user's chosen move duration (the chip strip) when
  /// the caller doesn't override. The duration default is presentation
  /// policy, so it lives here rather than in the repository.
  void presetRecall(int id, {Duration? duration}) => _fire(
    (r, dev) => r.presetRecall(
      deviceId: dev,
      presetId: id,
      duration: duration ?? _moveDuration,
    ),
  );

  void presetDelete(int id) =>
      _fire((r, dev) => r.presetDelete(deviceId: dev, presetId: id));

  void runStatus(String s) =>
      _fire((r, id) => r.runStatus(deviceId: id, status: s));

  // ---- sequencer (per selected camera) ----

  void sequenceSet(
    List<SequenceStep> steps, {
    LoopMode mode = LoopMode.forward,
  }) => _fire((r, id) => r.sequenceSet(deviceId: id, steps: steps, mode: mode));

  void sequenceStart() => _fire((r, id) => r.sequenceStart(deviceId: id));
  void sequenceStop() => _fire((r, id) => r.sequenceStop(deviceId: id));

  void sequenceSaveAs(
    String name,
    List<SequenceStep> steps, {
    LoopMode mode = LoopMode.forward,
  }) => _fire(
    (r, id) =>
        r.sequenceSaveAs(deviceId: id, name: name, steps: steps, mode: mode),
  );

  void sequenceLoad(String name) =>
      _fire((r, id) => r.sequenceLoad(deviceId: id, name: name));
  void sequenceDelete(String name) =>
      _fire((r, id) => r.sequenceDelete(deviceId: id, name: name));

  @override
  void dispose() {
    // Flag FIRST: _teardown() completes asynchronously after
    // super.dispose(), and its trailing notify (plus any in-flight
    // _fire error or the constructor's prefs callback) must become a
    // no-op rather than trip ChangeNotifier's disposed assert.
    _disposed = true;
    _teardown();
    super.dispose();
  }
}
