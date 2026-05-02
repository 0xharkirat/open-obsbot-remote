import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';

import 'ws_client.dart';
import 'web_mjpeg_stub.dart' if (dart.library.js_interop) 'web_mjpeg_web.dart';

/// Live preview from the bridge (`/preview.mjpeg` on port 8766).
///
/// Strategy by platform:
///   • Web (Chrome/Safari)   → HtmlElementView with a real `<img>` element.
///   • Android / iOS native  → `flutter_mjpeg` package (decodes the multipart
///                             stream itself; required because Flutter's
///                             Image widget on mobile doesn't grok multipart).
class PreviewWidget extends StatelessWidget {
  final WsClient client;
  const PreviewWidget({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final host = client.serverUri; // e.g. "10.250.1.51:8765"
    if (!client.connected || host.isEmpty) {
      return _placeholder(context, 'Connecting...');
    }
    // MJPEG runs on ws-port + 1 (8766 by default).
    final colon = host.lastIndexOf(':');
    final hostOnly = colon >= 0 ? host.substring(0, colon) : host;
    final wsPort = colon >= 0
        ? int.tryParse(host.substring(colon + 1)) ?? 8765
        : 8765;
    final tok = client.token ?? '';
    final url = 'http://$hostOnly:${wsPort + 1}/preview.mjpeg?t=$tok';

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: kIsWeb ? _webStream(url) : _mobileStream(url),
        ),
      ),
    );
  }

  Widget _webStream(String url) {
    // Image.network on Flutter web fetches bytes via HttpRequest and tries to
    // decode them as a single image — it can't handle multipart/x-mixed-replace.
    // Embed a real <img> element instead; the browser renders the multipart
    // stream natively. See web_mjpeg_web.dart.
    return buildWebMjpegView(url);
  }

  Widget _mobileStream(String url) {
    return Mjpeg(
      stream: url,
      isLive: true,
      fit: BoxFit.contain,
      error: (BuildContext ctx, dynamic err, dynamic _) {
        return _previewError(ctx, err.toString());
      },
      loading: (_) => const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      timeout: const Duration(seconds: 6),
    );
  }

  Widget _placeholder(BuildContext ctx, String msg) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Text(msg, style: const TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }

  Widget _previewError(BuildContext ctx, String detail) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.videocam_off, color: Colors.white54, size: 36),
          const SizedBox(height: 8),
          const Text(
            'Preview unavailable',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Open the OBSBOT Bridge app on your Mac and grant camera access when prompted (System Settings → Privacy & Security → Camera).',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              detail,
              style: const TextStyle(color: Colors.white24, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}
