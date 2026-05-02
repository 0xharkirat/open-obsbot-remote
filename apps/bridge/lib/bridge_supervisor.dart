import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Status of the bundled obsbot-bridge binary.
enum BridgeStatus { stopped, starting, running, error }

/// What we currently know about the macOS camera-access TCC state, parsed
/// from the bridge subprocess log.
enum CameraPermission {
  unknown, // bridge hasn't tried to open the camera yet
  granted, // capture session started OR devices visible
  denied, // explicit denial from AVAuthorizationStatus
  noCamera, // permission OK but no Tiny 2 Lite found
}

class BridgeSupervisor extends ChangeNotifier {
  Process? _proc;
  BridgeStatus _status = BridgeStatus.stopped;
  final List<String> _logTail = <String>[]; // last 200 lines, ring-buffered
  static const int _maxLog = 200;
  String _detectedSn = '';
  String _detectedModel = '';
  bool _cameraConnected = false;
  String? _lastError;
  int _wsClientCount = 0;
  CameraPermission _cameraPermission = CameraPermission.unknown;
  String _pin = ''; // 6-digit pairing PIN from bridge log
  int _pairedTokenCount = 0;

  // Auto-restart bookkeeping.
  bool _userStopped = false;
  int _autoRestartCount = 0;

  // Disk log: ~/Library/Logs/Open OBSBOT Bridge/bridge.log
  IOSink? _logSink;
  File? _logFile;

  File? get logFile => _logFile;
  String? get logFilePath => _logFile?.path;

  BridgeStatus get status => _status;
  List<String> get logTail => List<String>.unmodifiable(_logTail);
  String get detectedSn => _detectedSn;
  String get detectedModel => _detectedModel;
  bool get cameraConnected => _cameraConnected;
  String? get lastError => _lastError;
  int get wsClientCount => _wsClientCount;
  CameraPermission get cameraPermission => _cameraPermission;
  String get pin => _pin;
  int get pairedTokenCount => _pairedTokenCount;

  /// Returns the path to the bundled obsbot-bridge binary inside the .app.
  /// Falls back to the dev-tree build path if running via `flutter run`.
  Future<String?> _bridgeBinaryPath() async {
    final exe = File(Platform.resolvedExecutable);
    final macosDir = exe.parent;
    final candidates = <String>[
      // Inside .app bundle: Contents/MacOS/obsbot-bridge (sibling)
      '${macosDir.path}/obsbot-bridge',
      // Inside .app bundle: Contents/Resources/obsbot-bridge
      '${macosDir.parent.path}/Resources/obsbot-bridge',
      // Dev tree fallback (running via `flutter run`)
      // .../apps/bridge/build/macos/Build/Products/Debug → ../../../../../bridge_cpp/build/obsbot-bridge
      '${macosDir.path}/../../../../../bridge_cpp/build/obsbot-bridge',
      // Even-further-dev fallback
      '${Directory.current.path}/../bridge_cpp/build/obsbot-bridge',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (await f.exists()) {
        return f.absolute.path;
      }
    }
    return null;
  }

  Future<void> _openLogFile() async {
    if (_logSink != null) return;
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    final dir = Directory('$home/Library/Logs/Open OBSBOT Bridge');
    try {
      await dir.create(recursive: true);
      final f = File('${dir.path}/bridge.log');
      _logFile = f;
      _logSink = f.openWrite(mode: FileMode.append);
      _writeLog(
        '===== OBSBOT Bridge starting at ${DateTime.now().toIso8601String()} =====',
      );
    } catch (_) {
      _logSink = null;
    }
  }

  void _writeLog(String line) {
    final sink = _logSink;
    if (sink == null) return;
    try {
      sink.writeln(line);
    } catch (_) {}
  }

  Future<void> revealLogInFinder() async {
    final f = _logFile;
    if (f == null) return;
    await Process.run('open', <String>['-R', f.path]);
  }

  Future<void> _killStalePortsHolders() async {
    // If a previous bridge subprocess is still listening (e.g. crash + restart),
    // free the ports before we spawn a new one. Best-effort: lsof + kill -9.
    for (final port in <int>[8765, 8766]) {
      try {
        final r = await Process.run('lsof', <String>[
          '-nP',
          '-iTCP:$port',
          '-sTCP:LISTEN',
          '-t',
        ]);
        for (final line in (r.stdout as String).split(RegExp(r'\s+'))) {
          final pid = int.tryParse(line.trim());
          if (pid != null && pid > 1) {
            await Process.run('kill', <String>['-9', '$pid']);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> start() async {
    if (_status == BridgeStatus.running || _status == BridgeStatus.starting) {
      return;
    }
    _userStopped = false;
    _setStatus(BridgeStatus.starting);
    _lastError = null;
    await _openLogFile();
    await _killStalePortsHolders();

    final bin = await _bridgeBinaryPath();
    if (bin == null) {
      _lastError = 'obsbot-bridge binary not found inside the app bundle';
      _setStatus(BridgeStatus.error);
      return;
    }

    // Pass --web-root pointing at the bundled Flutter web build (when running
    // from inside the .app) or at apps/rc/build/web (dev tree).
    final exe = File(Platform.resolvedExecutable);
    final macosDir = exe.parent;
    final webCandidates = <String>[
      '${macosDir.parent.path}/Resources/web', // inside .app
      '${macosDir.path}/../../../../../rc/build/web', // dev tree
      '${Directory.current.path}/../rc/build/web',
    ];
    String? webRoot;
    for (final p in webCandidates) {
      if (await Directory(p).exists()) {
        webRoot = File(p).absolute.path;
        break;
      }
    }

    try {
      final args = <String>['--port', '8765'];
      if (webRoot != null) args.addAll(<String>['--web-root', webRoot]);

      final proc = await Process.start(
        bin,
        args,
        mode: ProcessStartMode.normal,
      );
      _proc = proc;

      // Tail stdout + stderr
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLogLine);
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLogLine);

      proc.exitCode.then((int code) async {
        _proc = null;
        _cameraConnected = false;
        if (code == 0) {
          _setStatus(BridgeStatus.stopped);
        } else {
          _lastError = 'bridge exited with code $code';
          _setStatus(BridgeStatus.error);
        }
        // Auto-restart unless user explicitly stopped via stop().
        // _userStopped flag is set by stop(); cleared by start().
        if (!_userStopped && _autoRestartCount < 5) {
          _autoRestartCount++;
          final delaySec = (_autoRestartCount * _autoRestartCount).clamp(1, 30);
          _writeLog(
            '===== bridge exited unexpectedly; auto-restart attempt $_autoRestartCount in ${delaySec}s =====',
          );
          await Future<void>.delayed(Duration(seconds: delaySec));
          if (!_userStopped) await start();
        }
      });

      _setStatus(BridgeStatus.running);
    } catch (e) {
      _lastError = e.toString();
      _setStatus(BridgeStatus.error);
    }
  }

  Future<void> stop() async {
    _userStopped = true; // suppress auto-restart
    _autoRestartCount = 0;
    final proc = _proc;
    if (proc == null) {
      _setStatus(BridgeStatus.stopped);
      return;
    }
    proc.kill(ProcessSignal.sigterm);
    try {
      await proc.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  void _setStatus(BridgeStatus s) {
    _status = s;
    notifyListeners();
  }

  // log line patterns we care about for status detection
  static final RegExp _activeDevRe = RegExp(
    r'active device:\s+(\S+)\s+\(([^)]+)\)',
  );
  static final RegExp _devUnpluggedRe = RegExp(r'device unplugged');
  static final RegExp _wsConnRe = RegExp(r'ws client connected.*total=(\d+)');
  static final RegExp _wsDisconnRe = RegExp(
    r'ws client disconnected.*total=(\d+)',
  );
  static final RegExp _videoStartedRe = RegExp(
    r'video: capture session started',
  );
  static final RegExp _videoDevicesRe = RegExp(
    r'video: \d+ capture devices visible',
  );
  static final RegExp _videoDeniedRe = RegExp(
    r'video: camera permission denied|video: camera not authorized',
  );
  static final RegExp _videoNoCamRe = RegExp(
    r'video: no matching capture device',
  );
  static final RegExp _pinRe = RegExp(
    r'auth: pairing PIN = (\d{6})\s+\(tokens: (\d+)\)',
  );
  static final RegExp _tokenIssuedRe = RegExp(
    r'auth: token issued \(total: (\d+)\)',
  );
  static final RegExp _tokenRevokedRe = RegExp(r'auth: all tokens revoked');
  static final RegExp _pinRotatedRe = RegExp(
    r'auth: PIN rotated, new PIN = (\d{6})',
  );

  void _onLogLine(String line) {
    if (line.isEmpty) return;
    _writeLog(line);
    _logTail.add(line);
    while (_logTail.length > _maxLog) {
      _logTail.removeAt(0);
    }

    final m = _activeDevRe.firstMatch(line);
    if (m != null) {
      _detectedSn = m.group(1) ?? '';
      _detectedModel = m.group(2) ?? '';
      _cameraConnected = true;
    } else if (_devUnpluggedRe.hasMatch(line)) {
      _cameraConnected = false;
    }

    final c = _wsConnRe.firstMatch(line) ?? _wsDisconnRe.firstMatch(line);
    if (c != null) {
      _wsClientCount = int.tryParse(c.group(1) ?? '0') ?? 0;
    }

    final pm = _pinRe.firstMatch(line);
    if (pm != null) {
      _pin = pm.group(1) ?? '';
      _pairedTokenCount = int.tryParse(pm.group(2) ?? '0') ?? 0;
    }
    final ti = _tokenIssuedRe.firstMatch(line);
    if (ti != null) {
      _pairedTokenCount = int.tryParse(ti.group(1) ?? '0') ?? 0;
    }
    if (_tokenRevokedRe.hasMatch(line)) {
      _pairedTokenCount = 0;
    }
    final pr = _pinRotatedRe.firstMatch(line);
    if (pr != null) {
      _pin = pr.group(1) ?? '';
    }

    if (_videoStartedRe.hasMatch(line) || _videoDevicesRe.hasMatch(line)) {
      _cameraPermission = CameraPermission.granted;
    } else if (_videoDeniedRe.hasMatch(line)) {
      _cameraPermission = CameraPermission.denied;
    } else if (_videoNoCamRe.hasMatch(line)) {
      // permission was OK enough to enumerate; just no camera attached
      _cameraPermission = CameraPermission.noCamera;
    }

    notifyListeners();
  }

  /// Reset all pairing state — deletes auth.json (PIN + tokens) and
  /// restarts the bridge subprocess so a fresh PIN is generated and
  /// every previously-paired phone has to re-enter the PIN.
  Future<void> resetPairing() async {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      final f = File(
        '$home/Library/Application Support/Open OBSBOT Bridge/auth.json',
      );
      if (await f.exists()) await f.delete();
    }
    _pin = '';
    _pairedTokenCount = 0;
    await stop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await start();
  }

  /// Open System Settings → Privacy & Security → Camera so the user can
  /// toggle permission for OBSBOT Bridge.
  Future<void> openSystemCameraSettings() async {
    await Process.run('open', <String>[
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera',
    ]);
  }

  /// Open System Settings → Network → Firewall so the user can allow
  /// incoming connections for the bridge if they dismissed the prompt.
  Future<void> openSystemFirewallSettings() async {
    await Process.run('open', <String>[
      'x-apple.systempreferences:com.apple.preference.security?Firewall',
    ]);
  }

  /// Reset macOS camera-access decisions for THIS bundle so the prompt
  /// fires again next time the bridge subprocess tries to open the camera.
  /// Then restart the bridge to retrigger the prompt.
  Future<void> resetCameraPermissionAndRestart() async {
    final bundleId = await _bundleIdentifier();
    if (bundleId != null && bundleId.isNotEmpty) {
      await Process.run('tccutil', <String>['reset', 'Camera', bundleId]);
    } else {
      // Fallback: nuke all camera decisions (asks every app again).
      await Process.run('tccutil', <String>['reset', 'Camera']);
    }
    _cameraPermission = CameraPermission.unknown;
    await stop();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await start();
  }

  Future<String?> _bundleIdentifier() async {
    // Resolved exec path is .../OBSBOT Bridge.app/Contents/MacOS/<exec>
    final exe = File(Platform.resolvedExecutable);
    final infoPlist = File('${exe.parent.parent.path}/Info.plist');
    if (!await infoPlist.exists()) return null;
    final r = await Process.run('/usr/libexec/PlistBuddy', <String>[
      '-c',
      'Print :CFBundleIdentifier',
      infoPlist.path,
    ]);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  }

  @override
  void dispose() {
    stop();
    _logSink?.flush();
    _logSink?.close();
    _logSink = null;
    super.dispose();
  }
}

/// Returns the Mac's LAN IPv4 addresses suitable for handing to a phone client.
Future<List<String>> getLanAddresses() async {
  final list = <String>[];
  try {
    final ifaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) list.add(addr.address);
      }
    }
  } catch (_) {}
  return list;
}
