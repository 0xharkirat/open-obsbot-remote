import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Tray owns the lifecycle: the user quits via the menubar tray's
  // "Quit OBSBOT Bridge" item (or Cmd-Q with the window focused).
  // Closing the red dot just hides the window (windowManager
  // setPreventClose(true) + TrayController.onWindowClose handle the
  // intercept). Returning false here is also required for
  // menubar-only mode — otherwise the missing window at launch is
  // misread as "last window closed" and the app quits immediately.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Single-instance: re-launching the .app (or clicking the Dock icon
  // when no windows are visible) should bring the existing window to
  // front instead of spawning a fresh window.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for w in sender.windows {
        w.makeKeyAndOrderFront(nil)
      }
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }

  // Belt-and-suspenders: macOS Launch Services normally prevents two
  // instances of the same .app, but ad-hoc-signed dev builds occasionally
  // slip through. If we detect a running sibling at startup, focus it
  // and quit ourselves so the user always sees one window.
  //
  // Also: read the persisted "menubar-only" preference from
  // NSUserDefaults BEFORE super.applicationDidFinishLaunching, because
  // FlutterAppDelegate creates and shows the main window inside super.
  // If the user opted into menubar-only mode, we flip activation policy
  // to .accessory now so the dock icon never appears at launch.
  //
  // The key is `flutter.bridge_menubar_only` because Flutter's
  // shared_preferences_foundation prefixes every key with `flutter.`
  // when it writes through NSUserDefaults. The Dart side writes
  // `bridge_menubar_only` and SharedPreferences adds the prefix; both
  // sides therefore stay in sync as long as the key constant doesn't
  // drift (see bridge_prefs.dart).
  override func applicationDidFinishLaunching(_ notification: Notification) {
    if UserDefaults.standard.bool(forKey: "flutter.bridge_menubar_only") {
      NSApp.setActivationPolicy(.accessory)
    }
    super.applicationDidFinishLaunching(notification)
    let bundleId = Bundle.main.bundleIdentifier ?? ""
    let me = NSRunningApplication.current
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
      .filter { $0 != me }
    if let other = others.first {
      other.activate(options: [.activateAllWindows])
      NSApp.terminate(nil)
    }
  }
}
