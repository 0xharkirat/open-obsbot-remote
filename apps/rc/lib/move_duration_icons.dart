import 'package:flutter/material.dart';

/// Flutter-side icon mapping for the well-known move-duration chip
/// strip (the `kMoveDurationPresets` list in `package:obsbot_protocol`).
/// The protocol package stays pure-Dart; the icon mapping is UI
/// metadata and lives here so the package can be reused outside
/// Flutter.
///
/// `const Map<Duration, IconData>` is rejected by the analyzer
/// because `Duration` overrides `==`. A switch on `inMilliseconds`
/// is equivalent and lets the values stay compile-time constants.
IconData iconForMoveDuration(Duration d) => switch (d.inMilliseconds) {
      0 => Icons.flash_on,
      1000 => Icons.bolt,
      5000 => Icons.directions_run,
      15000 => Icons.directions_walk,
      30000 => Icons.movie_creation_outlined,
      60000 => Icons.hourglass_bottom,
      180000 => Icons.hourglass_top,
      300000 => Icons.hourglass_empty,
      _ => Icons.timer,
    };
