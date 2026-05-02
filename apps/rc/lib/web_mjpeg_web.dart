// Flutter web implementation: embed a real <img> element so the browser
// renders the multipart/x-mixed-replace stream natively (it can't be done
// through dart:io NetworkImage because that fetches bytes once).
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

final Set<String> _registered = <String>{};

Widget buildWebMjpegView(String url) {
  final viewType = 'obs-mjpeg-${url.hashCode}';
  if (!_registered.contains(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final img = web.HTMLImageElement()
        ..src = url
        ..alt = 'preview'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'contain'
        ..style.background = 'black';
      // Try to nudge the browser to refetch on every (re)build so the stream
      // restarts after a reconnect.
      img.crossOrigin = 'anonymous';
      return img;
    });
    _registered.add(viewType);
  }
  return HtmlElementView(viewType: viewType);
}
