import 'package:meta/meta.dart';

/// One saved preset on the camera (mirrored from the bridge `state`
/// event, `presets` array).
///
/// Mirrors the C++ `PresetInfo` struct on the bridge side and the
/// OBSBOT SDK's `PresetPosInfo`. Angles are in degrees; zoom is a
/// float multiplier in the camera's reported range (1.0..2.0 on
/// Tiny 2 Lite, 1.0..4.0 on Tiny 2 / Tail Air).
@immutable
class PresetEntry {
  /// Preset slot id. Tiny 2 Lite supports 0..5 (P1..P6 in the UI).
  final int id;

  /// User-set name. Empty string for an unsaved slot. The OBSBOT SDK
  /// caps name length at 64 bytes; clients should respect that.
  final String name;

  /// Camera attitude in degrees at the time the preset was saved.
  final double yaw;
  final double pitch;
  final double roll;

  /// Camera zoom multiplier at the time the preset was saved.
  /// Use `camera.state.zoom.min` / `max` to clamp.
  final double zoom;

  const PresetEntry({
    required this.id,
    required this.name,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.zoom,
  });

  factory PresetEntry.fromJson(Map<String, dynamic> j) => PresetEntry(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        yaw: (j['yaw'] as num?)?.toDouble() ?? 0,
        pitch: (j['pitch'] as num?)?.toDouble() ?? 0,
        roll: (j['roll'] as num?)?.toDouble() ?? 0,
        zoom: (j['zoom'] as num?)?.toDouble() ?? 1,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'yaw': yaw,
        'pitch': pitch,
        'roll': roll,
        'zoom': zoom,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresetEntry &&
          id == other.id &&
          name == other.name &&
          yaw == other.yaw &&
          pitch == other.pitch &&
          roll == other.roll &&
          zoom == other.zoom;

  @override
  int get hashCode => Object.hash(id, name, yaw, pitch, roll, zoom);
}
