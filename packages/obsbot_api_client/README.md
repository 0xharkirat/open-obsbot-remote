# obsbot_api_client

WebSocket transport for the Open OBSBOT Bridge protocol. The bottom layer of
the client stack.

## What it does

Opens one `WebSocketChannel`, assigns a monotonic `id` to every outbound
action, and correlates the bridge's ack back to the `Future` that sent it.
Frames the bridge pushes unprompted (state events) are republished on
`events`.

```dart
final api = ObsbotApiClient(uri: Uri.parse('ws://localhost:8765/v1'));

api.events.listen((frame) {
  if (frame['event'] == 'state') { /* ... */ }
});

final ack = await api.send({'action': 'ping'});
```

Failures are typed:

| Exception | When |
| --- | --- |
| `ApiConnectionException` | socket refused, died, or the client is closed |
| `ApiTimeoutException` | no ack inside the deadline (default 3s) |
| `ApiActionException` | the bridge acked `ok: false`; carries `code` + `message` |

## What it deliberately does NOT do

It does not know what a camera is. No `BridgeState`, no `DeviceState`, no
`device_id`, no optimistic UI, no reconnect policy, no auth. Those belong in
`auth_repository`, `bridge_repository`, and `device_repository`, which sit on
top of this and are the only things the app should talk to.

If you find yourself importing `obsbot_api_client` from a widget, a layer is
missing.

## Two traps this package exists to contain

**`ApiActionException.message` is developer copy, never user copy.** The
bridge's `msg` on an `auth_required` ack is a protocol hint that reads roughly
like `send {action:'pair', pin:<6-digit>}`. Rendering it under a PIN field
shipped once already. Switch on `code`; write your own user-facing string.

**`WebSocketChannel.stream` is single-subscription.** Listening twice throws,
and cancel-then-relisten silently loses every frame that arrives in the gap.
This package subscribes exactly once in the constructor and fans out through a
broadcast controller. Do not add a second `listen` to the raw channel. There
is a regression test for this.

## Testing

Inject a fake channel through the `connect` seam:

```dart
ObsbotApiClient(
  uri: Uri.parse('ws://localhost:8765/v1'),
  connect: (_) => myFakeChannel,
  timeout: const Duration(milliseconds: 200),
);
```

```bash
cd packages/obsbot_api_client
dart pub get
dart test
```
