import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart' show CupertinoColors, CupertinoIcons;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_prefs.dart';
import 'bridge_supervisor.dart';
import 'camera_deck.dart';
import 'footer.dart';
import 'local_bridge_client.dart';
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
    final home = Platform.environment['HOME'];
    if (home == null) return false;
    final f = File(
      '$home/Library/Application Support/Open OBSBOT Bridge/auth.json',
    );
    if (!await f.exists()) return false;
    final j = json.decode(await f.readAsString()) as Map<String, dynamic>;
    final tokens = j['tokens'] as List<dynamic>?;
    return tokens != null && tokens.isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  // Marionette (debug only) lets an AI agent drive this Mac app via the
  // widget tree. Skip it under a test harness - one WidgetsBinding per
  // process. macOS-only app, so dart:io is always available here.
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
    const WindowOptions(
      size: Size(560, 480),
      minimumSize: Size(420, 320),
      titleBarStyle: TitleBarStyle.normal,
      title: 'Open OBSBOT Bridge',
      center: true,
    ),
    () async {
      // Close (red dot / Cmd-W) hides the window; the tray controller
      // intercepts onWindowClose and keeps the bridge subprocess alive.
      // Quit happens only via the tray menu or Cmd-Q from the app menu.
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
  /// watches it so the reveal animation runs regardless of who fired it.
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
    // v1.3 macos_ui shell. Two layers:
    //
    //   1. `MacosApp` at the very top provides MacosTheme (SF Pro
    //      typography, system colours, native window background tint
    //      via macos_window_utils) and a CupertinoApp underneath for
    //      its routing + localizations.
    //   2. `MaterialApp` nested as `home`  -  but with router OFF
    //      (`home:` set, no `routes`)  -  gives every descendant the
    //      MaterialLocalizations + Material context that Scaffold,
    //      AlertDialog, SnackBar, SwitchListTile, SegmentedButton
    //      (gone) and the v1.2.1 forui widgets rely on.
    //
    // Net effect: window chrome reads as a Mac app (system fonts,
    // dark-tinted titlebar), body widgets keep their Material
    // semantics. No widget-by-widget rewrite needed; that's a future
    // PR if/when we decide to embrace MacosScaffold + MacosToolBar.
    return MacosApp(
      title: 'Open OBSBOT Bridge',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: MacosThemeData.light(),
      darkTheme: MacosThemeData.dark(),
      home: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1976D2),
            brightness: Brightness.dark,
          ),
        ),
        home: AnimatedBuilder(
          animation: supervisor,
          builder: (BuildContext context, _) => HomeScreen(
            supervisor: supervisor,
            lanIps: _lanIps,
            revealRequest: _revealRequest,
            prefs: widget.prefs,
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final BridgeSupervisor supervisor;
  final List<String> lanIps;

  /// External reveal trigger (bumped by the macOS tray menu's
  /// "Reveal pairing PIN" item). HomeScreen listens and shows the PIN
  /// for the standard 60-second window.
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
  /// PIN + QR are hidden by default. User taps "Reveal" to show them long
  /// enough to type / scan, then they auto-hide after 60s. This stops a
  /// shoulder-surfer from grabbing the PIN off an idle Mac.
  bool _revealed = false;
  Timer? _hideTimer;
  int _lastRevealRequest = 0;

  /// v2: the window is itself a WS client of the C++ subprocess, so the
  /// Cameras section renders real multi-camera state (per-device rows,
  /// LIVE badge, set-live, rename) instead of log scraping.
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

  Color _statusColor(BuildContext ctx) {
    switch (supervisor.status) {
      case BridgeStatus.running:
        return supervisor.cameraConnected ? Colors.green : Colors.amber;
      case BridgeStatus.starting:
        return Colors.amber;
      case BridgeStatus.error:
        return Theme.of(ctx).colorScheme.error;
      case BridgeStatus.stopped:
        return Theme.of(ctx).colorScheme.outline;
    }
  }

  String _statusLabel() {
    switch (supervisor.status) {
      case BridgeStatus.running:
        return supervisor.cameraConnected
            ? 'Running  -  camera connected'
            : 'Running  -  waiting for camera plug-in';
      case BridgeStatus.starting:
        return 'Starting...';
      case BridgeStatus.error:
        return 'Error: ${supervisor.lastError ?? "unknown"}';
      case BridgeStatus.stopped:
        return 'Stopped';
    }
  }

  @override
  Widget build(BuildContext context) {
    // v1.4.1 native-shape rewrite. Outer chrome is now MacosScaffold +
    // ToolBar (AppKit-style title bar buttons + sectioned content) so
    // the window reads as a real Mac app instead of "Flutter debug
    // console". Body content still uses Material widgets inside the
    // ContentArea - SnackBar (URL copied), AlertDialog (Reset pairing,
    // Settings) and the log monospace box keep their existing
    // semantics. The MaterialApp wrapper above us provides the
    // Localizations + Material context they need.
    final isRunning = supervisor.status == BridgeStatus.running;
    return MacosScaffold(
      toolBar: ToolBar(
        // Logo + title. icon-1024.png has ~10% transparent padding baked
        // in per Apple's macOS app-icon convention - rendering it raw
        // wastes the toolbar's vertical real estate. Scale to 130% with
        // BoxFit.cover inside a clipped 20x20 SizedBox so the actual
        // glyph fills the visible area edge-to-edge.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(5)),
              child: SizedBox(
                width: 20,
                height: 20,
                child: Image.asset(
                  'assets/icon-1024.png',
                  fit: BoxFit.cover,
                  scale: 0.77, // 1 / 1.3
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Text('OBSBOT Bridge'),
          ],
        ),
        titleWidth: 200,
        actions: <ToolbarItem>[
          ToolBarIconButton(
            label: isRunning ? 'Stop' : 'Start',
            icon: MacosIcon(
              isRunning
                  ? CupertinoIcons.stop_circle
                  : CupertinoIcons.play_circle,
            ),
            onPressed: isRunning ? supervisor.stop : supervisor.start,
            showLabel: false,
            tooltipMessage: isRunning ? 'Stop bridge' : 'Start bridge',
          ),
          ToolBarIconButton(
            label: 'Settings',
            icon: const MacosIcon(CupertinoIcons.gear),
            onPressed: _showSettings,
            showLabel: false,
            tooltipMessage: 'Settings',
          ),
        ],
      ),
      children: <Widget>[
        ContentArea(
          builder: (BuildContext context, ScrollController scrollController) {
            return _buildBody(context, scrollController);
          },
        ),
      ],
    );
  }

  /// Body content for the [ContentArea]. Split out so the build() method
  /// stays scoped to the shell. The Material wrapper is required so the
  /// Material-flavoured rows below (TextButton, IconButton, Card chrome,
  /// SnackBar overlay, AlertDialog) still find a Material ancestor when
  /// they paint inside the MacosScaffold.
  Widget _buildBody(BuildContext context, ScrollController scrollController) {
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Hero status row - oversized dot + native macos_ui title
            // typography. Lives outside the Status group so it reads as
            // a banner rather than a row.
            _statusBanner(context),
            const SizedBox(height: 18),
            // Pairing first: the PIN/QR is the thing you open this window for
            // (setting up a phone), so it sits above the fold - no scrolling.
            _sectionHeader(context, 'Pairing'),
            const SizedBox(height: 6),
            _revealCard(context),
            if (lanIps.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Offline - no Wi-Fi network detected.',
                  style: MacosTheme.of(context).typography.subheadline.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            const SizedBox(height: 18),
            _sectionHeader(context, 'Status'),
            const SizedBox(height: 6),
            _groupCard(context, <Widget>[
              _cameraPermissionRow(context),
              _divider(context),
              _statusRow(
                context,
                title: 'Phone clients connected',
                subtitle:
                    '${supervisor.wsClientCount} active  ·  ${supervisor.pairedTokenCount} paired',
                dotColor: supervisor.wsClientCount > 0
                    ? CupertinoColors.systemGreen
                    : MacosColors.systemGrayColor,
              ),
              // Firewall last (informational hint for users whose phones
              // can't connect; not a measured state).
              _divider(context),
              _firewallRow(context),
            ]),
            const SizedBox(height: 18),
            // v2: per-camera rows replace the single log-scraped Camera
            // row - each attached camera gets its own status dot, LIVE
            // badge, Set live action, and rename. The deck talks to the
            // C++ subprocess over the same WS API the phone uses.
            _sectionHeader(context, 'Cameras'),
            const SizedBox(height: 6),
            _groupCard(context, <Widget>[CameraDeck(client: _bridgeClient)]),
            const SizedBox(height: 18),
            // One Browser Source pointed at active.mjpg replaces OBS
            // scene switching; the URL carries a token, so the row
            // masks it and copies the real thing on demand.
            _sectionHeader(context, 'OBS output'),
            const SizedBox(height: 6),
            _groupCard(context, <Widget>[ObsOutputRow(client: _bridgeClient)]),
            const SizedBox(height: 20),
            _logSection(context),
            const AppFooter(),
          ],
        ),
      ),
    );
  }

  /// "Bridge log" section header with reveal-in-Finder action, plus the
  /// scrollable monospace log box, all wrapped in the same group-card
  /// chrome as the Status section above.
  Widget _logSection(BuildContext ctx) {
    final macosTheme = MacosTheme.of(ctx);
    final isDark = MacosTheme.brightnessOf(ctx).isDark;
    final mutedColor = isDark
        ? MacosColors.systemGrayColor
        : const MacosColor(0xff6E6E73);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(
                'BRIDGE LOG',
                style: macosTheme.typography.caption1.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: mutedColor,
                ),
              ),
              const Spacer(),
              if (supervisor.logFilePath != null) ...<Widget>[
                Flexible(
                  child: Text(
                    supervisor.logFilePath!.replaceAll(
                      Platform.environment['HOME'] ?? '',
                      '~',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 10,
                      color: mutedColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PushButton(
                  controlSize: ControlSize.small,
                  secondary: true,
                  onPressed: supervisor.revealLogInFinder,
                  child: const Text('Open'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        DecoratedBox(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF6F6F8),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: Border.all(
              color: isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
              width: 0.5,
            ),
          ),
          child: SizedBox(
            height: 220,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: ListView.builder(
                itemCount: supervisor.logTail.length,
                itemBuilder: (BuildContext ctx, int i) {
                  return SelectableText(
                    supervisor.logTail[i],
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _revealCard(BuildContext ctx) {
    final macosTheme = MacosTheme.of(ctx);
    final mutedColor = MacosTheme.brightnessOf(ctx).isDark
        ? MacosColors.systemGrayColor
        : const MacosColor(0xff6E6E73);
    if (!_revealed) {
      return _groupCard(ctx, <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: <Widget>[
              MacosIcon(CupertinoIcons.lock_fill, color: mutedColor, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'PIN and QR hidden',
                      style: macosTheme.typography.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Reveal only when a phone is in front of you.',
                      style: macosTheme.typography.subheadline.copyWith(
                        color: mutedColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              PushButton(
                controlSize: ControlSize.regular,
                onPressed: supervisor.pin.isEmpty ? null : _toggleReveal,
                child: const Text('Reveal'),
              ),
            ],
          ),
        ),
      ]);
    }
    return _groupCard(ctx, <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        // Hide button moved into _pinBlock's right column so it stacks
        // cleanly under Reset pairing instead of floating off to the
        // far right of the row at a different baseline.
        child: _pinBlock(ctx, onHide: _toggleReveal),
      ),
      if (lanIps.isNotEmpty) ...<Widget>[
        _divider(ctx),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Connect from your phone to',
                style: macosTheme.typography.body.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              _qrCard(ctx, lanIps.first),
              for (final ip in lanIps.skip(1)) _ipPill(ctx, '$ip:8765'),
              const SizedBox(height: 8),
              Text(
                'Auto-hides in 60 seconds',
                style: macosTheme.typography.caption1.copyWith(
                  color: mutedColor,
                ),
              ),
            ],
          ),
        ),
      ],
    ]);
  }

  Widget _qrCard(BuildContext ctx, String firstIp) {
    // The connection LINK carries the PIN in the URL FRAGMENT, which a
    // browser never sends over the network. One link, three consumers: a
    // phone browser opens the web remote and it pairs itself; the phone
    // app's Scan QR parses it; a desktop remote pastes it via Copy link.
    // Only ever rendered inside the reveal-gated card, same as the PIN.
    final url = 'http://$firstIp:8765/';
    final link = supervisor.pin.isEmpty
        ? url
        : '$url#pair?pin=${supervisor.pin}';
    final macosTheme = MacosTheme.of(ctx);
    final mutedColor = MacosTheme.brightnessOf(ctx).isDark
        ? MacosColors.systemGrayColor
        : const MacosColor(0xff6E6E73);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: QrImageView(
                  data: link,
                  version: QrVersions.auto,
                  size: 140,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // URL under QR - type if scanning is slow
              SelectableText(
                url,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  PushButton(
                    controlSize: ControlSize.small,
                    secondary: true,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('URL copied'),
                          duration: Duration(milliseconds: 700),
                        ),
                      );
                    },
                    child: const Text('Copy URL'),
                  ),
                  const SizedBox(width: 6),
                  // The pairing link (URL + PIN fragment): paste into the
                  // desktop or phone app's Connect screen to connect AND
                  // pair in one step.
                  PushButton(
                    controlSize: ControlSize.small,
                    secondary: true,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: link));
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Pairing link copied'),
                          duration: Duration(milliseconds: 700),
                        ),
                      );
                    },
                    child: const Text('Copy link'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Scan or type the URL on any phone to open the web remote.',
                    style: macosTheme.typography.subheadline.copyWith(
                      color: mutedColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'After the page loads, type the 6-digit PIN above to pair.',
                    style: macosTheme.typography.caption1.copyWith(
                      color: mutedColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pinBlock(BuildContext ctx, {VoidCallback? onHide}) {
    final macosTheme = MacosTheme.of(ctx);
    final isDark = MacosTheme.brightnessOf(ctx).isDark;
    final mutedColor = isDark
        ? MacosColors.systemGrayColor
        : const MacosColor(0xff6E6E73);
    if (supervisor.pin.isEmpty) {
      return Text(
        'Pairing PIN - generated on first launch',
        style: macosTheme.typography.body.copyWith(color: mutedColor),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'PAIRING PIN',
              style: macosTheme.typography.caption1.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: mutedColor,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              supervisor.pin,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: 6,
              ),
            ),
          ],
        ),
        const Spacer(),
        // Right-side controls: paired count + Reset pairing + Hide
        // all stacked in a single column so they share x-baseline and
        // visually group as "the actions for this PIN".
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${supervisor.pairedTokenCount} paired',
              style: macosTheme.typography.caption1.copyWith(color: mutedColor),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (BuildContext c) => AlertDialog(
                        title: const Text('Reset pairing?'),
                        content: const Text(
                          'This deletes the PIN and revokes every paired phone. '
                          'A new PIN will be generated. Each phone has to re-enter it.',
                        ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.of(c).pop(false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(c).pop(true),
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await supervisor.resetPairing();
                    }
                  },
                  child: const Text('Reset pairing'),
                ),
                if (onHide != null) ...<Widget>[
                  const SizedBox(width: 6),
                  PushButton(
                    controlSize: ControlSize.regular,
                    secondary: true,
                    onPressed: onHide,
                    child: const Text('Hide'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ],
    );
  }

  // ---- v1.4.1 macos_ui status section helpers ----

  /// Hero banner above the Status group. Big status dot + title3
  /// typography in MacosTheme. Reads as a glanceable indicator rather
  /// than just another row.
  Widget _statusBanner(BuildContext ctx) {
    final macosTheme = MacosTheme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: _statusColor(ctx),
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: _statusColor(ctx).withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 0,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusLabel(),
              style: macosTheme.typography.title3.copyWith(
                fontWeight: MacosFontWeight.w590,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Section header above a grouped list (Status / Pairing / etc.).
  /// SF-style: caps + tighter tracking + muted color.
  Widget _sectionHeader(BuildContext ctx, String label) {
    final macosTheme = MacosTheme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Text(
        label.toUpperCase(),
        style: macosTheme.typography.caption1.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: MacosTheme.brightnessOf(ctx).isDark
              ? MacosColors.systemGrayColor
              : const MacosColor(0xff6E6E73),
        ),
      ),
    );
  }

  /// Card container that groups a list of rows with a subtle background
  /// + rounded corners, matching the System Settings group style.
  Widget _groupCard(BuildContext ctx, List<Widget> children) {
    final isDark = MacosTheme.brightnessOf(ctx).isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0x14FFFFFF)
            : MacosColors.controlBackgroundColor.color,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// 1px inset divider between rows in a [_groupCard].
  Widget _divider(BuildContext ctx) {
    final isDark = MacosTheme.brightnessOf(ctx).isDark;
    return Padding(
      padding: const EdgeInsets.only(left: 36),
      child: Container(
        height: 0.5,
        color: isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
      ),
    );
  }

  /// Generic status row inside [_groupCard]. Status dot (leading) - or
  /// an info icon when [informational] is true (signals "this is a
  /// hint, not a state we measured"); title (bold); subtitle (muted);
  /// optional trailing action.
  Widget _statusRow(
    BuildContext ctx, {
    required String title,
    required String subtitle,
    required Color dotColor,
    Widget? trailing,
    bool informational = false,
  }) {
    final macosTheme = MacosTheme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          if (informational)
            MacosIcon(
              CupertinoIcons.info_circle,
              size: 14,
              color: MacosColors.systemGrayColor,
            )
          else
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: macosTheme.typography.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: macosTheme.typography.subheadline.copyWith(
                    color: MacosTheme.brightnessOf(ctx).isDark
                        ? MacosColors.systemGrayColor
                        : const MacosColor(0xff6E6E73),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _cameraPermissionRow(BuildContext ctx) {
    String title;
    String subtitle;
    Color dot;
    Widget? trailing;
    switch (supervisor.cameraPermission) {
      case CameraPermission.granted:
        title = 'Camera permission';
        subtitle = 'Granted';
        dot = CupertinoColors.systemGreen;
        break;
      case CameraPermission.denied:
        title = 'Camera permission';
        subtitle = 'Denied - turn on OBSBOT Bridge in System Settings';
        dot = CupertinoColors.systemRed;
        trailing = Wrap(
          spacing: 6,
          children: <Widget>[
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: supervisor.openSystemCameraSettings,
              child: const Text('Open Settings'),
            ),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: () async {
                await supervisor.resetCameraPermissionAndRestart();
              },
              child: const Text('Reset & retry'),
            ),
          ],
        );
        break;
      case CameraPermission.noCamera:
        title = 'Camera permission';
        subtitle = 'Granted (no camera detected yet)';
        dot = CupertinoColors.systemYellow;
        break;
      case CameraPermission.unknown:
        title = 'Camera permission';
        subtitle = 'Not determined yet';
        dot = MacosColors.systemGrayColor;
        break;
    }
    return _statusRow(
      ctx,
      title: title,
      subtitle: subtitle,
      dotColor: dot,
      trailing: trailing,
    );
  }

  Widget _firewallRow(BuildContext ctx) {
    return _statusRow(
      ctx,
      title: 'Network firewall',
      subtitle:
          'If phones cannot connect: Firewall settings -> Options... '
          '-> allow obsbot-bridge to accept incoming connections.',
      dotColor: MacosColors.systemGrayColor,
      // We can't query firewall state from a non-privileged app; the
      // row is a hint rather than a measurement. Info icon makes
      // that explicit so the grey colour doesn't read as "broken".
      informational: true,
      trailing: PushButton(
        controlSize: ControlSize.regular,
        secondary: true,
        onPressed: supervisor.openSystemFirewallSettings,
        child: const Text('Open Firewall Settings'),
      ),
    );
  }

  Future<void> _showSettings() async {
    bool startHidden = widget.prefs.startHidden;
    final initial = startHidden;
    // Native macOS sheet, not a Material AlertDialog - the shell is macos_ui
    // (v1.4.1 native pass) and this dialog was the one Material island left:
    // Material switch + dialog chrome read wrong against MacosScaffold.
    // Hand-rolled route instead of showMacosSheet: its default transition
    // scale-pops on open, which reads as a glitch, not macOS. A plain quick
    // fade matches how AppKit presents centered panels.
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Settings',
      barrierColor: const Color(0x33000000),
      transitionDuration: const Duration(milliseconds: 160),
      transitionBuilder:
          (BuildContext c, Animation<double> anim, _, Widget child) {
            return FadeTransition(
              opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
              child: child,
            );
          },
      pageBuilder: (BuildContext c, _, _) {
        final MacosTypography type = MacosTheme.of(c).typography;
        return StatefulBuilder(
          builder: (BuildContext c, void Function(void Function()) setSt) {
            // Center + transparent Material: showGeneralDialog gives a raw
            // fullscreen page (no centering), and SelectableText's context
            // menu wants a Material ancestor the macos_ui route never had.
            return Center(
              child: Material(
                type: MaterialType.transparency,
                child: MacosSheet(
                  insetPadding: const EdgeInsets.symmetric(
                    horizontal: 60,
                    vertical: 40,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Settings', style: type.title2),
                          const SizedBox(height: 14),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      'Start hidden in menubar',
                                      style: type.body,
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'Launch directly into the menubar with no '
                                      'window or dock icon. Show the window any '
                                      'time from the tray. Until at least one '
                                      'phone is paired, the window will still '
                                      'appear on launch so you can see the PIN.',
                                      style: type.caption1.copyWith(
                                        color: MacosColors.systemGrayColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              MacosSwitch(
                                value: startHidden,
                                onChanged: (bool v) async {
                                  setSt(() => startHidden = v);
                                  await widget.prefs.setStartHidden(v);
                                },
                              ),
                            ],
                          ),
                          if (startHidden != initial)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                children: <Widget>[
                                  const MacosIcon(
                                    CupertinoIcons.info_circle,
                                    size: 14,
                                    color: MacosColors.systemGrayColor,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Applies on next launch. The dock icon '
                                      'already follows the window automatically.',
                                      style: type.caption1.copyWith(
                                        color: MacosColors.systemGrayColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Container(
                              height: 1,
                              color: MacosTheme.of(c).dividerColor,
                            ),
                          ),
                          _aboutSection(c),
                          const SizedBox(height: 16),
                          Align(
                            alignment: Alignment.centerRight,
                            child: PushButton(
                              controlSize: ControlSize.regular,
                              onPressed: () => Navigator.of(c).pop(),
                              child: const Text('Close'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// "About" block at the bottom of the Settings dialog. Mirrors the
  /// Handy / Tauri convention: version, log + app-data directories
  /// (clickable to open in Finder), source / changelog / issues links,
  /// and a short credit line.
  Widget _aboutSection(BuildContext ctx) {
    final MacosTypography type = MacosTheme.of(ctx).typography;
    final TextStyle mutedStyle = type.caption1.copyWith(
      color: MacosColors.systemGrayColor,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'About',
          style: type.caption1.copyWith(
            color: MacosTheme.of(ctx).primaryColor,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Text('Version', style: mutedStyle),
            const SizedBox(width: 8),
            SelectableText(
              'v$_kAppVersion',
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (supervisor.logFilePath != null)
          _aboutRow(
            ctx,
            label: 'Log directory',
            value: supervisor.logFilePath!.replaceAll(
              Platform.environment['HOME'] ?? '',
              '~',
            ),
            onTap: supervisor.revealLogInFinder,
          ),
        _aboutRow(
          ctx,
          label: 'App data',
          value: '~/Library/Application Support/Open OBSBOT Bridge/',
          onTap: () => _openInFinder(
            '${Platform.environment['HOME']}/Library/Application Support/Open OBSBOT Bridge',
          ),
        ),
        const SizedBox(height: 12),
        // Single-line footer. Inline GitHub link replaces the trio of
        // labelled link buttons (Source / Changelog / Report) which
        // overflowed past the AlertDialog's Close button. The repo
        // home page already has Changelog + Issues tabs one click in,
        // so one link is enough.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              'by Hark Singh with OBSBOT SDK + Flutter  ',
              style: mutedStyle,
            ),
            _aboutLink(
              ctx,
              icon: Icons.open_in_new,
              label: 'GitHub',
              url: 'https://github.com/0xharkirat/open-obsbot-remote',
            ),
          ],
        ),
      ],
    );
  }

  Widget _aboutRow(
    BuildContext ctx, {
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final MacosTypography type = MacosTheme.of(ctx).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: type.caption1.copyWith(color: MacosColors.systemGrayColor),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
            ),
          ),
          MacosTooltip(
            message: 'Reveal in Finder',
            child: MacosIconButton(
              icon: const MacosIcon(CupertinoIcons.folder, size: 14),
              padding: EdgeInsets.zero,
              boxConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onTap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutLink(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required String url,
  }) {
    // Small secondary PushButton: the inline-with-text micro-affordance size
    // (the same rule as the Copy URL button under the QR).
    return PushButton(
      controlSize: ControlSize.small,
      secondary: true,
      onPressed: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          MacosIcon(icon, size: 12),
          const SizedBox(width: 4),
          Text(label),
        ],
      ),
    );
  }

  void _openInFinder(String path) {
    Process.run('open', <String>[path]);
  }

  Widget _ipPill(BuildContext ctx, String hostPort) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              hostPort,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          MacosIconButton(
            backgroundColor: Colors.transparent,
            icon: MacosIcon(
              CupertinoIcons.doc_on_clipboard,
              color: MacosTheme.brightnessOf(ctx).isDark
                  ? MacosColors.systemGrayColor
                  : const MacosColor(0xff6E6E73),
              size: 14,
            ),
            semanticLabel: 'Copy URL',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: hostPort));
            },
          ),
        ],
      ),
    );
  }
}
