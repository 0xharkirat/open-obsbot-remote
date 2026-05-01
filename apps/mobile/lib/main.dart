import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ws_client.dart';
import 'control_screen.dart';
import 'connect_screen.dart';

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

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OBSBOT Control',
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
          if (client.connected) {
            return ControlScreen(client: client);
          }
          return ConnectScreen(client: client);
        },
      ),
    );
  }
}
