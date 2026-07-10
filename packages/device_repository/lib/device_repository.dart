/// Per-camera command + optimistic-state layer for Open OBSBOT Remote.
///
/// Sits on top of [BridgeRepository] and [ObsbotApiClient]. Every method
/// takes a `deviceId` and injects it as `device_id` on the wire, so one
/// controller UI can drive N cameras. Reads come from [DeviceRepository.state],
/// which merges the bridge's real state events with short-lived optimistic
/// overlays for instant-feeling toggles and sliders.
library;

export 'src/device_repository.dart';
