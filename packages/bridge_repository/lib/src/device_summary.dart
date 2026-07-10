import 'package:meta/meta.dart';

/// The lightweight per-camera record returned by `device.list`.
///
/// This is the picker-row shape: just enough to draw the device list
/// and badge the live one. The full per-camera snapshot (PTZ, zoom,
/// image, presets, sequence) lives in `DeviceState` inside the state
/// event, not here.
///
/// Wire shape (one entry of the `device.list` ack's `devices` array):
/// ```json
/// {
///   "device_id": "RMOWLHH3281PMV",
///   "model_display": "Tiny 2 Lite",
///   "sn": "RMOWLHH3281PMV",
///   "connected": true,
///   "friendly_name": "Vocal"
/// }
/// ```
@immutable
class DeviceSummary {
  const DeviceSummary({
    required this.deviceId,
    required this.modelDisplay,
    required this.sn,
    required this.connected,
    required this.friendlyName,
  });

  factory DeviceSummary.fromJson(Map<String, dynamic> j) => DeviceSummary(
    deviceId: j['device_id'] as String? ?? '',
    modelDisplay: j['model_display'] as String? ?? '',
    sn: j['sn'] as String? ?? '',
    connected: j['connected'] as bool? ?? false,
    friendlyName: j['friendly_name'] as String? ?? '',
  );

  /// Camera serial. The addressing key on every action and the path
  /// component in the per-camera MJPEG URL.
  final String deviceId;

  /// Human model label, e.g. `Tiny 2 Lite`.
  final String modelDisplay;

  /// Same serial as [deviceId]; carried separately to mirror the wire.
  final String sn;

  /// Whether libdev currently sees the camera.
  final bool connected;

  /// Operator name set via `device.rename`. Empty when unset.
  final String friendlyName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceSummary &&
          deviceId == other.deviceId &&
          modelDisplay == other.modelDisplay &&
          sn == other.sn &&
          connected == other.connected &&
          friendlyName == other.friendlyName;

  @override
  int get hashCode =>
      Object.hash(deviceId, modelDisplay, sn, connected, friendlyName);

  @override
  String toString() =>
      'DeviceSummary($deviceId, $modelDisplay, connected: $connected, '
      'friendlyName: "$friendlyName")';
}
