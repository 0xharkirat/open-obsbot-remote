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
- `CameraState` - the full decoded `state` event payload.
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

final state = CameraState.fromEvent(jsonDecode(wsFrame));
if (state.connected) print('Zoom: ${state.zoom.toStringAsFixed(2)}x');
```

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
  bridge's `hello` ack carries a `server.protocol` integer that
  clients should compare against their compiled-in version.

Current package version: `0.1.0` (matches bridge protocol `1`).
