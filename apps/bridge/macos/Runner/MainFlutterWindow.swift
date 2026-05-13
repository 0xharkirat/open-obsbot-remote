import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Retained for the lifetime of the window so the menu callbacks
  // keep working. NativeTray creates/destroys the NSStatusItem
  // internally on init/deinit.
  private var nativeTray: NativeTray?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // First-party tray (NativeTray.swift) replaces tray_manager for
    // menu-item dispatch — see that file's header for the reasoning.
    nativeTray = NativeTray(messenger: flutterViewController.engine.binaryMessenger)

    // MethodChannel: obsbot.bridge/dock — lets Dart flip the dock
    // activation policy at runtime. Handy-style hybrid model: when
    // the main window is hidden the bridge should switch to
    // .accessory (no dock icon), and back to .regular when shown.
    // The toggle happens dynamically as the user shows/hides the
    // window, not as a static install-time preference.
    let dockChannel = FlutterMethodChannel(
      name: "obsbot.bridge/dock",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    dockChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "setRegular":
        // Order matters: flip the policy first so subsequent calls to
        // makeKeyAndOrderFront / activate are honoured. .accessory
        // apps' windows can orderFront but never become key, which is
        // why a hidden-then-shown bridge window stayed un-clickable
        // before this fix.
        NSApp.setActivationPolicy(.regular)
        if let self = self {
          self.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      case "setAccessory":
        NSApp.setActivationPolicy(.accessory)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
