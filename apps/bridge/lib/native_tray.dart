import 'dart:async';
import 'package:flutter/services.dart';

/// Dart side of the first-party macOS NSStatusItem wrapper.
///
/// Replaces `tray_manager` for the bridge because the package's
/// 0.5.2 `popUpContextMenu` plumbing drops NSMenu target/action
/// dispatch on macOS Sonoma+ — menu items show but click events
/// never reach the Dart side. See `macos/Runner/NativeTray.swift`
/// for the native impl + the bug analysis in the file header.
///
/// API surface mirrors the subset of tray_manager we actually used.
class NativeTray {
  static const _channel = MethodChannel('obsbot.bridge/tray');
  static final List<NativeTrayListener> _listeners = <NativeTrayListener>[];
  static bool _handlerInstalled = false;

  static void _ensureHandlerInstalled() {
    if (_handlerInstalled) return;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onMenuClick') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final key = args['key'] as String;
        for (final l in List<NativeTrayListener>.from(_listeners)) {
          l.onTrayMenuClick(key);
        }
      }
    });
    _handlerInstalled = true;
  }

  static void addListener(NativeTrayListener l) {
    _ensureHandlerInstalled();
    if (!_listeners.contains(l)) _listeners.add(l);
  }

  static void removeListener(NativeTrayListener l) {
    _listeners.remove(l);
  }

  /// Load an icon from the Flutter asset bundle (matches the asset
  /// path you'd pass to `rootBundle.load()` or `AssetImage`).
  /// `isTemplate=true` lets macOS auto-tint the icon to match menubar
  /// foreground colour (recommended for monochrome menubar glyphs).
  ///
  /// Implementation note: we read the PNG bytes on the Dart side and
  /// pass them across the channel as a `Uint8List`. Flutter macOS
  /// asset paths can't be resolved from `Bundle.main` on the Swift
  /// side because flutter_assets is bundled inside `App.framework`,
  /// not the main bundle.
  static Future<void> setIcon(String assetPath, {bool isTemplate = true}) async {
    final ByteData data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
        data.offsetInBytes, data.lengthInBytes);
    return _channel.invokeMethod<void>('setIcon', <String, dynamic>{
      'bytes': bytes,
      'isTemplate': isTemplate,
    });
  }

  static Future<void> setTooltip(String text) {
    return _channel.invokeMethod<void>('setTooltip', <String, dynamic>{
      'text': text,
    });
  }

  static Future<void> setTitle(String title) {
    return _channel.invokeMethod<void>('setTitle', <String, dynamic>{
      'title': title,
    });
  }

  /// Sets the dropdown menu. Items in order; use `NativeTrayItem.separator()`
  /// for dividers. The Swift side attaches the menu permanently to the
  /// NSStatusItem so click routing uses NSMenu's native dispatch.
  static Future<void> setMenu(List<NativeTrayItem> items) {
    final payload = items.map((e) => e.toJson()).toList();
    return _channel.invokeMethod<void>('setMenu', <String, dynamic>{
      'items': payload,
    });
  }

  static Future<void> destroy() {
    return _channel.invokeMethod<void>('destroy');
  }
}

abstract class NativeTrayListener {
  void onTrayMenuClick(String key);
}

class NativeTrayItem {
  final String type; // "normal" | "separator"
  final String? key;
  final String label;
  final bool disabled;
  /// Single character (lower-case) for the macOS key equivalent shown
  /// in the menu, e.g. `'q'` for Quit. Empty = no key equivalent. The
  /// command (⌘) modifier is applied on the Swift side by default; pass
  /// a different mask via [keyEquivalentModifierMask] only when needed.
  final String keyEquivalent;
  /// macOS NSEventModifierFlags raw bit mask. 1 << 20 = command.
  /// When [keyEquivalent] is empty this is ignored. Defaults to
  /// command (1048576) which is the right thing for the bridge tray.
  final int keyEquivalentModifierMask;

  const NativeTrayItem({
    required this.key,
    required this.label,
    this.disabled = false,
    this.keyEquivalent = '',
    this.keyEquivalentModifierMask = 1048576, // NSEventModifierFlagCommand
  }) : type = 'normal';

  const NativeTrayItem.separator()
      : type = 'separator',
        key = null,
        label = '',
        disabled = true,
        keyEquivalent = '',
        keyEquivalentModifierMask = 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (key != null) 'key': key,
        'label': label,
        'disabled': disabled,
        if (keyEquivalent.isNotEmpty) 'keyEquivalent': keyEquivalent,
        if (keyEquivalent.isNotEmpty)
          'keyEquivalentModifierMask': keyEquivalentModifierMask,
      };
}
