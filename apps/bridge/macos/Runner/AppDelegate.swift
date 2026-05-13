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
  // Also: read the persisted "start hidden" preference from
  // NSUserDefaults BEFORE super.applicationDidFinishLaunching, because
  // FlutterAppDelegate creates and shows the main window inside super.
  // If start-hidden is enabled we flip activation policy to .accessory
  // now so the dock icon never appears at launch.
  //
  // The Handy-style dynamic flip (dock icon follows window visibility
  // once Flutter is up) is handled via the obsbot.bridge/dock
  // MethodChannel in MainFlutterWindow.swift — Dart calls into the
  // channel from windowManager show/hide events, see TrayController.
  //
  // Migration: v1.2.1 PR O used `bridge_menubar_only`; v1.2.1 PR R
  // renamed to `bridge_start_hidden`. We accept either key here so a
  // user mid-update doesn't see a one-launch regression. BridgePrefs.load
  // copies the legacy value forward on first Dart-side read.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    let defaults = UserDefaults.standard
    let startHidden =
      defaults.bool(forKey: "flutter.bridge_start_hidden") ||
      defaults.bool(forKey: "flutter.bridge_menubar_only")
    if startHidden {
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
