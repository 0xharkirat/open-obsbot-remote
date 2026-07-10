import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_prefs.dart';
import 'bridge_supervisor.dart';
import 'native_tray.dart';

/// macOS menubar tray (v1.2 PR H, v1.2.1 PR R + S "Handy-style",
/// v1.4.1 simplification).
///
/// PR S rewrite: dropped `tray_manager` in favour of a first-party
/// NSStatusItem + NSMenu wrapper. The package's 0.5.2
/// `popUpContextMenu` plumbing assigned then nulled `statusItem.menu`
/// around each click, dropping NSMenu's target/action dispatch on
/// macOS Sonoma+. Net effect: menu items rendered but clicks never
/// fired the Dart-side TrayListener  -  Quit / Show window / Reveal
/// PIN all became no-ops. The replacement attaches the NSMenu
/// permanently and routes clicks through `@objc menuItemClicked:`
/// straight to the `obsbot.bridge/tray` channel; rock-solid.
///
/// v1.4.1 menu simplification: real users called the previous menu
/// "confusing". The current menu is six items:
///
///   ● Camera connected · 2 phones     (disabled status line)
///   ───────
///   Pairing PIN  123456          ⌘C   (clickable; copies to clipboard)
///   ───────
///   Show main window             ⌘O
///   Open log file
///   ───────
///   Quit                         ⌘Q
///
/// What we collapsed: version row (moved to About in Settings),
/// separate "Copy PIN" + "Show PIN + QR" rows (PIN row IS the copy
/// affordance now; QR/Reveal lives in the main window), "Restart
/// bridge subprocess" (power-user, promote to Settings if anyone
/// misses it).
///
/// Behaviour unchanged from the user's perspective:
///   - Bridge no longer needs the main window to stay alive. Closing
///     the window hides it; the bridge subprocess keeps running and
///     the tray menu provides quick actions.
///   - Hybrid dock-visibility (PR R): the dock icon follows the main
///     window. Hiding the window flips activation policy to
///     `.accessory` (no dock icon); showing it flips back to
///     `.regular`. Pattern lifted from Handy.
class TrayController with WindowListener implements NativeTrayListener {
  final BridgeSupervisor supervisor;
  Timer? _refresh;
  bool _disposed = false;

  TrayController({
    required this.supervisor,
  });

  Future<void> init() async {
    if (!Platform.isMacOS) {
      // Tray is macOS-only for v1.2.x. Native impl is AppKit.
      // Windows + Linux ports will need their own NativeTray
      // siblings.
      return;
    }
    // Initial icon is set inside _refreshIcon (it picks the right
    // variant based on supervisor.status). If asset load fails the
    // setTitle fallback below keeps the menubar entry discoverable.
    final iconOk = await _refreshIcon();
    if (!iconOk) {
      await NativeTray.setTitle('OBSBOT');
    }
    await NativeTray.setTooltip('OBSBOT Bridge');
    await _refreshTooltip();
    await _rebuildMenu();

    NativeTray.addListener(this);
    windowManager.addListener(this);

    supervisor.addListener(_onSupervisorChange);
    _refresh = Timer.periodic(
        const Duration(seconds: 5), (_) => _refreshTooltip());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _refresh?.cancel();
    supervisor.removeListener(_onSupervisorChange);
    if (Platform.isMacOS) {
      NativeTray.removeListener(this);
      windowManager.removeListener(this);
      await NativeTray.destroy();
    }
  }

  void _onSupervisorChange() {
    if (_disposed) return;
    _refreshIcon();
    _refreshTooltip();
    _rebuildMenu();
  }

  /// Pick the right tray icon variant for the current supervisor
  /// status:
  ///
  ///   - `cameraTemplate.png`       (running + camera connected, idle)
  ///   - `cameraTemplateWarn.png`   (running but no camera plugged in,
  ///                                 or supervisor starting)
  ///   - `cameraTemplateError.png`  (bridge stopped or in error state)
  ///
  /// Returns true on success. Failures (asset missing, channel error)
  /// are swallowed; the caller treats false as "fall back to setTitle".
  Future<bool> _refreshIcon() async {
    String asset;
    switch (supervisor.status) {
      case BridgeStatus.running:
        asset = supervisor.cameraConnected
            ? 'assets/tray/cameraTemplate.png'
            : 'assets/tray/cameraTemplateWarn.png';
        break;
      case BridgeStatus.starting:
        asset = 'assets/tray/cameraTemplateWarn.png';
        break;
      case BridgeStatus.error:
      case BridgeStatus.stopped:
        asset = 'assets/tray/cameraTemplateError.png';
        break;
    }
    try {
      await NativeTray.setIcon(asset, isTemplate: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshTooltip() async {
    String tip;
    switch (supervisor.status) {
      case BridgeStatus.running:
        tip = supervisor.cameraConnected
            ? 'OBSBOT Bridge - running, camera connected'
            : 'OBSBOT Bridge - running, no camera plugged in';
        break;
      case BridgeStatus.starting:
        tip = 'OBSBOT Bridge - starting up';
        break;
      case BridgeStatus.error:
        tip = 'OBSBOT Bridge - error: ${supervisor.lastError ?? "unknown"}';
        break;
      case BridgeStatus.stopped:
        tip = 'OBSBOT Bridge - stopped';
        break;
    }
    try {
      await NativeTray.setTooltip(tip);
    } catch (_) {
      // Channel error; swallow.
    }
  }

  Future<void> _rebuildMenu() async {
    // Build ONE status line that captures both camera state and phone
    // count. The tray icon already encodes colour (green = camera OK,
    // amber = no camera, red = error/stopped) so the text just has to
    // be terse. Examples:
    //
    //   "Camera connected · 2 phones"
    //   "No camera · 0 phones"
    //   "Starting up…"
    //   "Stopped"
    //   "Error: bridge exited with code 1"
    final cameraOk = supervisor.cameraConnected;
    final clients = supervisor.wsClientCount;
    final phonesLabel = '$clients ${clients == 1 ? "phone" : "phones"}';
    String statusLabel;
    switch (supervisor.status) {
      case BridgeStatus.running:
        statusLabel = cameraOk
            ? 'Camera connected  ·  $phonesLabel'
            : 'No camera  ·  $phonesLabel';
        break;
      case BridgeStatus.starting:
        statusLabel = 'Starting up…';
        break;
      case BridgeStatus.error:
        statusLabel = 'Error: ${supervisor.lastError ?? "unknown"}';
        break;
      case BridgeStatus.stopped:
        statusLabel = 'Stopped';
        break;
    }

    // PIN line: clickable. Clicking copies the PIN to clipboard
    // (Tailscale / Dropbox idiom  -  collapse "PIN: XXXXXX" + "Copy PIN"
    // into a single affordance). The label ends with the standard
    // macOS ⌘C glyph hint to make the action discoverable.
    //
    // When the PIN is not yet known (auth.json still being read or the
    // bridge is starting up), show "Pairing PIN  ……" and keep the row
    // disabled.
    final hasPin = supervisor.pin.isNotEmpty;
    final pinLabel = hasPin
        ? 'Pairing PIN  ${supervisor.pin}'
        : 'Pairing PIN  ……';

    final items = <NativeTrayItem>[
      // Status. Disabled (NSMenu still renders, just non-clickable).
      // This is the only "live" line  -  the tray icon's colour glyph
      // says the same thing visually.
      NativeTrayItem(
        key: 'status',
        label: statusLabel,
        disabled: true,
      ),
      const NativeTrayItem.separator(),
      // The PIN row IS the copy affordance.
      NativeTrayItem(
        key: 'copy_pin',
        label: pinLabel,
        disabled: !hasPin,
        keyEquivalent: hasPin ? 'c' : '',
      ),
      const NativeTrayItem.separator(),
      const NativeTrayItem(
        key: 'show_window',
        label: 'Show main window',
        keyEquivalent: 'o',
      ),
      NativeTrayItem(
        key: 'open_log',
        label: 'Open log file',
        disabled: supervisor.logFilePath == null,
      ),
      const NativeTrayItem.separator(),
      const NativeTrayItem(
        key: 'quit',
        label: 'Quit',
        keyEquivalent: 'q',
      ),
    ];
    await NativeTray.setMenu(items);
  }

  // ---- NativeTrayListener -------------------------------------------------

  @override
  void onTrayMenuClick(String key) async {
    switch (key) {
      case 'copy_pin':
        if (supervisor.pin.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: supervisor.pin));
        }
        break;
      case 'show_window':
        await _showAndFocus();
        break;
      case 'open_log':
        supervisor.revealLogInFinder();
        break;
      case 'quit':
        await supervisor.stop();
        await dispose();
        exit(0);
    }
  }

  /// Show + focus the main window with dock-policy in the correct
  /// order. .accessory NSWindows can orderFront but never become key,
  /// so we flip back to .regular BEFORE asking window_manager to
  /// focus. See bridge_prefs.dart for the channel + AppDelegate.swift
  /// for the launch-time policy.
  Future<void> _showAndFocus() async {
    await BridgePrefs.setDockVisible(true);
    await windowManager.show();
    await windowManager.focus();
  }

  // ---- WindowListener -----------------------------------------------------

  @override
  void onWindowClose() async {
    final preventClose = await windowManager.isPreventClose();
    if (preventClose) {
      await windowManager.hide();
    }
  }

  @override
  void onWindowEvent(String eventName) {
    switch (eventName) {
      case 'show':
        BridgePrefs.setDockVisible(true);
        break;
      case 'hide':
        BridgePrefs.setDockVisible(false);
        break;
    }
  }
}
