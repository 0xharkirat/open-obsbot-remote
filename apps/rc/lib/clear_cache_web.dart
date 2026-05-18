// Web implementation: wipe shared_preferences (localStorage), unregister
// the Flutter service worker, clear all caches, then hard-reload bypassing
// the browser cache.
import 'dart:js_interop';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

Future<void> clearAppCache() async {
  // 1) wipe Dart-side prefs (token, last server, mode, speed)
  try {
    final p = await SharedPreferences.getInstance();
    await p.clear();
  } catch (_) {}

  // 2) unregister all service workers tied to this origin
  try {
    final sw = web.window.navigator.serviceWorker;
    final regs = await sw.getRegistrations().toDart;
    for (final r in regs.toDart) {
      await r.unregister().toDart;
    }
  } catch (_) {}

  // 3) clear the Cache Storage (covers anything the SW had cached)
  try {
    final caches = web.window.caches;
    final names = (await caches.keys().toDart).toDart;
    for (final n in names) {
      await caches.delete(n.toDart).toDart;
    }
  } catch (_) {}

  // 4) hard reload  -  fetches fresh index.html (no-cache header on it
  //    means new main.dart.js hash kicks in immediately).
  web.window.location.reload();
}
