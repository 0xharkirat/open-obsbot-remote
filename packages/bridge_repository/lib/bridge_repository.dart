/// Bridge-scoped state + device management for Open OBSBOT Remote.
///
/// One layer above [ObsbotApiClient]. It filters the raw frame stream
/// down to state events, decodes them into [BridgeState], and exposes
/// the bridge-wide commands (`device.set_active`, `device.rename`) plus the MJPEG preview URL builder.
///
/// It does NOT drive a gimbal or hold optimistic per-device UI state -
/// that is `device_repository`, which sits on top of this.
library;

export 'src/bridge_repository.dart';
