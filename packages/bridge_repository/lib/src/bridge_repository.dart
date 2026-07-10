import 'dart:async';

import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';

import 'device_summary.dart';

/// Bridge-scoped state and device management.
///
/// Sits directly on [ObsbotApiClient]. Two jobs:
///
/// 1. **State.** Filters the raw frame stream to `event == 'state'`
///    frames, decodes each into a [BridgeState], and republishes them
///    on [state] with the latest value replayed to every new listener
///    (a hand-rolled BehaviorSubject; no rxdart).
/// 2. **Device management.** Wraps the three bridge-scoped device
///    actions (`device.list`, `device.set_active`, `device.rename`)
///    and builds the MJPEG preview URL.
///
/// Per-device optimistic UI and gimbal/image commands live one layer
/// up in `device_repository`. This layer never mutates state
/// optimistically: every value it emits came from the bridge.
class BridgeRepository {
  BridgeRepository({required ObsbotApiClient api}) : _api = api {
    _sub = _api.events.where(_isStateEvent).listen(_onStateFrame);
  }

  final ObsbotApiClient _api;
  late final StreamSubscription<Map<String, dynamic>> _sub;

  /// Live updates only. New listeners get the replayed [_current] first
  /// via the [state] getter's wrapper, then this stream's live events.
  final _updates = StreamController<BridgeState>.broadcast();

  BridgeState _current = BridgeState.empty;

  /// Latest decoded bridge state. Seeded [BridgeState.empty] until the
  /// first state event lands.
  BridgeState get current => _current;

  /// Broadcast stream of bridge state, seeded and replaying the latest
  /// value to every subscriber the moment it listens.
  ///
  /// Hand-rolled replay: each subscription gets its own wrapper
  /// controller whose `onListen` synchronously emits [_current] and
  /// then forwards live updates. Emitting the seed and subscribing to
  /// the source both happen inside `onListen` with no `await` between
  /// them, so no update can slip through the gap - the flaw a naive
  /// `async* { yield _current; yield* _updates.stream; }` has.
  Stream<BridgeState> get state {
    late final StreamController<BridgeState> out;
    StreamSubscription<BridgeState>? live;
    out = StreamController<BridgeState>(
      onListen: () {
        out.add(_current);
        live = _updates.stream.listen(out.add);
      },
      onCancel: () => live?.cancel(),
    );
    return out.stream;
  }

  static bool _isStateEvent(Map<String, dynamic> f) => f['event'] == 'state';

  void _onStateFrame(Map<String, dynamic> frame) {
    _current = BridgeState.fromEvent(frame);
    if (!_updates.isClosed) _updates.add(_current);
  }

  /// Tells the bridge to start pushing state events on this connection.
  /// The ack is immediately followed by a full state event.
  Future<void> subscribe() async {
    await _api.send(<String, dynamic>{'action': 'subscribe'});
  }

  /// Returns the picker-row summary for every attached camera. Cheaper
  /// than waiting for a full state event when only the device list is
  /// needed.
  Future<List<DeviceSummary>> listDevices() async {
    final ack = await _api.send(<String, dynamic>{'action': 'device.list'});
    final raw = ack['devices'] as List<dynamic>? ?? const <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DeviceSummary.fromJson)
        .toList(growable: false);
  }

  /// Marks [deviceId] the live camera (the one `active.mjpg` follows and
  /// that OBS sees). The bridge broadcasts a fresh state event on
  /// success, which flows out through [state].
  Future<void> setActiveDevice(String deviceId) async {
    await _api.send(<String, dynamic>{
      'action': 'device.set_active',
      'device_id': deviceId,
    });
  }

  /// Sets the operator-facing friendly name for [deviceId].
  ///
  /// The name is trimmed and capped at 60 characters. An empty result
  /// clears the name (the UI then falls back to model + last-4 of SN).
  /// The bridge applies the same trim/cap; doing it here keeps the
  /// optimistic path and any local echo consistent with what persists.
  Future<void> renameDevice(String deviceId, String name) async {
    var trimmed = name.trim();
    if (trimmed.length > 60) trimmed = trimmed.substring(0, 60);
    await _api.send(<String, dynamic>{
      'action': 'device.rename',
      'device_id': deviceId,
      'name': trimmed,
    });
  }

  /// Builds the MJPEG preview URL on the HTTP port (`ws_port + 1`).
  ///
  /// [deviceId] null -> `/preview/active.mjpg`, the follow-the-live
  /// stream that OBS consumes. A concrete id -> `/preview/<id>.mjpg`,
  /// one fixed camera. The [token] is carried as the `?t=` query param,
  /// the same token the WebSocket paired with.
  Uri previewUri({
    required String host,
    required int port,
    required String token,
    String? deviceId,
  }) {
    final path = deviceId == null
        ? '/preview/active.mjpg'
        : '/preview/$deviceId.mjpg';
    return Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: path,
      queryParameters: <String, String>{'t': token},
    );
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await _updates.close();
  }
}
