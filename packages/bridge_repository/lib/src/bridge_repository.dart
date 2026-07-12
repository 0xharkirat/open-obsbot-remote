import 'dart:async';

import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';

/// Bridge-scoped state and device management.
///
/// Sits directly on [ObsbotApiClient]. Two jobs:
///
/// 1. **State.** Filters the raw frame stream to `event == 'state'`
///    frames, decodes each into a [BridgeState], and republishes them
///    on [state] with the latest value replayed to every new listener
///    (a hand-rolled BehaviorSubject; no rxdart).
/// 2. **Device management.** Wraps the bridge-scoped device actions
///    (`device.set_active`, `device.rename`) and builds the MJPEG
///    preview URL. There is deliberately no `device.list` wrapper -
///    both apps read the device list off [BridgeState.devices], which
///    a `subscribe` immediately populates.
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

  /// Marks [deviceId] the live camera (the one `active.mjpg` follows and
  /// that OBS sees). The bridge broadcasts a fresh state event on
  /// success, which flows out through [state].
  Future<void> setActiveDevice(String deviceId, {int fadeMs = 0}) async {
    await _api.send(<String, dynamic>{
      'action': 'device.set_active',
      'device_id': deviceId,
      if (fadeMs > 0) 'fade_ms': fadeMs,
    });
  }

  /// Sets the operator-facing friendly name for [deviceId]. An empty
  /// name clears it (the UI falls back to model + last-4 of SN). The
  /// bridge owns validation (trim + 60-char cap) - one authority, no
  /// drifting duplicate here.
  Future<void> renameDevice(String deviceId, String name) async {
    await _api.send(<String, dynamic>{
      'action': 'device.rename',
      'device_id': deviceId,
      'name': name,
    });
  }

  // ---- mix.* : cross-camera sequencer (bridge-scoped, spans cameras) ----

  /// Replaces the active scratch cue list. Persists on the bridge and
  /// broadcasts a fresh state event with the new `mix.cues`.
  Future<void> setMix(List<MixCue> cues, String mode) async {
    await _api.send(<String, dynamic>{
      'action': 'mix.set',
      'cues': cues.map((c) => c.toJson()).toList(),
      'mode': mode,
    });
  }

  Future<void> startMix() =>
      _api.send(<String, dynamic>{'action': 'mix.start'});
  Future<void> stopMix() => _api.send(<String, dynamic>{'action': 'mix.stop'});

  /// Saves the cue list to the library under [name] and marks it loaded.
  Future<void> saveMixAs(String name, List<MixCue> cues, String mode) async {
    await _api.send(<String, dynamic>{
      'action': 'mix.save_as',
      'name': name,
      'cues': cues.map((c) => c.toJson()).toList(),
      'mode': mode,
    });
  }

  Future<void> loadMix(String name) =>
      _api.send(<String, dynamic>{'action': 'mix.load', 'name': name});
  Future<void> deleteMix(String name) =>
      _api.send(<String, dynamic>{'action': 'mix.delete', 'name': name});

  // ---- library.* : export/import the authored library (for Mac migration) ----

  /// Returns the whole authored library (sequences + mix + names) as a JSON
  /// map. Presets are excluded - they live on the camera hardware.
  Future<Map<String, dynamic>> exportLibrary() async {
    final ack = await _api.send(<String, dynamic>{'action': 'library.export'});
    final lib = ack['library'];
    return lib is Map<String, dynamic> ? lib : <String, dynamic>{};
  }

  /// Merges [library] back into the bridge's stored files (incoming wins per
  /// key). Names refresh live; sequences apply on the next camera re-attach.
  Future<void> importLibrary(Map<String, dynamic> library) => _api
      .send(<String, dynamic>{'action': 'library.import', 'library': library});

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
    final path =
        deviceId == null ? '/preview/active.mjpg' : '/preview/$deviceId.mjpg';
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
