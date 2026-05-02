import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'clear_cache_stub.dart' if (dart.library.js_interop) 'clear_cache_web.dart';

/// Overflow menu with "Clear cache & reload". Useful when the bridge ships
/// a new web build and the phone is still showing the old one. Wipes:
/// - shared_preferences (last server, token, mode, speed) → forces re-pair
/// - service worker registrations
/// - Cache Storage entries
/// - then hard-reloads (web) or just re-runs onCleared (native)
class CacheMenu extends StatelessWidget {
  /// Called after cache clear on native. On web the page reloads, so this
  /// is mostly relevant for iOS/Android native builds.
  final VoidCallback? onCleared;
  const CacheMenu({super.key, this.onCleared});

  Future<void> _confirm(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Clear cache & reload?'),
        content: Text(
          kIsWeb
              ? 'Wipes the cached web bundle, service worker, paired token, and last-server. The page will reload. You\'ll need to re-enter the PIN.'
              : 'Wipes the paired token and stored preferences. You\'ll need to re-enter the PIN.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Clear & reload'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await clearAppCache();
    onCleared?.call();
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'clear',
          child: Row(children: <Widget>[
            Icon(Icons.cleaning_services_outlined, size: 16),
            SizedBox(width: 8),
            Text('Clear cache & reload'),
          ]),
        ),
      ],
      onSelected: (v) {
        if (v == 'clear') _confirm(context);
      },
    );
  }
}
