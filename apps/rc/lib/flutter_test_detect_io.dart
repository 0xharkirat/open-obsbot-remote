import 'dart:io' show Platform;

// `flutter test` (and integration harnesses) set FLUTTER_TEST=true.
bool get isRunningFlutterTest =>
    Platform.environment.containsKey('FLUTTER_TEST');
