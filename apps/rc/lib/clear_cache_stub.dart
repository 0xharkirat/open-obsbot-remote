// On native (iOS/Android), there's no service worker / browser cache to wipe.
// We just clear stored prefs.
import 'package:shared_preferences/shared_preferences.dart';

Future<void> clearAppCache() async {
  final p = await SharedPreferences.getInstance();
  await p.clear();
}
