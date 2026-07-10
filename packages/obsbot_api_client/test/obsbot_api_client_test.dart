import 'dart:async';
import 'dart:convert';

import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A WebSocketChannel whose inbound stream we drive from the test and whose
/// outbound sink we capture. Single-subscription on purpose: if the client
/// ever listens twice, `_FakeChannel` throws, which is exactly the CLAUDE.md
/// #16 regression we want to catch.
class _FakeChannel implements WebSocketChannel {
  _FakeChannel()
      : _inbound = StreamController<dynamic>(),
        _outbound = _CapturingSink();

  final StreamController<dynamic> _inbound;
  final _CapturingSink _outbound;

  List<Map<String, dynamic>> get sent => _outbound.frames;

  /// Simulate a frame arriving from the bridge.
  void emit(Map<String, dynamic> frame) => _inbound.add(jsonEncode(frame));
  void emitRaw(String raw) => _inbound.add(raw);
  void emitError(Object error) => _inbound.addError(error);
  Future<void> closeInbound() => _inbound.close();

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  WebSocketSink get sink => _outbound;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturingSink implements WebSocketSink {
  final frames = <Map<String, dynamic>>[];

  @override
  void add(dynamic data) =>
      frames.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> get done async {}
}

void main() {
  late _FakeChannel channel;
  late ObsbotApiClient client;

  ObsbotApiClient build({Duration? timeout}) {
    channel = _FakeChannel();
    return client = ObsbotApiClient(
      uri: Uri.parse('ws://localhost:8765/v1'),
      connect: (_) => channel,
      timeout: timeout ?? const Duration(milliseconds: 200),
    );
  }

  group('send', () {
    test('assigns a monotonic id and writes the frame', () async {
      build();
      unawaited(client.send(<String, dynamic>{'action': 'ping'}));
      unawaited(client.send(<String, dynamic>{'action': 'ping'}));
      await Future<void>.delayed(Duration.zero);

      expect(channel.sent, hasLength(2));
      expect(channel.sent[0]['id'], 1);
      expect(channel.sent[1]['id'], 2);
      expect(channel.sent[0]['action'], 'ping');
    });

    test('completes with the ack whose id matches', () async {
      build();
      final future = client.send(<String, dynamic>{'action': 'ping'});
      await Future<void>.delayed(Duration.zero);

      // An ack for a DIFFERENT id must not complete our future.
      channel.emit(<String, dynamic>{'id': 99, 'ok': true, 'type': 'pong'});
      channel.emit(<String, dynamic>{'id': 1, 'ok': true, 'type': 'pong'});

      expect((await future)['type'], 'pong');
    });

    test('ok:false becomes ApiActionException carrying err + msg', () async {
      build();
      final future = client.send(<String, dynamic>{'action': 'ptz.angle'});
      await Future<void>.delayed(Duration.zero);
      channel.emit(<String, dynamic>{
        'id': 1,
        'ok': false,
        'err': 'device_required',
        'msg': 'device_id is required when multiple cameras are attached',
      });

      await expectLater(
        future,
        throwsA(
          isA<ApiActionException>()
              .having((e) => e.code, 'code', 'device_required')
              .having((e) => e.message, 'message', contains('device_id')),
        ),
      );
    });

    test('no ack inside the deadline throws ApiTimeoutException', () async {
      build(timeout: const Duration(milliseconds: 50));
      await expectLater(
        client.send(<String, dynamic>{'action': 'ping'}),
        throwsA(isA<ApiTimeoutException>()),
      );
    });

    test('sending on a closed client throws ApiConnectionException', () async {
      build();
      await client.close();
      expect(
        () => client.send(<String, dynamic>{'action': 'ping'}),
        throwsA(isA<ApiConnectionException>()),
      );
    });
  });

  group('events', () {
    test('republishes unsolicited frames', () async {
      build();
      final seen = <Map<String, dynamic>>[];
      client.events.listen(seen.add);

      channel.emit(<String, dynamic>{'event': 'state', 'devices': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single['event'], 'state');
    });

    test('an ack reaches events AND completes its future', () async {
      build();
      final seen = <Map<String, dynamic>>[];
      client.events.listen(seen.add);

      final future = client.send(<String, dynamic>{'action': 'ping'});
      await Future<void>.delayed(Duration.zero);
      channel.emit(<String, dynamic>{'id': 1, 'ok': true});

      await future;
      expect(seen, hasLength(1));
    });

    test('a malformed frame is dropped, not thrown', () async {
      build();
      final seen = <Map<String, dynamic>>[];
      client.events.listen(seen.add);

      channel.emitRaw('this is not json');
      channel.emit(<String, dynamic>{'event': 'state'});
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
    });

    test('subscribes to the socket exactly once (CLAUDE.md #16)', () async {
      build();
      // Two listeners on `events` is fine because it is broadcast. The
      // regression we guard is the client listening to `channel.stream`
      // more than once, which a single-subscription controller rejects.
      client.events.listen((_) {});
      client.events.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent, isEmpty);
    });
  });

  group('socket death', () {
    test('closing the socket fails every in-flight request', () async {
      build(timeout: const Duration(seconds: 30));
      final future = client.send(<String, dynamic>{'action': 'ping'});
      await Future<void>.delayed(Duration.zero);
      await channel.closeInbound();

      await expectLater(future, throwsA(isA<ApiConnectionException>()));
    });

    test('a socket error fails every in-flight request', () async {
      build(timeout: const Duration(seconds: 30));
      final future = client.send(<String, dynamic>{'action': 'ping'});
      await Future<void>.delayed(Duration.zero);
      channel.emitError(StateError('boom'));

      await expectLater(future, throwsA(isA<ApiConnectionException>()));
    });
  });
}
