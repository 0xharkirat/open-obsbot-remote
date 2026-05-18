// Web-only: derive bridge host:port from the page URL the user loaded.
// If user opened http://192.168.68.51:8765/ then we already know
// where the bridge lives  -  no need to ask.
import 'package:web/web.dart' as web;

String? autoDetectHostPort() {
  try {
    final loc = web.window.location;
    final host = loc.hostname;
    if (host.isEmpty) return null;
    // location.port is "" when default. Bridge always uses an explicit port.
    final port = loc.port.isEmpty ? '8765' : loc.port;
    return '$host:$port';
  } catch (_) {
    return null;
  }
}
