import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent UI preferences + platform-channel helpers for the bridge app.
///
/// Two responsibilities are bundled here because they always travel
/// together for the Handy-style menubar lifecycle:
///
///   1. Persisted prefs (SharedPreferences).
///   2. The `obsbot.bridge/dock` MethodChannel that lets Dart flip the
///      app's NSApplication activation policy at runtime.
///
/// **Why the `flutter.` key prefix matters.** Flutter's
/// shared_preferences_foundation plugin writes through NSUserDefaults
/// with every key prefixed by `flutter.`. AppDelegate.swift reads
/// `flutter.bridge_start_hidden` directly from `UserDefaults.standard`
/// before the Flutter engine boots  -  that's how the dock icon never
/// flickers on launch in start-hidden mode.
class BridgePrefs {
  BridgePrefs._(this._prefs);

  /// SharedPreferences keys. Dart writes `bridge_start_hidden`; the
  /// plugin stores it as `flutter.bridge_start_hidden` in NSUserDefaults.
  static const _kStartHidden = 'bridge_start_hidden';

  /// Legacy key from v1.2.1 PR O  -  same meaning, kept for migration.
  static const _kMenubarOnlyLegacy = 'bridge_menubar_only';

  static const _dockChannel = MethodChannel('obsbot.bridge/dock');

  final SharedPreferences _prefs;

  static Future<BridgePrefs> load() async {
    final p = await SharedPreferences.getInstance();
    // One-shot migration: if the user set the old menubar-only pref,
    // copy its value into the new start-hidden key so they get the
    // same behavior after this update.
    if (!p.containsKey(_kStartHidden) && p.containsKey(_kMenubarOnlyLegacy)) {
      final old = p.getBool(_kMenubarOnlyLegacy) ?? false;
      await p.setBool(_kStartHidden, old);
    }
    return BridgePrefs._(p);
  }

  /// "Start hidden in menubar"  -  when true, the bridge boots without
  /// showing the main window and with the dock icon hidden (Handy's
  /// `start_hidden`). Default false.
  ///
  /// Onboarding override: even with this true, the bridge force-shows
  /// the window when there are no paired phones yet, so the user can
  /// see the pairing PIN. See `main.dart`.
  bool get startHidden => _prefs.getBool(_kStartHidden) ?? false;

  Future<void> setStartHidden(bool v) async {
    await _prefs.setBool(_kStartHidden, v);
  }

  /// Switch the macOS activation policy at runtime.
  ///
  /// `true`  → `.regular`  (dock icon visible, app participates in
  ///                        Cmd-Tab and dock click).
  /// `false` → `.accessory` (no dock icon, tray-only).
  ///
  /// The Handy pattern: call `setDockVisible(true)` when showing the
  /// main window, `setDockVisible(false)` when hiding it. Initial
  /// state at launch is set in AppDelegate.swift based on the
  /// `flutter.bridge_start_hidden` UserDefaults key, before the
  /// Flutter engine boots  -  no flicker.
  static Future<void> setDockVisible(bool visible) async {
    try {
      await _dockChannel
          .invokeMethod<void>(visible ? 'setRegular' : 'setAccessory');
    } catch (_) {
      // Channel missing on non-macOS platforms; safe to swallow.
    }
  }
}
