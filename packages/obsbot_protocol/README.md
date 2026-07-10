# obsbot_protocol

Pure-Dart types for the WebSocket protocol between Open OBSBOT Remote
clients and the Open OBSBOT Bridge. No Flutter dependency, so it can
be used from any client (mobile, web, desktop) or from a Dart-based
bridge UI without dragging in Material.

Wire-format spec lives in [`docs/PROTOCOL.md`](../../docs/PROTOCOL.md)
at the repo root. The bridge implementation is in
[`apps/bridge_cpp/src/protocol.cpp`](../../apps/bridge_cpp/src/protocol.cpp).
This package is the Dart-side mirror.

## What you get

- `PresetEntry` - one saved preset on the camera.
- `SequenceStep` - one step in a sequence (preset id + hold seconds +
  transition duration).
- `SequenceState` - sequencer block from the `state` event (running
  flag, current step, library, active edit list).
- `DeviceState` - one camera's full snapshot (PTZ, zoom, AI, image,
  exposure / WB, presets, per-device sequence). Multiple cameras
  appear as multiple `DeviceState`s.
- `BridgeState` - the top-level `state` event envelope. Owns the
  `devices` list + `activeDeviceId` (which camera is currently going
  out to OBS). `BridgeState.deviceById(id)` + `BridgeState.withDevice`
  for routing per-device mutations.
- `LoopMode` + `loopModeToWire` / `loopModeFromWire` /
  `loopModeLabel`.
- `MoveDurationPreset` + `kMoveDurationPresets` +
  `formatMoveDuration` - the well-known move-duration chip strip
  (Instant / 1 sec / 5 sec / 15 sec / 30 sec / 1 min / 3 min /
  5 min). Pure data; no `IconData`. The UI layer attaches icons.

## Use it

```yaml
dependencies:
  obsbot_protocol:
    path: ../../packages/obsbot_protocol
```

```dart
import 'package:obsbot_protocol/obsbot_protocol.dart';

final bridge = BridgeState.fromEvent(jsonDecode(wsFrame));
for (final dev in bridge.devices) {
  print('${dev.displayName}: zoom ${dev.zoom.toStringAsFixed(2)}x');
}
final live = bridge.activeDevice;
if (live != null) print('OBS sees: ${live.displayName}');
```

## v2 break - multi-cam

v1.x called the single-camera snapshot `CameraState` and pushed it
directly as the state event. v2 splits this into:

- `DeviceState` (per-camera, same fields as v1 `CameraState` + new
  `deviceId` + `friendlyName`)
- `BridgeState` (envelope holding the device list + the live id)

v1 clients connecting to a v2 bridge fail at the state-event parse
step (no `devices` array). v2 clients connecting to a v1 bridge use
the `BridgeState.fromEvent` fallback that wraps the single device into
a one-element list - transitional during the rollout window.

## Tests

JSON round-trip + default-value tests for every type:

```bash
cd packages/obsbot_protocol
dart pub get
dart test
```

## Versioning

The package version tracks the wire protocol version, not the
Open OBSBOT Remote app version. Bumps:

- Patch: defaults added, optional fields, no breaking change.
- Minor: new actions, new state fields. Old clients still work.
- Major: breaking change to existing field names / types. The
  state event carries a `version` field clients can compare
  against their compiled-in version.

Current package version: `1.0.0` (matches bridge protocol `2.0`).
