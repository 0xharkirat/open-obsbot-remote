import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_prefs.dart';
import 'bridge_supervisor.dart';
import 'camera_deck.dart';
import 'health.dart';
import 'langar_theme.dart';
import 'langar_widgets.dart';
import 'local_bridge_client.dart';
import 'platform_paths.dart';
import 'tray_controller.dart';

/// Best-effort check whether the user has ever paired a phone.
///
/// Returns true if `auth.json` exists and contains at least one token.
/// Used as the onboarding override: when start-hidden is true but the
/// user has never paired, force the window visible on launch so they
/// can see the PIN + QR code. Pattern lifted from Handy's
/// AccessibilityOnboarding (auto-show window when something the user
/// needs to see is gated behind a permission/credential).
Future<bool> _hasPairedTokens() async {
  try {
    final f = File(PlatformPaths.authJsonPath);
    if (!await f.exists()) return false;
    final j = json.decode(await f.readAsString()) as Map<String, dynamic>;
    final tokens = j['tokens'] as List<dynamic>?;
    return tokens != null && tokens.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// `--window-size=720x560` opens the window at that logical size. For review
/// captures of the minimum layout; the window manager applies display
/// scaling itself, which an outside resize gets wrong.
Size _windowSize(List<String> args) {
  for (final a in args) {
    final m = RegExp(r'^--window-size=(\d+)x(\d+)$').firstMatch(a);
    if (m != null) {
      return Size(double.parse(m.group(1)!), double.parse(m.group(2)!));
    }
  }
  return const Size(920, 720);
}

Future<void> main(List<String> args) async {
  // Marionette (debug only) lets an AI agent drive this app via the widget
  // tree. Skip it under a test harness - one WidgetsBinding per process.
  // Desktop-only app (macOS, Windows), so dart:io is always here.
  final underTest = Platform.environment.containsKey('FLUTTER_TEST');
  if (kDebugMode && !underTest) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  await windowManager.ensureInitialized();
  final info = await PackageInfo.fromPlatform();
  _kAppVersion = '${info.version} (${info.buildNumber})';
  final prefs = await BridgePrefs.load();
  final paired = await _hasPairedTokens();
  // Handy-style onboarding override: ignore start-hidden when no
  // pairing has happened yet  -  the user needs the PIN/QR card in
  // front of them. Once they've paired at least one phone the
  // start-hidden preference takes effect normally.
  final hideAtLaunch = prefs.startHidden && paired;

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      // 920x720 by default, so the whole first viewport - answer, four
      // places, cameras and the fix panel - is visible without scrolling.
      size: _windowSize(args),
      minimumSize: const Size(720, 560),
      titleBarStyle: TitleBarStyle.normal,
      title: 'Open OBSBOT Bridge',
      center: true,
      backgroundColor: Langar.limewash,
    ),
    () async {
      // Close hides the window; the tray controller intercepts
      // onWindowClose and keeps the bridge subprocess alive. Quit happens
      // only via the tray menu or Cmd-Q from the app menu.
      await windowManager.setPreventClose(true);
      if (hideAtLaunch) {
        await windowManager.hide();
        // No setDockVisible(false) call needed  -  AppDelegate already
        // flipped policy to .accessory before super.didFinishLaunching
        // based on the same pref.
      } else {
        await windowManager.show();
        await windowManager.focus();
        // If start-hidden was on but onboarding override forced us
        // visible, make sure the dock icon is visible too. AppDelegate
        // started us as .accessory; flip back now that we have a window.
        if (prefs.startHidden && !paired) {
          await BridgePrefs.setDockVisible(true);
        }
      }
    },
  );

  runApp(ObsbotBridgeApp(prefs: prefs));
}

/// Read from the built bundle at startup, never hardcoded.
///
/// This used to be a `const` mirroring `version:` in `pubspec.yaml`, on the
/// reasoning that a dependency was too much for one string. That trade was
/// wrong: two sources of truth drift, and the number is the first thing anyone
/// asks for when diagnosing a machine in the field. A version that can lie is
/// worse than no version. Now it comes from the artifact itself, so it is
/// always what is actually running.
String _kAppVersion = '';

class ObsbotBridgeApp extends StatefulWidget {
  final BridgePrefs prefs;
  const ObsbotBridgeApp({super.key, required this.prefs});
  @override
  State<ObsbotBridgeApp> createState() => _ObsbotBridgeAppState();
}

class _ObsbotBridgeAppState extends State<ObsbotBridgeApp> {
  final supervisor = BridgeSupervisor();
  List<String> _lanIps = const <String>[];

  /// Tray-driven "Reveal PIN" toggles this from anywhere; HomeScreen
  /// watches it so the reveal runs regardless of who fired it.
  final ValueNotifier<int> _revealRequest = ValueNotifier<int>(0);
  TrayController? _tray;

  @override
  void initState() {
    super.initState();
    _refreshIps();
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      supervisor.start(); // auto-start on launch
      _tray = TrayController(supervisor: supervisor);
      _tray!.init();
    });
    Timer.periodic(const Duration(seconds: 5), (_) => _refreshIps());
  }

  Future<void> _refreshIps() async {
    final ips = await getLanAddresses();
    if (mounted) setState(() => _lanIps = ips);
  }

  @override
  void dispose() {
    _tray?.dispose();
    supervisor.stop();
    supervisor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open OBSBOT Bridge',
      debugShowCheckedModeBanner: false,
      theme: Langar.theme(),
      home: AnimatedBuilder(
        animation: supervisor,
        builder: (BuildContext context, _) => HomeScreen(
          supervisor: supervisor,
          lanIps: _lanIps,
          revealRequest: _revealRequest,
          prefs: widget.prefs,
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final BridgeSupervisor supervisor;
  final List<String> lanIps;

  /// External reveal trigger (bumped by the tray menu). HomeScreen listens
  /// and shows the PIN for the standard 60-second window.
  final ValueNotifier<int> revealRequest;
  final BridgePrefs prefs;
  const HomeScreen({
    super.key,
    required this.supervisor,
    required this.lanIps,
    required this.revealRequest,
    required this.prefs,
  });
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// PIN + QR are hidden by default. The user shows them long enough to
  /// type or scan, then they hide after 60s. This stops a shoulder-surfer
  /// from reading the PIN off an idle computer.
  bool _revealed = false;
  Timer? _hideTimer;

  /// The firewall note under "Phone cannot connect?".
  bool _firewallHelp = false;
  int _lastRevealRequest = 0;

  /// The window is itself a WS client of the C++ subprocess, so the camera
  /// list renders real multi-camera state instead of log scraping.
  late final LocalBridgeClient _bridgeClient;

  @override
  void initState() {
    super.initState();
    _lastRevealRequest = widget.revealRequest.value;
    widget.revealRequest.addListener(_onExternalReveal);
    _bridgeClient = LocalBridgeClient()..start();
  }

  void _onExternalReveal() {
    if (widget.revealRequest.value > _lastRevealRequest) {
      _lastRevealRequest = widget.revealRequest.value;
      if (!_revealed) _toggleReveal();
    }
  }

  void _toggleReveal() {
    setState(() => _revealed = !_revealed);
    _hideTimer?.cancel();
    if (_revealed) {
      _hideTimer = Timer(const Duration(seconds: 60), () {
        if (mounted) setState(() => _revealed = false);
      });
    }
  }

  BridgeSupervisor get supervisor => widget.supervisor;
  List<String> get lanIps => widget.lanIps;

  @override
  void dispose() {
    widget.revealRequest.removeListener(_onExternalReveal);
    _hideTimer?.cancel();
    _bridgeClient.dispose();
    super.dispose();
  }

  Health _health() {
    final devices = _bridgeClient.state.devices;
    return Health.from(HealthInput(
      bridge: switch (supervisor.status) {
        BridgeStatus.running => BridgeRun.running,
        BridgeStatus.starting => BridgeRun.starting,
        BridgeStatus.stopped => BridgeRun.stopped,
        BridgeStatus.error => BridgeRun.error,
      },
      bridgeError: supervisor.lastError,
      windowConnected: _bridgeClient.connected,
      camerasConnected: devices.where((d) => d.connected).length,
      camerasTotal: devices.length,
      cameraAccessDenied:
          supervisor.cameraPermission == CameraPermission.denied,
      cameraBusy: supervisor.cameraBusy,
      obsReading: supervisor.obsReading,
      wsClients: supervisor.wsClientCount,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bridgeClient,
      builder: (context, _) {
        final health = _health();
        return Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _band(health),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _places(health),
                      const SizedBox(height: 28),
                      LayoutBuilder(
                        builder: (context, c) {
                          final cameras = _section(
                            'Cameras',
                            CameraList(client: _bridgeClient),
                          );
                          final fix = _fixColumn(health);
                          if (c.maxWidth < 760) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                fix,
                                const SizedBox(height: 28),
                                cameras,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(flex: 11, child: cameras),
                              const SizedBox(width: 24),
                              Expanded(flex: 10, child: fix),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---- The runner band: the one answer ---------------------------------

  Widget _band(Health health) {
    return RunnerBand(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 22, 16, 22),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutExpo,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  children: <Widget>[...previous, ?current],
                ),
                child: Column(
                  key: ValueKey<String>('${health.answer}|${health.detail}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Semantics(
                      liveRegion: true,
                      child: Text(health.answer, style: Langar.answer),
                    ),
                    const SizedBox(height: 6),
                    Text(health.detail, style: Langar.answerSub),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Settings',
              onPressed: _showSettings,
              icon: const Icon(Icons.settings_outlined),
              color: Langar.onMaroon,
              style: IconButton.styleFrom(
                foregroundColor: Langar.onMaroon,
                hoverColor: const Color(0x22FFFFFF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- The row of four set places --------------------------------------

  Widget _places(Health health) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < health.places.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 14),
          Expanded(child: PlaceTile(place: health.places[i])),
        ],
      ],
    );
  }

  Widget _section(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(title, style: Langar.heading),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  // ---- The fix column: what needs you, or pairing -----------------------

  /// One fix per place that needs the user, in place order, so no fix hides
  /// behind another. With nothing to fix, the column offers pairing.
  Widget _fixColumn(Health health) {
    final fixes = health.needing.map((p) => p.fix!).toList();
    final children = <Widget>[];
    for (final fix in fixes) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 24));
      children.add(switch (fix) {
        Fix.startBridge => _section('Start the bridge', _bridgeFix()),
        Fix.cameraAccess => _section('Allow camera access', _cameraAccessFix()),
        Fix.cameraBusy => _section('Free the camera', _cameraBusyFix()),
        Fix.plugCamera => _section('Connect a camera', _plugCameraFix()),
        Fix.setUpObs => _section('Connect OBS', _obsFix()),
        Fix.connectPhone => _section('Connect a phone', _pairPanel(attention: true)),
      });
    }
    if (fixes.isEmpty) {
      children.add(_section('Connect another phone', _pairPanel(attention: false)));
    }
    // Proof of where OBS reads from, unless the OBS fix already shows it.
    if (!fixes.contains(Fix.setUpObs) && !fixes.contains(Fix.startBridge)) {
      children
        ..add(const SizedBox(height: 16))
        ..add(ObsOutputField(client: _bridgeClient));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _steps(List<String> steps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 24,
                  child: Text('${i + 1}.', style: Langar.body.copyWith(fontWeight: FontWeight.w700)),
                ),
                Expanded(child: Text(steps[i], style: Langar.body)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bridgeFix() {
    final err = supervisor.lastError;
    return Panel(
      attention: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            err == null ? 'The bridge is stopped.' : 'The bridge stopped: $err',
            style: Langar.body,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: supervisor.start,
                child: const Text('Start the bridge'),
              ),
              if (supervisor.logFilePath != null)
                OutlinedButton(
                  onPressed: supervisor.revealLogInFinder,
                  child: const Text('Open the log'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cameraAccessFix() {
    final windows = Platform.isWindows;
    return Panel(
      attention: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            windows
                ? 'Windows blocks camera access for desktop apps.'
                : 'macOS blocks camera access for Open OBSBOT Bridge.',
            style: Langar.body,
          ),
          const SizedBox(height: 10),
          _steps(windows
              ? <String>[
                  'Click Open camera settings.',
                  'Turn on "Let desktop apps access your camera".',
                ]
              : <String>[
                  'Click Open camera settings.',
                  'Turn on Open OBSBOT Bridge.',
                ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: supervisor.openSystemCameraSettings,
                child: const Text('Open camera settings'),
              ),
              OutlinedButton(
                onPressed: supervisor.resetCameraPermissionAndRestart,
                child: const Text('Try again'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cameraBusyFix() {
    return Panel(
      attention: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'A different app is using the camera. Only one app can use it at a time.',
            style: Langar.body,
          ),
          const SizedBox(height: 10),
          _steps(const <String>[
            'Quit OBSBOT Center, if it is open.',
            'In OBS, remove any Video Capture Device that uses the OBSBOT.',
          ]),
          const SizedBox(height: 4),
          const Text(
            'The picture comes back in 2 seconds. You do not need to restart.',
            style: Langar.meta,
          ),
        ],
      ),
    );
  }

  Widget _plugCameraFix() {
    return Panel(
      attention: true,
      child: _steps(const <String>[
        'Connect the OBSBOT camera to this computer with a USB cable.',
        'Quit OBSBOT Center, if it is open.',
        'Wait up to 20 seconds. The camera shows in the list.',
      ]),
    );
  }

  Widget _obsFix() {
    final url = obsUrl(_bridgeClient.token);
    return Panel(
      attention: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _steps(const <String>[
            'In OBS, add a Media Source.',
            'Turn off Local File.',
            'Paste this into Input. Set Input Format to mjpeg.',
          ]),
          const SizedBox(height: 6),
          CopyField(
            label: 'Input',
            shown: url == null
                ? 'Waiting for the bridge'
                : 'http://localhost:8766/preview/active.mjpg?t=••••••••',
            copyText: url,
          ),
          const SizedBox(height: 12),
          const CopyField(
            label: 'FFmpeg Options',
            shown: obsFfmpegOptions,
            copyText: obsFfmpegOptions,
          ),
          const SizedBox(height: 10),
          const Text(
            'Do not add the OBSBOT as a Video Capture Device in OBS.',
            style: Langar.meta,
          ),
        ],
      ),
    );
  }

  Widget _pairPanel({required bool attention}) {
    final address = lanIps.isEmpty ? null : '${lanIps.first}:8765';
    if (address == null) {
      return const Panel(
        attention: true,
        child: Text(
          'This computer is not on a network. Connect it to the Wi-Fi.',
          style: Langar.body,
        ),
      );
    }
    final url = 'http://$address/';
    final pin = supervisor.pin;
    final link = pin.isEmpty ? url : '$url#pair?pin=$pin';
    return Panel(
      attention: attention,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Open this on your phone', style: Langar.title),
          const SizedBox(height: 2),
          const Text('Use the same Wi-Fi as this computer.', style: Langar.meta),
          const SizedBox(height: 10),
          SelectableText(address, style: Langar.value),
          for (final ip in lanIps.skip(1))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SelectableText('or $ip:8765', style: Langar.meta),
            ),
          const SizedBox(height: 14),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutExpo,
            alignment: Alignment.topLeft,
            child: _revealed && pin.isNotEmpty
                ? _revealedPin(pin, link)
                : FilledButton.icon(
                    onPressed: pin.isEmpty ? null : _toggleReveal,
                    icon: const Icon(Icons.qr_code_2, size: 20),
                    label: const Text('Show PIN and QR code'),
                  ),
          ),
          const SizedBox(height: 12),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                supervisor.pairedTokenCount == 1
                    ? '1 device paired.'
                    : '${supervisor.pairedTokenCount} devices paired.',
                style: Langar.meta,
              ),
              TextButton(
                onPressed: () => setState(() => _firewallHelp = !_firewallHelp),
                child: const Text('Phone cannot connect?'),
              ),
            ],
          ),
          if (_firewallHelp) ...<Widget>[
            const SizedBox(height: 4),
            const Text(
              'Make sure the phone uses the same Wi-Fi. Then allow Open OBSBOT '
              'Bridge in the firewall.',
              style: Langar.body,
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: supervisor.openSystemFirewallSettings,
              child: const Text('Open firewall settings'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _revealedPin(String pin, String link) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(Langar.radiusSmall),
            border: Border.all(color: Langar.line),
          ),
          child: QrImageView(
            data: link,
            size: 132,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Langar.ink),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Langar.ink,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('PIN', style: Langar.meta),
              SelectableText(
                pin,
                style: Langar.value.copyWith(fontSize: 34, letterSpacing: 6),
              ),
              const SizedBox(height: 2),
              const Text('Scan the code, or type the PIN. Hides in 60 seconds.', style: Langar.meta),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: link));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Pairing link copied'),
                          duration: Duration(milliseconds: 1200),
                        ),
                      );
                    },
                    child: const Text('Copy link'),
                  ),
                  TextButton(onPressed: _toggleReveal, child: const Text('Hide')),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Settings ----------------------------------------------------------

  Future<void> _showSettings() async {
    bool startHidden = widget.prefs.startHidden;
    final initial = startHidden;
    final trayWord = Platform.isWindows ? 'notification area' : 'menu bar';
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setSt) => AlertDialog(
          title: const Text('Settings'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('Start hidden', style: Langar.title),
                          const SizedBox(height: 2),
                          Text(
                            'Open in the $trayWord with no window. Until a phone is '
                            'paired, the window still opens so you can see the PIN.',
                            style: Langar.meta,
                          ),
                          if (startHidden != initial)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text('Applies the next time the app starts.', style: Langar.meta),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      value: startHidden,
                      onChanged: (v) async {
                        setSt(() => startHidden = v);
                        await widget.prefs.setStartHidden(v);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 12),
                const Text('Pairing', style: Langar.title),
                const SizedBox(height: 2),
                const Text(
                  'Reset pairing makes a new PIN and disconnects every paired phone.',
                  style: Langar.meta,
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    Navigator.of(c).pop();
                    await _confirmResetPairing();
                  },
                  child: const Text('Reset pairing'),
                ),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 12),
                _aboutRow('Version', 'v$_kAppVersion'),
                if (supervisor.logFilePath != null)
                  _aboutRow(
                    'Log',
                    PlatformPaths.displayPath(supervisor.logFilePath!),
                    onOpen: supervisor.revealLogInFinder,
                  ),
                _aboutRow(
                  'App data',
                  PlatformPaths.supportDirLabel,
                  onOpen: () => PlatformPaths.openFolder(PlatformPaths.supportDir),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse('https://github.com/0xharkirat/open-obsbot-remote'),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Open OBSBOT Remote on GitHub'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        Navigator.of(c).pop();
                        if (supervisor.status == BridgeStatus.running) {
                          await supervisor.stop();
                        } else {
                          await supervisor.start();
                        }
                      },
                      child: Text(
                        supervisor.status == BridgeStatus.running
                            ? 'Stop the bridge'
                            : 'Start the bridge',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(c).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _aboutRow(String label, String value, {VoidCallback? onOpen}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(width: 84, child: Text(label, style: Langar.meta)),
          Expanded(child: SelectableText(value, style: Langar.body.copyWith(fontSize: 14))),
          if (onOpen != null)
            IconButton(
              tooltip: 'Show in ${PlatformPaths.fileManagerName}',
              icon: const Icon(Icons.folder_open_outlined, size: 20),
              onPressed: onOpen,
            ),
        ],
      ),
    );
  }

  Future<void> _confirmResetPairing() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reset pairing?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'This makes a new PIN and disconnects every paired phone. '
            'Each phone must enter the new PIN.',
            style: Langar.body,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Reset pairing'),
          ),
        ],
      ),
    );
    if (ok == true) await supervisor.resetPairing();
  }
}
