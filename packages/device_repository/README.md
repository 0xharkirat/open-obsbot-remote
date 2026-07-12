# device_repository

Per-camera commands and optimistic state for Open OBSBOT Remote. The top of the client
data stack: widgets talk to this, not to `bridge_repository` or `obsbot_api_client`.

```dart
final api = ObsbotApiClient(uri: Uri.parse('ws://localhost:8765/v1'));
final bridge = BridgeRepository(api: api);
final devices = DeviceRepository(api: api, bridge: bridge);

devices.state.listen((s) => render(s));           // real events + optimistic overlays

await bridge.subscribe();
await devices.hdr(deviceId: 'RMOW...', enabled: true);
await devices.zoomSet(deviceId: 'RMOW...', value: 2.0, terminal: true,
    duration: const Duration(seconds: 5));
```

Every method takes `deviceId` first and injects it as `device_id` on the wire, so one
controller UI can drive N cameras. `ptz.angle` is intentionally not exposed - it had
zero callers in the v1 client. Frames never carry an `id`; `obsbot_api_client` assigns
it.

## The optimistic overlay

A tap on HDR must flip the button on the same frame, not 200-500 ms later when the
bridge echoes over Wi-Fi. So each mutating method writes a **per-device, per-field**
overlay and emits merged state immediately, then sends the wire command.

`state` = the bridge's real `BridgeState` with every live overlay applied on top,
per device via `BridgeState.withDevice`. Consequences:

- An HDR overlay on camera A never touches camera B.
- A slow-settling zoom overlay on A never masks a concurrent AI-mode overlay on A - each
  field is a separate overlay that settles on its own.
- A real state event for a device supersedes its overlays, **including when the camera
  clamped or rejected**: request `zoom 4.0`, the camera reports `2.0`, and the UI
  settles at `2.0` because the echo drops the overlay and the real value shows through.

Only fields the client can predict get an overlay: `zoom`, `ai` mode/sub-mode, `hdr`,
`fov`, `face_ae`, `face_focus`, `flip_h`, the color sliders, exposure mode, EV bias,
anti-flicker, WB auto, WB kelvin. PTZ (continuous motion), preset recall (pose values
not known locally), `image.refresh`, sequences, and run-status send with no overlay.

### The stale-event race, and how it is solved

The naive rule "drop the overlay on the next state event" is **wrong**. State events
poll about every 500 ms, so when the user taps, an event generated *before* the tap is
often already in flight. It does not carry the user's value. Dropping the overlay on
that event resurrects the stale value for one frame before the next event finally shows
the new one - a visible flicker.

The fix keys off the **ack**, which is a synchronization point in the single ordered
WebSocket stream. Frames arrive in send order over TCP, and the bridge stamps its
snapshot then acks, so on the wire the order is:

```
[stale in-flight event] ... [our ack] ... [reflecting event]
```

So the overlay is held until its write is acked (it becomes `armed`), and only the first
real state event *after* that ack drops it. The stale event arrives before the ack and
is ignored; the reflecting event - carrying the applied or camera-clamped value - arrives
after and wins.

**Rapid slider drags** send many writes for one field before any acks return. An
`openSends` counter tracks them: the overlay stays pinned to the latest value and only
arms when the *last* write is acked, so the UI never flickers back to a stale real value
mid-drag. `zoomSet` also enforces CLAUDE.md #28 - mid-drag frames are always
`duration_ms: 0` (a non-zero mid-drag duration makes the bridge planner cancel/restart
every 100 ms); the chosen duration and `final: true` ride only on the release frame.

### Why this design, and what was rejected

- **Pure TTL** (hold each overlay N ms, then drop). Rejected: it cannot tell a
  pre-tap stale event from the reflecting one, so either N is too short (flicker) or too
  long (a clamp like `4.0 -> 2.0` lingers wrong for the whole window). Ack-gating settles
  in exactly one event with no guessed timeout on the happy path.
- **Skip-one-event** (ignore the first event after a write). Rejected: the number of
  in-flight events is 0, 1, or more depending on timing; a fixed skip count is wrong for
  all but one of them.

TTL survives here only as a **safety net**: an armed overlay is force-dropped after 5 s if
no state event ever settles it (see below). It never drives the happy path.

## Failure modes

- **Command rejected (`ApiActionException`) or timed out.** The error propagates to the
  caller, but the overlay is still armed in a `finally`, so the next real state event
  reverts the optimistic value to the truth. The UI self-corrects; the caller may also
  surface the error.
- **Bridge never broadcasts after a command.** The armed overlay would otherwise linger
  forever showing a possibly-wrong value. A 5 s per-overlay safety timer force-drops it
  and re-emits, converging to the last real state. The bridge broadcasts after every
  command in practice, so this only guards a misbehaving bridge.
- **Device detached mid-overlay.** `withDevice` throws if the device is gone; the merge
  guards with `deviceById(id) != null` and simply skips the overlay for a device no
  longer in the real state.

## Move-duration preference

`presetRecall` and `zoomSet` forward the caller's chosen `duration` straight through
(omitted -> `Duration.zero`, the camera's fastest path). The v1 client's persisted
`move_duration_ms` default was UI state; it belongs in the presentation layer above this
repository, which now just carries whatever it is handed.

## Testing

```bash
cd packages/device_repository
dart pub get
very_good test    # bare `dart test` is blocked by a repo hook
```
