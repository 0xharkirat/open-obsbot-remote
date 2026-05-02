import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_supervisor.dart';
import 'footer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(560, 480),
      minimumSize: Size(420, 320),
      titleBarStyle: TitleBarStyle.normal,
      title: 'Open OBSBOT Bridge',
      center: true,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(const ObsbotBridgeApp());
}

class ObsbotBridgeApp extends StatefulWidget {
  const ObsbotBridgeApp({super.key});
  @override
  State<ObsbotBridgeApp> createState() => _ObsbotBridgeAppState();
}

class _ObsbotBridgeAppState extends State<ObsbotBridgeApp> {
  final supervisor = BridgeSupervisor();
  List<String> _lanIps = const <String>[];

  @override
  void initState() {
    super.initState();
    _refreshIps();
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      supervisor.start(); // auto-start on launch
    });
    Timer.periodic(const Duration(seconds: 5), (_) => _refreshIps());
  }

  Future<void> _refreshIps() async {
    final ips = await getLanAddresses();
    if (mounted) setState(() => _lanIps = ips);
  }

  @override
  void dispose() {
    supervisor.stop();
    supervisor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open OBSBOT Bridge',
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
        builder: (BuildContext context, _) =>
            HomeScreen(supervisor: supervisor, lanIps: _lanIps),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final BridgeSupervisor supervisor;
  final List<String> lanIps;
  const HomeScreen({super.key, required this.supervisor, required this.lanIps});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// PIN + QR are hidden by default. User taps "Reveal" to show them long
  /// enough to type / scan, then they auto-hide after 60s. This stops a
  /// shoulder-surfer from grabbing the PIN off an idle Mac.
  bool _revealed = false;
  Timer? _hideTimer;

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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBSBOT Bridge'),
        actions: <Widget>[
          if (supervisor.status == BridgeStatus.running)
            IconButton(
              tooltip: 'Stop bridge',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: supervisor.stop,
            )
          else
            IconButton(
              tooltip: 'Start bridge',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: supervisor.start,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: _statusColor(context),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _statusLabel(),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _cameraPermissionRow(context),
            _row(
              context,
              'Camera',
              supervisor.cameraConnected
                  ? '${supervisor.detectedModel}  •  ${supervisor.detectedSn}'
                  : '— none plugged in —',
            ),
            _row(
              context,
              'Phone clients connected',
              '${supervisor.wsClientCount}  (${supervisor.pairedTokenCount} paired)',
            ),
            const SizedBox(height: 16),
            _revealCard(context),
            if (lanIps.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('— offline (no Wi-Fi) —'),
              ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text('Bridge log', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (supervisor.logFilePath != null) ...<Widget>[
                  Text(
                    supervisor.logFilePath!.replaceAll(
                      Platform.environment['HOME'] ?? '',
                      '~',
                    ),
                    style: TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 10,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    icon: const Icon(Icons.folder_open, size: 14),
                    label: const Text('Reveal'),
                    onPressed: supervisor.revealLogInFinder,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 220,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
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
            const AppFooter(),
          ],
        ),
      ),
    );
  }

  Widget _revealCard(BuildContext ctx) {
    final theme = Theme.of(ctx);
    if (!_revealed) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.lock_outline, color: theme.colorScheme.outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Pairing PIN + QR hidden.\nReveal only when a phone is in front of you.',
                style: TextStyle(
                  color: theme.colorScheme.outline,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: const Icon(Icons.visibility, size: 16),
              label: const Text('Reveal'),
              onPressed: supervisor.pin.isEmpty ? null : _toggleReveal,
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _pinBlock(ctx)),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.visibility_off, size: 14),
              label: const Text('Hide'),
              onPressed: _toggleReveal,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Connect from your phone to:', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (lanIps.isNotEmpty) _qrCard(ctx, lanIps.first),
        ...lanIps.map((ip) => _ipPill(ctx, '$ip:8765')),
        const SizedBox(height: 4),
        Text(
          'Auto-hides in 60 seconds',
          style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  Widget _qrCard(BuildContext ctx, String firstIp) {
    final url = 'http://$firstIp:8765/';
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
              // URL under QR — type if scanning is slow
              SelectableText(
                url,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy URL'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('URL copied'),
                      duration: Duration(milliseconds: 700),
                    ),
                  );
                },
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
                    style: TextStyle(
                      color: theme.colorScheme.outline,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'After the page loads, type the 6-digit PIN above to pair.',
                    style: TextStyle(
                      color: theme.colorScheme.outline,
                      fontSize: 11,
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
    final theme = Theme.of(ctx);
    if (supervisor.pin.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Pairing PIN — generated on first launch',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Pairing PIN',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                supervisor.pin,
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                  color: theme.colorScheme.onPrimaryContainer,
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
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Reset pairing'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
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
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cameraPermissionRow(BuildContext ctx) {
    final theme = Theme.of(ctx);
    String label;
    Color dot;
    Widget? trailing;
    switch (supervisor.cameraPermission) {
      case CameraPermission.granted:
        label = 'Granted';
        dot = Colors.green;
        break;
      case CameraPermission.denied:
        label = 'Denied — click "Open Settings" and turn on OBSBOT Bridge';
        dot = theme.colorScheme.error;
        trailing = Wrap(
          spacing: 6,
          children: <Widget>[
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
              ),
              icon: const Icon(Icons.settings, size: 14),
              label: const Text('Open Settings'),
              onPressed: supervisor.openSystemCameraSettings,
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
              ),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Reset & retry'),
              onPressed: () async {
                await supervisor.resetCameraPermissionAndRestart();
              },
            ),
          ],
        );
        break;
      case CameraPermission.noCamera:
        label = 'Granted (no camera detected yet)';
        dot = Colors.amber;
        break;
      case CameraPermission.unknown:
        label = 'Not determined yet';
        dot = theme.colorScheme.outline;
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 180,
            child: Text(
              'Camera permission',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _row(BuildContext ctx, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 180,
            child: Text(
              k,
              style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
            ),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ipPill(BuildContext ctx, String hostPort) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 180,
            child: Text(
              '  ',
              style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
            ),
          ),
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
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: hostPort));
            },
          ),
        ],
      ),
    );
  }
}
