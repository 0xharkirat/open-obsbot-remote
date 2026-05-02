import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
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
  override func applicationDidFinishLaunching(_ notification: Notification) {
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
