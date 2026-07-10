import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'exceptions.dart';

/// Opens a [WebSocketChannel] to [uri]. Swapped out in tests.
typedef ChannelFactory = WebSocketChannel Function(Uri uri);

/// Moves JSON frames between the client and the bridge. Nothing more.
///
/// This layer does not know what a `BridgeState` is, what a camera is, or
/// what any action means. It assigns request ids, correlates acks back to
/// their futures, and republishes unsolicited frames (state events) on
/// [events]. Domain meaning lives in the repository packages above it.
///
/// Request/response frames are correlated by an `id` this client assigns.
/// Frames without an `id` (or with an unknown one) are treated as
/// unsolicited broadcasts and go to [events] only.
class ObsbotApiClient {
  ObsbotApiClient({
    required Uri uri,
    ChannelFactory? connect,
    Duration timeout = const Duration(seconds: 3),
  }) : _timeout = timeout,
       _channel = (connect ?? WebSocketChannel.connect)(uri) {
    // CLAUDE.md #16: `WebSocketChannel.stream` is single-subscription.
    // Subscribing twice throws, and cancel-then-relisten silently drops
    // every frame that arrives in the gap. Subscribe exactly once here
    // and fan out through the broadcast controller.
    _sub = _channel.stream.listen(
      _onFrame,
      onError: (Object e) => _shutdown(ApiConnectionException('$e')),
      onDone: () => _shutdown(const ApiConnectionException('socket closed')),
    );
  }

  final WebSocketChannel _channel;
  final Duration _timeout;

  late final StreamSubscription<dynamic> _sub;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  int _nextId = 1;
  bool _closed = false;

  /// Every frame the bridge sends, decoded. Broadcast, so late listeners
  /// are fine, but they see only frames that arrive after they subscribe.
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Sends [action] and completes with the matching ack.
  ///
  /// Throws [ApiActionException] when the bridge acks `ok: false`,
  /// [ApiTimeoutException] when no ack arrives inside the deadline, and
  /// [ApiConnectionException] when the socket is already gone.
  Future<Map<String, dynamic>> send(Map<String, dynamic> action) {
    if (_closed) {
      throw const ApiConnectionException('client is closed');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    _channel.sink.add(jsonEncode(<String, dynamic>{...action, 'id': id}));

    return completer.future.timeout(
      _timeout,
      onTimeout: () {
        _pending.remove(id);
        throw ApiTimeoutException(
          'no ack for "${action['action']}" within ${_timeout.inMilliseconds}ms',
        );
      },
    );
  }

  void _onFrame(dynamic raw) {
    final Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw as String) as Map<String, dynamic>;
    } on Object {
      return; // A frame we cannot parse is a frame we cannot route.
    }

    if (!_events.isClosed) _events.add(frame);

    final id = frame['id'];
    if (id is! int) return; // Unsolicited: state events and the like.
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    if (frame['ok'] == false) {
      completer.completeError(
        ApiActionException(
          frame['err'] as String? ?? 'unknown',
          frame['msg'] as String? ?? '',
        ),
      );
    } else {
      completer.complete(frame);
    }
  }

  /// Fails every in-flight request, then tears the client down. Callers
  /// waiting on [send] get [cause] rather than hanging until timeout.
  void _shutdown(ApiException cause) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(cause);
    }
    _pending.clear();
    if (!_events.isClosed) _events.close();
  }

  Future<void> close() async {
    _shutdown(const ApiConnectionException('client closed by caller'));
    await _sub.cancel();
    await _channel.sink.close();
  }
}
