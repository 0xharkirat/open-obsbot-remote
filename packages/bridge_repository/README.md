# bridge_repository

Bridge-scoped state and actions for Open OBSBOT Remote.
One layer above [`obsbot_api_client`](../obsbot_api_client) and below [`device_repository`](../device_repository).

## What it does

- State. Filters the raw frame stream to `event == 'state'` frames, decodes each into a `BridgeState` (from `obsbot_protocol`), and republishes them on `state` with the latest value replayed to every new listener.
- Bridge-scoped actions. Wraps the actions that are not tied to one camera: set the active (on-air) camera, rename a camera, drive the cross-camera mix sequencer, and export or import the library. It also builds the MJPEG preview URL.

There is no `device.list` wrapper on purpose.
Both apps read the device list off `BridgeState.devices`, which a `subscribe` populates immediately.

```dart
final api = ObsbotApiClient(uri: Uri.parse('ws://localhost:8765/v1'));
final bridge = BridgeRepository(api: api);

bridge.state.listen((s) => print('active: ${s.activeDeviceId}, ${s.devices.length} cams'));

await bridge.subscribe();
await bridge.setActiveDevice('RMOWLHHC233LOQ');           // device.set_active (hard cut)
await bridge.setActiveDevice('RMOW...', fadeMs: 500);     // crossfade
await bridge.renameDevice('RMOW...', 'Vocal');            // device.rename (trim, cap 60)

await bridge.setMix(cues, 'forward');                     // mix.set
await bridge.startMix();                                  // mix.start

final blob = await bridge.exportLibrary();                // library.export -> JSON map
await bridge.importLibrary(blob);                         // library.import (merge)

final fixed = bridge.previewUri(                          // one camera
  host: '10.0.0.5', port: 8766, token: tok, deviceId: 'RMOW...',
);
final live = bridge.previewUri(                           // follow the active camera
  host: '10.0.0.5', port: 8766, token: tok,               // deviceId omitted -> active.mjpg
);
```

## API

| Member | Wire | Notes |
| --- | --- | --- |
| `state` | `event: state` frames | Broadcast, seeded `BridgeState.empty`, replays latest. |
| `current` | - | Latest decoded state, read synchronously. |
| `subscribe()` | `subscribe` | Bridge then pushes a full state event. |
| `setActiveDevice(id, {fadeMs})` | `device.set_active` | `fadeMs > 0` crossfades into the incoming camera instead of cutting. |
| `renameDevice(id, name)` | `device.rename` | Trims, caps at 60 chars; empty clears. |
| `setMix / startMix / stopMix` | `mix.set` / `mix.start` / `mix.stop` | Cross-camera cue timeline. |
| `saveMixAs / loadMix / deleteMix` | `mix.save_as` / `mix.load` / `mix.delete` | Named mix library. |
| `exportLibrary() / importLibrary(map)` | `library.export` / `library.import` | Sequences, mixes, and names as JSON. |
| `previewUri(...)` | `:8766/preview/...` | `deviceId` null -> `active.mjpg`; else `<id>.mjpg`. |

## What it does not do

No optimistic UI. Every value `state` emits came from the bridge.
Per-device gimbal, zoom, and image commands, and their instant-feedback overlays, live in `device_repository`, which sits on top of this layer.

## Replay stream (no rxdart)

`state` is a hand-rolled replay-the-latest broadcast.
Each subscription gets its own wrapper controller whose `onListen` synchronously emits `current` and then forwards live updates.
Emitting the seed and subscribing to the source both happen inside `onListen` with no `await` between them, so a late listener always gets the latest state and no update slips through a seed/subscribe gap.

## Testing

```bash
cd packages/bridge_repository
dart pub get
very_good test    # bare `dart test` is blocked by a repo hook
```
