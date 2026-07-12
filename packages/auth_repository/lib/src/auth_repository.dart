import 'dart:async';

import 'package:obsbot_api_client/obsbot_api_client.dart';

import 'auth_status.dart';
import 'auth_storage.dart';
import 'pair_exception.dart';

/// Owns the phone's auth relationship with one bridge.
///
/// It runs the `hello` / `pair` handshake over [ObsbotApiClient], persists the
/// per-bridge token through [AuthStorage], and publishes an [AuthStatus] stream
/// the app routes off. It does not own the api client: closing this repository
/// leaves the transport alone.
///
/// Per-host keying: the token is stored under `token::<hostPort>` so two
/// bridges on one LAN never share a token. `hostPort` is passed in rather than
/// parsed here, which keeps this package free of URI handling.
class AuthRepository {
  AuthRepository({
    required ObsbotApiClient api,
    required AuthStorage storage,
    required String hostPort,
  }) : _api = api,
       _storage = storage,
       _tokenKey = 'token::$hostPort';

  final ObsbotApiClient _api;
  final AuthStorage _storage;

  /// Matches v1's `WsClient._tokenKey`, so a phone upgrading from v1 finds the
  /// token it already paired with instead of re-prompting for the PIN.
  final String _tokenKey;

  // Hand-rolled cached-value broadcast: `_current` is the latest value and
  // `_changes` fans out transitions. `status` (below) replays `_current` to
  // every late listener via `Stream.multi`, so a bloc that subscribes after
  // authentication still sees the current state. No rxdart, no BehaviorSubject.
  final _changes = StreamController<AuthStatus>.broadcast();
  AuthStatus _current = AuthStatus.unknown;
  String? _token;

  /// The current status. Cheap synchronous read for guards and tests.
  AuthStatus get current => _current;

  /// The saved token, or null when unauthenticated. The MJPEG preview URL
  /// builder needs this to append `?t=<token>`.
  String? get token => _token;

  /// Broadcast stream of status transitions that replays the latest value to
  /// late subscribers.
  Stream<AuthStatus> get status => Stream<AuthStatus>.multi((controller) {
    controller.add(_current);
    final sub = _changes.stream.listen(
      controller.add,
      onError: controller.addError,
    );
    controller.onCancel = sub.cancel;
  });

  /// Sends `hello`, carrying the saved token when there is one.
  ///
  /// Success -> [AuthStatus.authenticated]. An `auth_required` rejection is a
  /// STATE TRANSITION, not an error: it moves to [AuthStatus.unauthenticated]
  /// and, per CLAUDE.md #41, carries no message. Any other action error, or a
  /// transport failure, propagates untouched.
  Future<void> authenticate() async {
    final saved = await _storage.read(_tokenKey);
    try {
      await _api.send(<String, dynamic>{
        'action': 'hello',
        // Omit the key entirely when absent; the bridge treats a missing
        // token exactly like a bad one, but this keeps the frame honest.
        if (saved != null) 'token': saved,
      });
      _token = saved;
      _emit(AuthStatus.authenticated);
    } on ApiActionException catch (e) {
      if (e.code != 'auth_required') rethrow;
      // Do NOT touch e.message here. It is the bridge's developer-facing
      // protocol hint; surfacing it as user copy is CLAUDE.md #41.
      _emit(AuthStatus.unauthenticated);
    }
  }

  /// Pairs with the 6-digit [pin] shown in the bridge UI.
  ///
  /// On success the bridge acks a 32-byte-hex token; it is saved under the
  /// per-host key and status becomes [AuthStatus.authenticated]. A wrong PIN
  /// (or any other bridge rejection) throws [PairException]; a transport
  /// failure ([ApiConnectionException] / [ApiTimeoutException]) propagates
  /// untouched so the UI can tell "wrong PIN" from "cannot reach the bridge".
  Future<void> pair(String pin) async {
    final Map<String, dynamic> ack;
    try {
      ack = await _api.send(<String, dynamic>{'action': 'pair', 'pin': pin});
    } on ApiActionException catch (e) {
      // e.message is the bridge's `msg` ("wrong PIN", plus protocol shape on
      // some codes). PairException has no slot for it, so it cannot leak.
      throw PairException(e.code);
    }

    final token = ack['token'];
    if (token is! String || token.isEmpty) {
      // ok:true with no token is a bridge bug, not a wrong PIN, but from the
      // caller's side pairing still did not work. One failure type to catch.
      throw const PairException('no_token');
    }

    await _storage.write(_tokenKey, token);
    _token = token;
    _emit(AuthStatus.authenticated);
  }

  /// Forgets the saved token and drops to [AuthStatus.unauthenticated].
  Future<void> logOut() async {
    await _storage.delete(_tokenKey);
    _token = null;
    _emit(AuthStatus.unauthenticated);
  }

  /// Closes the status stream. Does not close the injected [ObsbotApiClient];
  /// this repository does not own it.
  Future<void> dispose() => _changes.close();

  void _emit(AuthStatus next) {
    if (next == _current) return;
    _current = next;
    if (!_changes.isClosed) _changes.add(next);
  }
}
