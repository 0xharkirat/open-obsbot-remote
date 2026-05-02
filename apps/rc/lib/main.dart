import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_screen.dart';
import 'control_screen.dart';
import 'host_autodetect_stub.dart'
    if (dart.library.js_interop) 'host_autodetect_web.dart';
import 'pin_entry_screen.dart';
import 'simple_mode_screen.dart';
import 'ws_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const ObsbotApp());
}

class ObsbotApp extends StatefulWidget {
  const ObsbotApp({super.key});
  @override
  State<ObsbotApp> createState() => _ObsbotAppState();
}

class _ObsbotAppState extends State<ObsbotApp> {
  final WsClient client = WsClient();
  bool _simpleMode = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final m = p.getString('mode') ?? 'simple';
      if (mounted) setState(() => _simpleMode = m == 'simple');
    });
    // On web, the page itself was served by the bridge, so we already
    // know its address. Skip the connect screen and auto-dial.
    if (kIsWeb) {
      final hp = autoDetectHostPort();
      if (hp != null && hp.isNotEmpty) {
        client.connect(hp);
      }
    }
  }

  Future<void> _setMode(bool simple) async {
    setState(() => _simpleMode = simple);
    final p = await SharedPreferences.getInstance();
    await p.setString('mode', simple ? 'simple' : 'advanced');
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open OBSBOT Remote',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
      ),
      home: AnimatedBuilder(
        animation: client,
        builder: (BuildContext context, _) {
          // 1) not connected at all → connect screen
          if (!client.socketOpen) {
            return ConnectScreen(client: client);
          }
          // 2) socket open but server demands PIN → pair screen
          if (client.needsPairing || client.token == null) {
            return PinEntryScreen(client: client);
          }
          // 3) authed + camera reporting state → control screens
          if (_simpleMode) {
            return SimpleModeScreen(
              client: client,
              onSwitchAdvanced: () => _setMode(false),
            );
          }
          return ControlScreen(
            client: client,
            onSwitchSimple: () => _setMode(true),
          );
        },
      ),
    );
  }
}
