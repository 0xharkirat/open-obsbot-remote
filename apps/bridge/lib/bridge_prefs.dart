import 'package:shared_preferences/shared_preferences.dart';

/// Persistent UI preferences for the bridge app.
///
/// Why SharedPreferences:
///   - Flutter's shared_preferences_foundation on macOS writes through
///     `NSUserDefaults` under the app's bundle ID, prefixing every key
///     with `flutter.`. That's important for [menubarOnly]: AppDelegate.swift
///     reads the same key from `UserDefaults.standard` before the Flutter
///     engine boots, so it can decide whether to call
///     `NSApp.setActivationPolicy(.accessory)` early enough to suppress
///     the dock icon at launch.
///   - Side-effect: the Swift side MUST use the key `flutter.bridge_menubar_only`;
///     the Dart side uses `bridge_menubar_only`. They must stay in sync.
class BridgePrefs {
  BridgePrefs._(this._prefs);

  static const _kMenubarOnly = 'bridge_menubar_only';

  final SharedPreferences _prefs;

  static Future<BridgePrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return BridgePrefs._(p);
  }

  /// Hide the dock icon. When true, AppDelegate sets activation policy
  /// to `.accessory` at launch and `main()` skips the auto-show window
  /// call so the app starts as a pure menubar resident. The user can
  /// always restore the window via the tray menu.
  bool get menubarOnly => _prefs.getBool(_kMenubarOnly) ?? false;

  Future<void> setMenubarOnly(bool v) async {
    await _prefs.setBool(_kMenubarOnly, v);
  }
}
