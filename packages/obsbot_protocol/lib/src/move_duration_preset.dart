import 'package:meta/meta.dart';

/// One entry in the well-known move-duration chip strip.
///
/// The bridge's motion planner accepts any positive integer
/// `duration_ms`, but the UI exposes a curated set of common values
/// so the operator does not have to type ms. Pure-Dart (no
/// `IconData`) so the package can be used outside Flutter; the UI
/// layer attaches an icon per preset.
@immutable
class MoveDurationPreset {
  /// Human-readable label, e.g. "Instant", "5 sec", "3 min".
  final String label;

  /// Move duration in ms. `Duration.zero` means instant (hardware
  /// path, no planner).
  final Duration duration;

  const MoveDurationPreset(this.label, this.duration);
}

/// The chip strip shown at the bottom of the Joystick and Buttons
/// tabs in the v1.2 advanced UI. Keep in sync with the wire-format
/// expectations: every entry is a valid `duration_ms` value the
/// bridge accepts.
const List<MoveDurationPreset> kMoveDurationPresets = <MoveDurationPreset>[
  MoveDurationPreset('Instant', Duration.zero),
  MoveDurationPreset('1 sec', Duration(milliseconds: 1000)),
  MoveDurationPreset('5 sec', Duration(milliseconds: 5000)),
  MoveDurationPreset('15 sec', Duration(milliseconds: 15000)),
  MoveDurationPreset('30 sec', Duration(milliseconds: 30000)),
  MoveDurationPreset('1 min', Duration(milliseconds: 60000)),
  MoveDurationPreset('3 min', Duration(milliseconds: 180000)),
  MoveDurationPreset('5 min', Duration(milliseconds: 300000)),
];

/// Pretty-print a `Duration` as `Instant`, `5 sec`, `2m 30s`, etc.
String formatMoveDuration(Duration d) {
  if (d == Duration.zero) return 'Instant';
  if (d.inMinutes >= 1) {
    final m = d.inMinutes;
    final s = d.inSeconds - m * 60;
    return s == 0 ? '$m min' : '${m}m ${s}s';
  }
  final ms = d.inMilliseconds;
  return '${(ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1)} sec';
}
