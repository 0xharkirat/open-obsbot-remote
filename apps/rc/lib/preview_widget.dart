import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';

import 'grid_overlay.dart';
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

  /// Show small `+` reticle at frame center.
  final bool showCrosshair;

  /// Show solid horizontal + vertical lines through dead center.
  final bool showCenterLines;

  /// Show rule-of-thirds dashed grid.
  final bool showThirds;

  /// Show top-left Pan / Tilt degrees readout.
  final bool showReadout;

  /// Which camera to stream. Null = the selected camera (the default,
  /// used everywhere before the studio surface). A concrete id pins the
  /// stream to one camera regardless of selection - the v3 studio uses
  /// this to show the on-air (program) camera in the PiP while the
  /// large preview follows the staged camera.
  final String? deviceId;

  /// Bare feed: no grid overlay, no rounded clip, no aspect box. For the
  /// program PiP, which draws its own frame + ON AIR badge.
  final bool minimal;

  const PreviewWidget({
    super.key,
    required this.client,
    this.showCrosshair = true,
    this.showCenterLines = false,
    this.showThirds = false,
    this.showReadout = true,
    this.deviceId,
    this.minimal = false,
  });

  @override
  Widget build(BuildContext context) {
    // v2: the URL is per-device (`/preview/<sn>.mjpg`), built by the
    // bridge repository from the SELECTED camera - switching cameras
    // in the picker switches this stream on the same frame. v3 studio
    // may pin it to an explicit camera (the on-air one) instead.
    final uri = client.previewUri(deviceId: deviceId);
    if (!client.connected || uri == null) {
      return _placeholder(context, 'Connecting...');
    }
    final url = uri.toString();
    final stream = kIsWeb ? _webStream(url) : _mobileStream(url);

    if (minimal) {
      return ColoredBox(color: Colors.black, child: stream);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              stream,
              GridOverlay(
                client: client,
                showCrosshair: showCrosshair,
                showCenterLines: showCenterLines,
                showThirds: showThirds,
                showReadout: showReadout,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _webStream(String url) {
    // Image.network on Flutter web fetches bytes via HttpRequest and tries to
    // decode them as a single image  -  it can't handle multipart/x-mixed-replace.
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
            'Open the OBSBOT Bridge app on your Mac and grant camera access when prompted (System Settings > Privacy & Security > Camera).',
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
