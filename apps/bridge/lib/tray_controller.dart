import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge_supervisor.dart';

/// macOS menubar tray for the bridge (v1.2 PR H).
///
/// Replaces the "set + forget" pain point of the bridge .app:
///
///   - The bridge no longer needs the main window to stay alive.
///     Closing the window hides it; the bridge subprocess keeps running
///     and the tray menu provides quick actions.
///   - The tray title shows the current bridge status (●  Running /
///     ◌  Stopped / ✗  Error) so the user knows from a glance whether
///     phones can still connect.
///   - Tray menu mirrors the live "Reveal PIN" gesture from the main
///     window so the user can pair from any context without restoring
///     the window.
///
/// macOS-specific:
///   - The `LSUIElement` setting in Info.plist is left at the default
///     (false / not present) so the dock icon stays visible — easier
///     discovery for first-time users. A future PR may make this
///     configurable so power users can run as a pure menubar app.
class TrayController with WindowListener, TrayListener {
  final BridgeSupervisor supervisor;
  final VoidCallback onRevealPin;
  Timer? _refresh;
  bool _disposed = false;

  TrayController({required this.supervisor, required this.onRevealPin});

  Future<void> init() async {
    if (!Platform.isMacOS) {
      // Tray is macOS-only for v1.2. tray_manager supports Windows +
      // Linux too, but the Bridge .app is macOS-only today.
      return;
    }
    await trayManager.setToolTip('OBSBOT Bridge');
    await _refreshTrayLabel();
    await _rebuildMenu();
    trayManager.addListener(this);
    windowManager.addListener(this);

    supervisor.addListener(_onSupervisorChange);
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _refreshTrayLabel());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _refresh?.cancel();
    supervisor.removeListener(_onSupervisorChange);
    if (Platform.isMacOS) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
    }
  }

  void _onSupervisorChange() {
    if (_disposed) return;
    _refreshTrayLabel();
    _rebuildMenu();
  }

  Future<void> _refreshTrayLabel() async {
    String glyph;
    switch (supervisor.status) {
      case BridgeStatus.running:
        glyph = supervisor.cameraConnected ? '● OBSBOT' : '◐ OBSBOT';
        break;
      case BridgeStatus.starting:
        glyph = '◌ OBSBOT';
        break;
      case BridgeStatus.error:
        glyph = '✗ OBSBOT';
        break;
      case BridgeStatus.stopped:
        glyph = '○ OBSBOT';
        break;
    }
    try {
      await trayManager.setTitle(glyph);
    } catch (_) {
      // setTitle is macOS-only on tray_manager; safe to swallow.
    }
  }

  Future<void> _rebuildMenu() async {
    final running = supervisor.status == BridgeStatus.running;
    final cameraOk = supervisor.cameraConnected;
    final paired = supervisor.pairedTokenCount;
    final clients = supervisor.wsClientCount;

    final menu = Menu(
      items: <MenuItem>[
        MenuItem(
          label: running
              ? (cameraOk
                  ? 'Status: Running (camera OK)'
                  : 'Status: Running (no camera)')
              : (supervisor.status == BridgeStatus.error
                  ? 'Status: Error'
                  : 'Status: Stopped'),
          disabled: true,
        ),
        MenuItem(
          label: '$clients phones connected ($paired paired)',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'reveal_pin',
          label: 'Reveal pairing PIN (60s)',
          disabled: supervisor.pin.isEmpty,
        ),
        MenuItem(
          key: 'show_window',
          label: 'Show main window',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'open_log',
          label: 'Open log file',
          disabled: supervisor.logFilePath == null,
        ),
        MenuItem(
          key: 'restart_bridge',
          label: 'Restart bridge subprocess',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit OBSBOT Bridge',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  // ---- TrayListener -------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    // Left-click also pops the menu — same as right-click. Matches the
    // OBSBOT Center / Slack / Dropbox idiom.
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'reveal_pin':
        await windowManager.show();
        await windowManager.focus();
        onRevealPin();
        break;
      case 'show_window':
        await windowManager.show();
        await windowManager.focus();
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

  // ---- WindowListener -----------------------------------------------------
  //
  // Hide the window instead of letting it actually close. The tray icon
  // keeps the bridge subprocess alive; quitting only happens through the
  // tray's "Quit" item or Cmd-Q from a focused window (which Flutter
  // forwards through onWindowClose with prevent-close OFF — handled by
  // setPreventClose(true) below).

  @override
  void onWindowClose() async {
    // tray_manager + window_manager dance: only intercept the close
    // when setPreventClose(true) is set; otherwise the framework will
    // call exit() itself.
    final preventClose = await windowManager.isPreventClose();
    if (preventClose) {
      await windowManager.hide();
    }
  }
}
