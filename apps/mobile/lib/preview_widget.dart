import 'package:flutter/material.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';

import 'ws_client.dart';

/// Live preview from `bridge_cpp` (`/preview.mjpeg` route).
/// Falls back to a placeholder if the bridge or camera permission isn't ready.
class PreviewWidget extends StatelessWidget {
  final WsClient client;
  const PreviewWidget({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final host = client.serverUri; // e.g. "10.250.1.51:8765"
    if (!client.connected || host.isEmpty) {
      return _placeholder(context, 'Connecting...');
    }
    final url = 'http://$host/preview.mjpeg';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Mjpeg(
                stream: url,
                isLive: true,
                fit: BoxFit.contain,
                error: (BuildContext ctx, dynamic err, dynamic _) {
                  return _previewError(ctx, err.toString());
                },
                loading: (_) => const Center(
                  child: SizedBox(
                    width: 32, height: 32,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                timeout: const Duration(seconds: 6),
              ),
            ],
          ),
        ),
      ),
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
          Text(
            'Grant Terminal camera access on the Mac and restart the bridge.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(detail, style: const TextStyle(color: Colors.white24, fontSize: 10)),
          ],
        ],
      ),
    );
  }
}
