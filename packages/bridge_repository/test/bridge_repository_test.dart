import 'dart:async';

import 'package:bridge_repository/bridge_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';
import 'package:test/test.dart';

class _MockApi extends Mock implements ObsbotApiClient {}

/// A minimal state event for one device, enough to exercise the mapping.
Map<String, dynamic> _stateEvent({
  required String activeId,
  required List<Map<String, dynamic>> devices,
  String version = '2.0',
}) =>
    <String, dynamic>{
      'event': 'state',
      'version': version,
      'active_device_id': activeId,
      'devices': devices,
    };

Map<String, dynamic> _device(String id, {String name = ''}) =>
    <String, dynamic>{
      'device_id': id,
      'device': <String, dynamic>{
        'sn': id,
        'model_display': 'Tiny 2 Lite',
        'connected': true,
        'friendly_name': name,
      },
    };

void main() {
  late _MockApi api;
  late StreamController<Map<String, dynamic>> events;

  setUp(() {
    api = _MockApi();
    events = StreamController<Map<String, dynamic>>.broadcast();
    when(() => api.events).thenAnswer((_) => events.stream);
  });

  tearDown(() => events.close());

  BridgeRepository build() => BridgeRepository(api: api);

  group('state', () {
    test('current seeds to BridgeState.empty before any event', () {
      final repo = build();
      expect(repo.current, same(BridgeState.empty));
    });

    test('maps a state event into BridgeState and updates current', () async {
      final repo = build();
      final seen = <BridgeState>[];
      repo.state.listen(seen.add);

      events.add(_stateEvent(
        activeId: 'A',
        devices: [_device('A', name: 'Vocal'), _device('B')],
      ));
      await pumpEventQueue();

      expect(repo.current.devices, hasLength(2));
      expect(repo.current.activeDeviceId, 'A');
      expect(repo.current.deviceById('A')!.friendlyName, 'Vocal');
      // seed (empty) + the mapped event.
      expect(seen.last.activeDeviceId, 'A');
    });

    test('ignores non-state frames', () async {
      final repo = build();
      events.add(<String, dynamic>{'type': 'pong', 'id': 1});
      events.add(<String, dynamic>{'type': 'ack', 'id': 2, 'ok': true});
      await pumpEventQueue();
      expect(repo.current, same(BridgeState.empty));
    });

    test('replays the latest value to a late listener', () async {
      final repo = build();
      // An early listener so the broadcast has a subscriber, mirroring
      // real usage where a widget is already listening.
      repo.state.listen((_) {});

      events.add(_stateEvent(activeId: 'A', devices: [_device('A')]));
      await pumpEventQueue();

      // Subscribe AFTER the event: must still receive the latest state.
      final late = <BridgeState>[];
      repo.state.listen(late.add);
      await pumpEventQueue();

      expect(late, isNotEmpty);
      expect(late.first.activeDeviceId, 'A');
    });

    test('seeds a brand-new listener with empty then live updates', () async {
      final repo = build();
      final seen = <BridgeState>[];
      repo.state.listen(seen.add);
      await pumpEventQueue();
      expect(seen.first, same(BridgeState.empty));

      events.add(_stateEvent(activeId: 'A', devices: [_device('A')]));
      await pumpEventQueue();
      expect(seen.last.activeDeviceId, 'A');
    });
  });

  group('previewUri', () {
    test('per-device form uses /preview/<id>.mjpg', () {
      final repo = build();
      final uri = repo.previewUri(
        host: '10.0.0.5',
        port: 8766,
        token: 'abc123',
        deviceId: 'RMOW1234',
      );
      expect(uri.toString(),
          'http://10.0.0.5:8766/preview/RMOW1234.mjpg?t=abc123');
    });

    test('null deviceId is the follow-live active.mjpg stream', () {
      final repo = build();
      final uri = repo.previewUri(host: 'localhost', port: 8766, token: 'tok');
      expect(uri.toString(), 'http://localhost:8766/preview/active.mjpg?t=tok');
    });
  });

  group('device management', () {
    test('subscribe sends the bare subscribe frame', () async {
      when(() => api.send(any())).thenAnswer((_) async => <String, dynamic>{});
      final repo = build();
      await repo.subscribe();
      final sent = verify(() => api.send(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(sent, <String, dynamic>{'action': 'subscribe'});
    });

    test('setActiveDevice injects device_id', () async {
      when(() => api.send(any())).thenAnswer((_) async => <String, dynamic>{});
      final repo = build();
      await repo.setActiveDevice('RMOWLHHC233LOQ');
      final sent = verify(() => api.send(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(sent, <String, dynamic>{
        'action': 'device.set_active',
        'device_id': 'RMOWLHHC233LOQ',
      });
    });

    test(
        'renameDevice passes the name through verbatim - the bridge '
        'owns validation (trim + 60-char cap), one authority', () async {
      when(() => api.send(any())).thenAnswer((_) async => <String, dynamic>{});
      final repo = build();
      await repo.renameDevice('A', '  Vocal  ');
      final sent = verify(() => api.send(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(sent['action'], 'device.rename');
      expect(sent['device_id'], 'A');
      expect(sent['name'], '  Vocal  ');
    });
  });
}
