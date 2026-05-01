import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_supervisor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(560, 480),
      minimumSize: Size(420, 320),
      titleBarStyle: TitleBarStyle.normal,
      title: 'OBSBOT Bridge',
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
      title: 'OBSBOT Bridge',
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
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final BridgeSupervisor supervisor;
  final List<String> lanIps;
  const HomeScreen({super.key, required this.supervisor, required this.lanIps});

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
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    color: _statusColor(context),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_statusLabel(),
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _row(context, 'Camera',
              supervisor.cameraConnected
                ? '${supervisor.detectedModel}  •  ${supervisor.detectedSn}'
                : '— none plugged in —'),
            _row(context, 'Phone clients connected',
                '${supervisor.wsClientCount}'),
            const SizedBox(height: 16),
            Text('Connect from your phone to:',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            ...lanIps.map((ip) => _ipPill(context, '$ip:8765')),
            if (lanIps.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('— offline (no Wi-Fi) —'),
              ),
            const SizedBox(height: 20),
            Text('Bridge log',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Expanded(
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
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
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
            child: Text(k,
                style: TextStyle(color: Theme.of(ctx).colorScheme.outline)),
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
      child: Row(children: <Widget>[
        SizedBox(
          width: 180,
          child: Text('  ',
              style: TextStyle(color: Theme.of(ctx).colorScheme.outline)),
        ),
        Expanded(
          child: SelectableText(
            hostPort,
            style: const TextStyle(
                fontFamily: 'Menlo',
                fontWeight: FontWeight.w600,
                fontSize: 14),
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 16),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: hostPort));
          },
        ),
      ]),
    );
  }
}
