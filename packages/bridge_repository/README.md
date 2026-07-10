# bridge_repository

Bridge-scoped state and device management for Open OBSBOT Remote. One layer above
[`obsbot_api_client`](../obsbot_api_client) and below
[`device_repository`](../device_repository).

## What it does

- **State.** Filters the raw frame stream down to `event == 'state'` frames, decodes
  each into a `BridgeState` (from `obsbot_protocol`), and republishes them on `state`
  with the latest value replayed to every new listener.
- **Device management.** Wraps the three bridge-scoped device actions and builds the
  MJPEG preview URL.

```dart
final api = ObsbotApiClient(uri: Uri.parse('ws://localhost:8765/v1'));
final bridge = BridgeRepository(api: api);

bridge.state.listen((s) => print('active: ${s.activeDeviceId}, ${s.devices.length} cams'));

await bridge.subscribe();
final devices = await bridge.listDevices();      // List<DeviceSummary>
await bridge.setActiveDevice('RMOWLHHC233LOQ');  // device.set_active
await bridge.renameDevice('RMOW...', 'Vocal');   // device.rename (trim, cap 60)

final preview = bridge.previewUri(
  host: '10.0.0.5', port: 8766, token: tok,      // per-camera stream
  deviceId: 'RMOW...',
);
final live = bridge.previewUri(                  // follow-the-live-camera stream
  host: '10.0.0.5', port: 8766, token: tok,      // deviceId omitted -> active.mjpg
);
```

## API

| Member | Wire | Notes |
| --- | --- | --- |
| `state` | `event: state` frames | Broadcast, seeded `BridgeState.empty`, replays latest. |
| `current` | - | Latest decoded state, read synchronously. |
| `subscribe()` | `subscribe` | Bridge then pushes a full state event. |
| `listDevices()` | `device.list` | Parses the ack into `List<DeviceSummary>`. |
| `setActiveDevice(id)` | `device.set_active` | Bridge broadcasts a state event on success. |
| `renameDevice(id, name)` | `device.rename` | Trims, caps at 60 chars; empty clears. |
| `previewUri(...)` | `:8766/preview/...` | `deviceId` null -> `active.mjpg`; else `<id>.mjpg`. |

## What it deliberately does NOT do

No optimistic UI. Every value `state` emits came from the bridge. Per-device gimbal /
zoom / image commands and their instant-feedback overlays live in `device_repository`,
which takes a `BridgeRepository` and sits on top of this.

## Replay stream (no rxdart)

`state` is a hand-rolled "replay the latest" broadcast. Each subscription gets its own
wrapper controller whose `onListen` synchronously emits `current` and then forwards
live updates. Emitting the seed and subscribing to the source both happen inside
`onListen` with no `await` between them, so a late listener always gets the latest
state and no update can slip through a seed/subscribe gap.

## Testing

```bash
cd packages/bridge_repository
dart pub get
very_good test    # bare `dart test` is blocked by a repo hook
```
