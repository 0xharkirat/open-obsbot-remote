// NativeTray.swift  -  first-party macOS NSStatusItem replacement for the
// `tray_manager` Flutter plugin.
//
// Why we wrote this: tray_manager 0.5.2's `popUpContextMenu` toggles
// `statusItem.menu` on and off around each click. On macOS Sonoma+ that
// dance drops NSMenu's target/action dispatch  -  the menu shows but
// menuitem clicks never reach the Dart-side TrayListener. The bug bit
// us on v1.2.1 hard enough that Quit / Show window / Reveal PIN all
// became no-ops.
//
// This file owns:
//   - One NSStatusItem with its NSMenu attached permanently (the
//     macOS-blessed pattern, NSMenu's own click routing handles all
//     dispatch).
//   - A method channel `obsbot.bridge/tray`. Dart calls in to set
//     icon / tooltip / menu items; the Swift side calls back with
//     `onMenuClick { key: "<dart-supplied key>" }` when an item fires.
//
// Lifetimes mirror MainFlutterWindow: created in awakeFromNib, lives
// for the engine's lifetime. The single-instance check in
// AppDelegate ensures only one tray is ever active.

import Cocoa
import FlutterMacOS

class NativeTray: NSObject {
  private let channel: FlutterMethodChannel
  private let statusItem: NSStatusItem
  private var menuItems: [String: NSMenuItem] = [:]

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "obsbot.bridge/tray",
      binaryMessenger: messenger
    )
    self.statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength
    )
    super.init()
    channel.setMethodCallHandler { [weak self] (call, result) in
      self?.handle(call, result: result)
    }
  }

  deinit {
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setIcon":
      guard let args = call.arguments as? [String: Any],
            let data = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad-args", message: "setIcon needs bytes", details: nil))
        return
      }
      let isTemplate = (args["isTemplate"] as? Bool) ?? false
      setIcon(data: data.data, isTemplate: isTemplate)
      result(nil)

    case "setTooltip":
      let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
      statusItem.button?.toolTip = text
      result(nil)

    case "setTitle":
      // Optional text title next to the icon (Handy uses this for "REC"
      // overlay etc). For the bridge we usually leave this empty  -  the
      // icon carries the visual.
      let title = (call.arguments as? [String: Any])?["title"] as? String ?? ""
      statusItem.button?.title = title
      result(nil)

    case "setMenu":
      guard let args = call.arguments as? [String: Any],
            let items = args["items"] as? [[String: Any]] else {
        result(FlutterError(code: "bad-args", message: "setMenu needs items", details: nil))
        return
      }
      setMenu(items)
      result(nil)

    case "destroy":
      NSStatusBar.system.removeStatusItem(statusItem)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Build NSImage from raw bytes sent by Dart. Originally we tried
  // FlutterDartProject.lookupKey + Bundle.main.url, but Flutter assets
  // live inside `App.framework/Resources/flutter_assets/` on macOS,
  // not in `Bundle.main` directly  -  Bundle.main returned nil and the
  // status item rendered with no icon. Passing PNG bytes through the
  // channel is the robust path (matches what tray_manager itself did
  // with base64 strings; FlutterStandardTypedData is the binary
  // equivalent + zero base64 overhead).
  private func setIcon(data: Data, isTemplate: Bool) {
    guard let image = NSImage(data: data) else { return }
    image.isTemplate = isTemplate
    image.size = NSSize(width: 18, height: 18)
    statusItem.button?.image = image
  }

  // Builds the NSMenu from a list of {key, label, type, disabled} dicts.
  // type defaults to "normal"; the only other value is "separator". We
  // wire each item's target = self, action = #menuItemClicked: so the
  // dispatch goes through the NSMenu pipeline directly  -  no
  // popUpContextMenu toggling.
  private func setMenu(_ items: [[String: Any]]) {
    let menu = NSMenu()
    menuItems.removeAll()
    for (i, item) in items.enumerated() {
      let type = item["type"] as? String ?? "normal"
      if type == "separator" {
        menu.addItem(NSMenuItem.separator())
        continue
      }
      let label = item["label"] as? String ?? ""
      let disabled = item["disabled"] as? Bool ?? false
      let key = item["key"] as? String ?? "__item_\(i)"
      // Optional macOS key equivalent (Cmd-Q, Cmd-O, etc). Dart side
      // sends a 1-char string + an NSEventModifierFlags raw mask. Empty
      // string = no shortcut (renders without a glyph on the right).
      let keyEquiv = item["keyEquivalent"] as? String ?? ""
      let modMask = item["keyEquivalentModifierMask"] as? Int ?? 0
      let mi = NSMenuItem(title: label, action: #selector(menuItemClicked(_:)), keyEquivalent: keyEquiv)
      if !keyEquiv.isEmpty && modMask != 0 {
        mi.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(modMask))
      }
      mi.target = self
      mi.isEnabled = !disabled
      // representedObject carries the Dart-supplied key back to us.
      mi.representedObject = key
      menu.addItem(mi)
      menuItems[key] = mi
    }
    // Permanent attachment. macOS handles all click routing through
    // this menu; we never null it out.
    statusItem.menu = menu
  }

  @objc private func menuItemClicked(_ sender: NSMenuItem) {
    guard let key = sender.representedObject as? String else { return }
    channel.invokeMethod("onMenuClick", arguments: ["key": key])
  }
}
