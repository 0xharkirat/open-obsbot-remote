import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'connect_screen.dart';
import 'flutter_test_detect.dart'
    if (dart.library.io) 'flutter_test_detect_io.dart';
import 'host_autodetect_stub.dart'
    if (dart.library.js_interop) 'host_autodetect_web.dart';
import 'live_screen.dart';
import 'pin_entry_screen.dart';
import 'ws_client.dart';

void main() {
  // Marionette lets an AI agent drive the running app via the widget tree
  // (docs/testing: marionette MCP). Debug-only, and never when a test
  // harness already owns the binding - one WidgetsBinding per process.
  if (kDebugMode && !isRunningFlutterTest) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
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
  void initState() {
    super.initState();
    // On web, the page itself was served by the bridge, so we already
    // know its address. Skip the connect screen and auto-dial.
    if (kIsWeb) {
      final hp = autoDetectHostPort();
      if (hp != null && hp.isNotEmpty) {
        client.connect(hp);
      }
    }
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v1.2 palette  -  OBSBOT brand red accent on near-black neutral.
    // Replaces the v1.1 default blue. Deep surface keeps the live
    // preview from looking grey-washed; red primary matches the camera
    // hardware + the OBSBOT Center mac app.
    const obsbotRed = Color(0xFFFF3B30);
    const deepSurface = Color(0xFF0F1115);
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: obsbotRed,
          primary: obsbotRed,
          surface: deepSurface,
          brightness: Brightness.dark,
        ).copyWith(
          surfaceContainerLowest: const Color(0xFF0A0C10),
          surfaceContainerLow: const Color(0xFF14171D),
          surfaceContainer: const Color(0xFF181B22),
          surfaceContainerHigh: const Color(0xFF1F2229),
          surfaceContainerHighest: const Color(0xFF262932),
          outlineVariant: const Color(0xFF3A3D45),
        );
    return MaterialApp(
      title: 'Open OBSBOT Remote',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: deepSurface,
        // M3 default SegmentedButton selected fill is `secondaryContainer`,
        // which `fromSeed(red, dark)` derives to a washed near-white that
        // collides with our dark surface. Pin selected = brand red on white,
        // unselected = surface on onSurface.
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.primary;
              }
              return colorScheme.surfaceContainer;
            }),
            foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.onPrimary;
              }
              return colorScheme.onSurface;
            }),
            iconColor: WidgetStateProperty.resolveWith<Color?>((states) {
              if (states.contains(WidgetState.selected)) {
                return colorScheme.onPrimary;
              }
              return colorScheme.onSurface;
            }),
            side: WidgetStatePropertyAll<BorderSide>(
              BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
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
          // 3) authed → the v3 studio (one surface, no mode split).
          return LiveScreen(client: client);
        },
      ),
    );
  }
}
