import 'package:auth_repository/auth_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:test/test.dart';

class _MockApi extends Mock implements ObsbotApiClient {}

/// The exact developer-facing hint the bridge sends on `auth_required`
/// (ws_server.cpp). CLAUDE.md #41: this must never reach user copy. Tests
/// assert this string surfaces nowhere.
const _protocolHint =
    "send {action:'pair', pin:<6-digit>} or {action:'hello', token:<token>} first";

const _hostPort = '192.168.1.50:8765';
const _tokenKey = 'token::$_hostPort';

void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _MockApi api;
  late InMemoryAuthStorage storage;

  AuthRepository build() =>
      AuthRepository(api: api, storage: storage, hostPort: _hostPort);

  setUp(() {
    api = _MockApi();
    storage = InMemoryAuthStorage();
  });

  group('authenticate', () {
    test('reuses a saved token: hello carries it, status authenticated',
        () async {
      await storage.write(_tokenKey, 'deadbeef');
      when(() => api.send(any())).thenAnswer(
        (_) async => <String, dynamic>{'type': 'ack', 'ok': true},
      );
      final repo = build();

      await repo.authenticate();

      final frame = verify(() => api.send(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(frame['action'], 'hello');
      expect(frame['token'], 'deadbeef');
      expect(repo.current, AuthStatus.authenticated);
      expect(repo.token, 'deadbeef');
    });

    test('omits the token key entirely when none is saved', () async {
      when(() => api.send(any())).thenAnswer(
        (_) async => <String, dynamic>{'type': 'ack', 'ok': true},
      );
      final repo = build();

      await repo.authenticate();

      final frame = verify(() => api.send(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(frame['action'], 'hello');
      expect(frame.containsKey('token'), isFalse);
      expect(repo.current, AuthStatus.authenticated);
    });

    test('auth_required becomes unauthenticated, not an error, no msg leak',
        () async {
      when(() => api.send(any())).thenThrow(
        // The message carries the raw protocol hint on purpose.
        const ApiActionException('auth_required', _protocolHint),
      );
      final repo = build();
      final seen = <AuthStatus>[];
      repo.status.listen(seen.add);

      // Must not throw: entering the pair state is a transition.
      await repo.authenticate();

      expect(repo.current, AuthStatus.unauthenticated);
      // The enum has no payload, so there is structurally nowhere for the
      // hint to live. Assert it appears in no reachable surface anyway.
      expect(repo.token, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(AuthStatus.unauthenticated));
      for (final s in seen) {
        expect(s.toString(), isNot(contains('pair')));
        expect(s.toString(), isNot(contains(_protocolHint)));
      }
    });

    test('a non-auth action error propagates untouched', () async {
      when(() => api.send(any())).thenThrow(
        const ApiActionException('no_device', 'no camera attached'),
      );
      final repo = build();

      await expectLater(
        repo.authenticate(),
        throwsA(isA<ApiActionException>()
            .having((e) => e.code, 'code', 'no_device')),
      );
      expect(repo.current, AuthStatus.unknown);
    });

    test('a transport failure propagates untouched', () async {
      when(() => api.send(any()))
          .thenThrow(const ApiConnectionException('socket closed'));
      final repo = build();

      await expectLater(
        repo.authenticate(),
        throwsA(isA<ApiConnectionException>()),
      );
    });
  });

  group('pair', () {
    test('success saves the token under the per-host key + authenticates',
        () async {
      when(() => api.send(any())).thenAnswer(
        (_) async => <String, dynamic>{
          'type': 'ack',
          'ok': true,
          'token': 'a' * 64,
        },
      );
      final repo = build();

      await repo.pair('123456');

      expect(await storage.read(_tokenKey), 'a' * 64);
      // Nothing bled into a neighbouring bridge's slot.
      expect(await storage.read('token::10.0.0.9:8765'), isNull);
      expect(repo.token, 'a' * 64);
      expect(repo.current, AuthStatus.authenticated);

      final frame = verify(() => api.send(captureAny())).captured.single
          as Map<String, dynamic>;
      expect(frame['action'], 'pair');
      expect(frame['pin'], '123456');
    });

    test('wrong PIN throws PairException; the protocol hint is not exposed',
        () async {
      when(() => api.send(any())).thenThrow(
        const ApiActionException('auth_failed', 'wrong PIN $_protocolHint'),
      );
      final repo = build();

      await expectLater(
        repo.pair('000000'),
        throwsA(
          isA<PairException>()
              .having((e) => e.code, 'code', 'auth_failed')
              .having((e) => e.toString(), 'toString', isNot(contains('PIN')))
              .having(
                (e) => e.toString(),
                'toString',
                isNot(contains(_protocolHint)),
              ),
        ),
      );
      expect(repo.current, AuthStatus.unknown);
      expect(await storage.read(_tokenKey), isNull);
    });

    test('a transport failure is NOT wrapped in PairException', () async {
      when(() => api.send(any()))
          .thenThrow(const ApiTimeoutException('no ack'));
      final repo = build();

      await expectLater(
        repo.pair('123456'),
        throwsA(isA<ApiTimeoutException>()),
      );
    });

    test('ok:true without a token throws PairException(no_token)', () async {
      when(() => api.send(any())).thenAnswer(
        (_) async => <String, dynamic>{'type': 'ack', 'ok': true},
      );
      final repo = build();

      await expectLater(
        repo.pair('123456'),
        throwsA(isA<PairException>().having((e) => e.code, 'code', 'no_token')),
      );
    });
  });

  group('logOut', () {
    test('clears the stored token and drops to unauthenticated', () async {
      await storage.write(_tokenKey, 'deadbeef');
      final repo = build();

      await repo.logOut();

      expect(await storage.read(_tokenKey), isNull);
      expect(repo.token, isNull);
      expect(repo.current, AuthStatus.unauthenticated);
    });
  });

  group('status stream', () {
    test('replays the latest value to a late listener', () async {
      when(() => api.send(any())).thenAnswer(
        (_) async => <String, dynamic>{'type': 'ack', 'ok': true},
      );
      final repo = build();
      await repo.authenticate();

      // Subscribe AFTER authentication; must still see authenticated first.
      final first = await repo.status.first;
      expect(first, AuthStatus.authenticated);
    });

    test('two late listeners each get the cached value', () async {
      final repo = build();

      expect(await repo.status.first, AuthStatus.unknown);
      expect(await repo.status.first, AuthStatus.unknown);
    });
  });
}
