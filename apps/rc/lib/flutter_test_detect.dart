// Web + default stub: no dart:io, so never "under flutter test".
// The io variant (flutter_test_detect_io.dart) reads the FLUTTER_TEST env
// var on native. Used to skip MarionetteBinding when a test harness (or
// patrol) has already installed its own WidgetsBinding - only one binding
// is allowed per process.
bool get isRunningFlutterTest => false;
