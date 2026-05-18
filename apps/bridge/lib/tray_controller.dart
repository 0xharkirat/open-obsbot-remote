import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_prefs.dart';
import 'bridge_supervisor.dart';
import 'native_tray.dart';

/// macOS menubar tray (v1.2 PR H, v1.2.1 PR R + S "Handy-style").
///
/// PR S rewrite: dropped `tray_manager` in favour of a first-party
/// NSStatusItem + NSMenu wrapper. The package's 0.5.2
/// `popUpContextMenu` plumbing assigned then nulled `statusItem.menu`
/// around each click, dropping NSMenu's target/action dispatch on
/// macOS Sonoma+. Net effect: menu items rendered but clicks never
/// fired the Dart-side TrayListener — Quit / Show window / Reveal
/// PIN all became no-ops. The replacement attaches the NSMenu
/// permanently and routes clicks through `@objc menuItemClicked:`
/// straight to the `obsbot.bridge/tray` channel; rock-solid.
///
/// Behaviour unchanged from the user's perspective:
///   - Bridge no longer needs the main window to stay alive. Closing
///     the window hides it; the bridge subprocess keeps running and
///     the tray menu provides quick actions.
///   - Hybrid dock-visibility (PR R): the dock icon follows the main
///     window. Hiding the window flips activation policy to
///     `.accessory` (no dock icon); showing it flips back to
///     `.regular`. Pattern lifted from Handy.
///   - Tray carries Status, paired-phones count, version, and
///     mirrors the live "Reveal PIN" gesture from the main window
///     so the user can pair from any context without restoring the
///     window.
class TrayController with WindowListener implements NativeTrayListener {
  final BridgeSupervisor supervisor;
  final VoidCallback onRevealPin;
  /// App version label (e.g. "1.2.1"). Shown as the first, disabled
  /// item in the tray menu — Handy-style at-a-glance build indicator.
  final String version;
  Timer? _refresh;
  bool _disposed = false;

  TrayController({
    required this.supervisor,
    required this.onRevealPin,
    this.version = '',
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
    final running = supervisor.status == BridgeStatus.running;
    final cameraOk = supervisor.cameraConnected;
    final paired = supervisor.pairedTokenCount;
    final clients = supervisor.wsClientCount;

    final items = <NativeTrayItem>[
      if (version.isNotEmpty)
        NativeTrayItem(
          key: 'version',
          label: 'OBSBOT Bridge v$version',
          disabled: true,
        ),
      if (version.isNotEmpty) const NativeTrayItem.separator(),
      NativeTrayItem(
        key: 'status',
        label: running
            ? (cameraOk
                ? 'Status: Running (camera OK)'
                : 'Status: Running (no camera)')
            : (supervisor.status == BridgeStatus.error
                ? 'Status: Error'
                : 'Status: Stopped'),
        disabled: true,
      ),
      NativeTrayItem(
        key: 'clients',
        label: '$clients phones connected ($paired paired)',
        disabled: true,
      ),
      const NativeTrayItem.separator(),
      // Pairing PIN, inline. Tailscale / Dropbox idiom: the most-used
      // piece of info is one click away.
      NativeTrayItem(
        key: 'pin_display',
        label: supervisor.pin.isNotEmpty
            ? 'Pairing PIN:  ${supervisor.pin}'
            : 'Pairing PIN:  (generating…)',
        disabled: true,
      ),
      if (supervisor.pin.isNotEmpty)
        const NativeTrayItem(key: 'copy_pin', label: 'Copy PIN to clipboard'),
      NativeTrayItem(
        key: 'reveal_pin',
        label: 'Show PIN + QR code in main window',
        disabled: supervisor.pin.isEmpty,
      ),
      const NativeTrayItem(key: 'show_window', label: 'Show main window'),
      const NativeTrayItem.separator(),
      NativeTrayItem(
        key: 'open_log',
        label: 'Open log file',
        disabled: supervisor.logFilePath == null,
      ),
      const NativeTrayItem(
        key: 'restart_bridge',
        label: 'Restart bridge subprocess',
      ),
      const NativeTrayItem.separator(),
      const NativeTrayItem(key: 'quit', label: 'Quit OBSBOT Bridge'),
    ];
    await NativeTray.setMenu(items);
  }

  // ---- NativeTrayListener -------------------------------------------------

  @override
  void onTrayMenuClick(String key) async {
    switch (key) {
      case 'reveal_pin':
        await _showAndFocus();
        onRevealPin();
        break;
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
      case 'restart_bridge':
        await supervisor.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await supervisor.start();
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
