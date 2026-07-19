import 'package:meta/meta.dart';

/// One camera AVFoundation can see, as listed by `source.list`.
///
/// Wire shape (see `apps/bridge_cpp/src/device_manager.cpp`
/// `available_sources()`):
/// ```json
/// {"unique_id": "0x1234...", "name": "FaceTime HD Camera",
///  "obsbot": false, "in_use": false}
/// ```
///
/// The picker adds a source with `source.add {unique_id, label}`; the
/// bridge then addresses it as device_id `av:<unique_id>`.
@immutable
class AvailableSource {
  /// AVFoundation's stable uniqueID for this capture device.
  final String uniqueId;

  /// Human-readable device name (e.g. "Camo Studio Virtual Camera").
  final String name;

  /// True when this is OBSBOT hardware. The bridge refuses to add it as
  /// a generic source (it already gets a full session over USB), so the
  /// picker shows it disabled.
  final bool obsbot;

  /// True when this uniqueID is already bound - either to an OBSBOT
  /// session's capture or to an added generic source.
  final bool inUse;

  const AvailableSource({
    required this.uniqueId,
    required this.name,
    required this.obsbot,
    required this.inUse,
  });

  /// A source the picker lets the user add.
  bool get addable => !obsbot && !inUse;

  factory AvailableSource.fromJson(Map<String, dynamic> j) => AvailableSource(
    uniqueId: j['unique_id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    obsbot: j['obsbot'] as bool? ?? false,
    inUse: j['in_use'] as bool? ?? false,
  );
}
