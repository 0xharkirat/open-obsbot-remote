import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart' show CupertinoColors, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_prefs.dart';
import 'bridge_supervisor.dart';
import 'footer.dart';
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
        '$home/Library/Application Support/Open OBSBOT Bridge/auth.json');
    if (!await f.exists()) return false;
    final j = json.decode(await f.readAsString()) as Map<String, dynamic>;
    final tokens = j['tokens'] as List<dynamic>?;
    return tokens != null && tokens.isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final prefs = await BridgePrefs.load();
  final paired = await _hasPairedTokens();
  // Handy-style onboarding override: ignore start-hidden when no
  // pairing has happened yet — the user needs the PIN/QR card in
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
        // No setDockVisible(false) call needed — AppDelegate already
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

/// Hardcoded for now; mirrors `version:` in `apps/bridge/pubspec.yaml`.
/// `package_info_plus` would let us read it at runtime but it adds a
/// dependency for a single string. Update both places at release time.
const String _kAppVersion = '1.4.0';

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
      _tray = TrayController(
        supervisor: supervisor,
        onRevealPin: () => _revealRequest.value++,
        version: _kAppVersion,
      );
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
    //   2. `MaterialApp` nested as `home` — but with router OFF
    //      (`home:` set, no `routes`) — gives every descendant the
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

  @override
  void initState() {
    super.initState();
    _lastRevealRequest = widget.revealRequest.value;
    widget.revealRequest.addListener(_onExternalReveal);
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
            ? 'Running — camera connected'
            : 'Running — waiting for camera plug-in';
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
        title: const Text('OBSBOT Bridge'),
        titleWidth: 180,
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
            _sectionHeader(context, 'Status'),
            const SizedBox(height: 6),
            _groupCard(context, <Widget>[
              _cameraPermissionRow(context),
              _divider(context),
              _firewallRow(context),
              _divider(context),
              _statusRow(
                context,
                title: 'Camera',
                subtitle: supervisor.cameraConnected
                    ? '${supervisor.detectedModel}  -  ${supervisor.detectedSn}'
                    : 'Not detected',
                dotColor: supervisor.cameraConnected
                    ? CupertinoColors.systemGreen
                    : MacosColors.systemGrayColor,
              ),
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
            ]),
            const SizedBox(height: 18),
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
                  child: const Text('Reveal'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        DecoratedBox(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1C1C1E)
                : const Color(0xFFF6F6F8),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: Border.all(
              color: isDark
                  ? const Color(0x1FFFFFFF)
                  : const Color(0x14000000),
              width: 0.5,
            ),
          ),
          child: SizedBox(
            height: 220,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
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
              MacosIcon(
                CupertinoIcons.lock_fill,
                color: mutedColor,
                size: 18,
              ),
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
        child: Row(
          children: <Widget>[
            Expanded(child: _pinBlock(ctx)),
            const SizedBox(width: 12),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _toggleReveal,
              child: const Text('Hide'),
            ),
          ],
        ),
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
    final url = 'http://$firstIp:8765/';
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
                  data: url,
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

  Widget _pinBlock(BuildContext ctx) {
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
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${supervisor.pairedTokenCount} paired',
              style: macosTheme.typography.caption1.copyWith(
                color: mutedColor,
              ),
            ),
            const SizedBox(height: 6),
            PushButton(
              controlSize: ControlSize.small,
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
          color: isDark
              ? const Color(0x1FFFFFFF)
              : const Color(0x14000000),
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
        color: isDark
            ? const Color(0x1FFFFFFF)
            : const Color(0x14000000),
      ),
    );
  }

  /// Generic status row inside [_groupCard]. Status dot (leading),
  /// title (bold), subtitle (muted), optional trailing action.
  Widget _statusRow(
    BuildContext ctx, {
    required String title,
    required String subtitle,
    required Color dotColor,
    Widget? trailing,
  }) {
    final macosTheme = MacosTheme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
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
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing,
          ],
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
              controlSize: ControlSize.small,
              secondary: true,
              onPressed: supervisor.openSystemCameraSettings,
              child: const Text('Open Settings'),
            ),
            PushButton(
              controlSize: ControlSize.small,
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
      subtitle: 'If phones cannot connect, allow incoming connections.',
      dotColor: MacosColors.systemGrayColor,
      trailing: PushButton(
        controlSize: ControlSize.small,
        secondary: true,
        onPressed: supervisor.openSystemFirewallSettings,
        child: const Text('Open Settings'),
      ),
    );
  }

  Future<void> _showSettings() async {
    bool startHidden = widget.prefs.startHidden;
    final initial = startHidden;
    await showDialog<void>(
      context: context,
      builder: (BuildContext c) {
        return StatefulBuilder(
          builder: (BuildContext c, void Function(void Function()) setSt) {
            return AlertDialog(
              title: const Text('Settings'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start hidden in menubar'),
                    subtitle: const Text(
                      'Launch directly into the menubar with no window or '
                      'dock icon. Show the window any time from the tray. '
                      'Until at least one phone is paired, the window will '
                      'still appear on launch so you can see the PIN.',
                    ),
                    value: startHidden,
                    onChanged: (bool v) async {
                      setSt(() => startHidden = v);
                      await widget.prefs.setStartHidden(v);
                    },
                  ),
                  if (startHidden != initial)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Theme.of(c).colorScheme.tertiary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Applies on next launch. The dock icon '
                              'already follows the window automatically.',
                              style: TextStyle(
                                color: Theme.of(c).colorScheme.tertiary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1),
                  ),
                  _aboutSection(c),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(c).pop(),
                  child: const Text('Close'),
                ),
              ],
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
    final theme = Theme.of(ctx);
    final mutedStyle = TextStyle(
      color: theme.colorScheme.outline,
      fontSize: 11,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'About',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Text('Version', style: mutedStyle),
          const SizedBox(width: 8),
          SelectableText(
            'v$_kAppVersion',
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontWeight: FontWeight.w600,
            ),
          ),
        ]),
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
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: <Widget>[
            _aboutLink(
              ctx,
              icon: Icons.code,
              label: 'Source code',
              url: 'https://github.com/0xharkirat/open-obsbot-remote',
            ),
            _aboutLink(
              ctx,
              icon: Icons.history,
              label: 'Changelog',
              url:
                  'https://github.com/0xharkirat/open-obsbot-remote/blob/main/CHANGELOG.md',
            ),
            _aboutLink(
              ctx,
              icon: Icons.bug_report_outlined,
              label: 'Report an issue',
              url:
                  'https://github.com/0xharkirat/open-obsbot-remote/issues/new',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Open OBSBOT Bridge — by Hark Singh.\n'
          'Not affiliated with OBSBOT.',
          style: mutedStyle,
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
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(
              label,
              style:
                  TextStyle(color: theme.colorScheme.outline, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style:
                  const TextStyle(fontFamily: 'Menlo', fontSize: 11),
            ),
          ),
          IconButton(
            tooltip: 'Reveal in Finder',
            icon: const Icon(Icons.folder_open, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onTap,
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
    return TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label),
      onPressed: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        }
      },
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
