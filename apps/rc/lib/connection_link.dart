/// One connection-link format, three consumers.
///
/// The bridge's QR encodes `http://<ip>:<port>/#pair?pin=123456`. A phone
/// SCANS it, a desktop PASTES it, and a plain browser just OPENS it (the web
/// app reads the fragment and pairs itself). This parser also accepts the
/// hand-typed forms that predate it: `host:port` and bare `host`.
library;

({String hostPort, String? pin})? parseConnectionLink(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (t.contains('://')) {
    final uri = Uri.tryParse(t);
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 8765;
    String? pin;
    // The pin rides in the FRAGMENT (never sent to any server by browsers):
    // "#pair?pin=123456".
    final frag = uri.fragment;
    if (frag.startsWith('pair')) {
      final q = Uri.tryParse('x://x/$frag');
      pin = q?.queryParameters['pin'];
      if (pin != null && pin.isEmpty) pin = null;
    }
    return (hostPort: '${uri.host}:$port', pin: pin);
  }
  // host:port or bare host. Reject things that are clearly not addresses.
  if (t.contains(' ') || t.contains('\n')) return null;
  final hp = t.contains(':') ? t : '$t:8765';
  final parts = hp.split(':');
  if (parts.length != 2 || parts[0].isEmpty) return null;
  if (int.tryParse(parts[1]) == null) return null;
  return (hostPort: hp, pin: null);
}
