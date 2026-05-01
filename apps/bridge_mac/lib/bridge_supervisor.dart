import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Status of the bundled obsbot-bridge binary.
enum BridgeStatus { stopped, starting, running, error }

/// What we currently know about the macOS camera-access TCC state, parsed
/// from the bridge subprocess log.
enum CameraPermission {
  unknown,    // bridge hasn't tried to open the camera yet
  granted,    // capture session started OR devices visible
  denied,     // explicit denial from AVAuthorizationStatus
  noCamera,   // permission OK but no Tiny 2 Lite found
}

class BridgeSupervisor extends ChangeNotifier {
  Process? _proc;
  BridgeStatus _status = BridgeStatus.stopped;
  final List<String> _logTail = <String>[];   // last 200 lines, ring-buffered
  static const int _maxLog = 200;
  String _detectedSn = '';
  String _detectedModel = '';
  bool _cameraConnected = false;
  String? _lastError;
  int _wsClientCount = 0;
  CameraPermission _cameraPermission = CameraPermission.unknown;

  // Disk log: ~/Library/Logs/OBSBOT Bridge/bridge.log
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
      // .../apps/bridge_mac/build/macos/Build/Products/Debug → ../../../../../bridge_cpp/build/obsbot-bridge
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
    final dir = Directory('$home/Library/Logs/OBSBOT Bridge');
    try {
      await dir.create(recursive: true);
      final f = File('${dir.path}/bridge.log');
      _logFile = f;
      _logSink = f.openWrite(mode: FileMode.append);
      _writeLog('===== OBSBOT Bridge starting at ${DateTime.now().toIso8601String()} =====');
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

  Future<void> start() async {
    if (_status == BridgeStatus.running || _status == BridgeStatus.starting) {
      return;
    }
    _setStatus(BridgeStatus.starting);
    _lastError = null;
    await _openLogFile();

    final bin = await _bridgeBinaryPath();
    if (bin == null) {
      _lastError = 'obsbot-bridge binary not found inside the app bundle';
      _setStatus(BridgeStatus.error);
      return;
    }

    try {
      final proc = await Process.start(
        bin,
        <String>['8765'],
        mode: ProcessStartMode.normal,
      );
      _proc = proc;

      // Tail stdout + stderr
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLogLine);
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLogLine);

      proc.exitCode.then((int code) {
        _proc = null;
        _cameraConnected = false;
        if (code == 0) {
          _setStatus(BridgeStatus.stopped);
        } else {
          _lastError = 'bridge exited with code $code';
          _setStatus(BridgeStatus.error);
        }
      });

      _setStatus(BridgeStatus.running);
    } catch (e) {
      _lastError = e.toString();
      _setStatus(BridgeStatus.error);
    }
  }

  Future<void> stop() async {
    final proc = _proc;
    if (proc == null) {
      _setStatus(BridgeStatus.stopped);
      return;
    }
    proc.kill(ProcessSignal.sigterm);
    // Force-kill if still alive after 2s
    Timer(const Duration(seconds: 2), () {
      if (_proc != null) _proc!.kill(ProcessSignal.sigkill);
    });
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
  static final RegExp _wsDisconnRe = RegExp(r'ws client disconnected.*total=(\d+)');
  static final RegExp _videoStartedRe = RegExp(r'video: capture session started');
  static final RegExp _videoDevicesRe = RegExp(r'video: \d+ capture devices visible');
  static final RegExp _videoDeniedRe = RegExp(r'video: camera permission denied|video: camera not authorized');
  static final RegExp _videoNoCamRe = RegExp(r'video: no matching capture device');

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

    if (_videoStartedRe.hasMatch(line) || _videoDevicesRe.hasMatch(line)) {
      _cameraPermission = CameraPermission.granted;
    } else if (_videoDeniedRe.hasMatch(line)) {
      _cameraPermission = CameraPermission.denied;
    } else if (_videoNoCamRe.hasMatch(line)) {
      // permission was OK enough to enumerate; just no camera attached
      if (_cameraPermission != CameraPermission.granted) {
        _cameraPermission = CameraPermission.granted;
      }
    }

    notifyListeners();
  }

  /// Open System Settings → Privacy & Security → Camera so the user can
  /// toggle permission for OBSBOT Bridge.
  Future<void> openSystemCameraSettings() async {
    await Process.run('open', <String>[
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera',
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
    final r = await Process.run('/usr/libexec/PlistBuddy',
        <String>['-c', 'Print :CFBundleIdentifier', infoPlist.path]);
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
