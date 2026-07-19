import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/connection_link.dart';

void main() {
  group('parseConnectionLink', () {
    test('full bridge link with pair fragment', () {
      final r = parseConnectionLink('http://192.168.68.55:8765/#pair?pin=123456');
      expect(r?.hostPort, '192.168.68.55:8765');
      expect(r?.pin, '123456');
    });

    test('link without fragment has no pin', () {
      final r = parseConnectionLink('http://192.168.68.55:8765/');
      expect(r?.hostPort, '192.168.68.55:8765');
      expect(r?.pin, isNull);
    });

    test('link without explicit port defaults to 8765', () {
      final r = parseConnectionLink('http://mini.local/#pair?pin=004312');
      expect(r?.hostPort, 'mini.local:8765');
      expect(r?.pin, '004312');
    });

    test('hand-typed host:port passes through', () {
      final r = parseConnectionLink('192.168.0.10:9000');
      expect(r?.hostPort, '192.168.0.10:9000');
      expect(r?.pin, isNull);
    });

    test('bare host gains the default port', () {
      expect(parseConnectionLink('mini.local')?.hostPort, 'mini.local:8765');
    });

    test('garbage is rejected', () {
      expect(parseConnectionLink(''), isNull);
      expect(parseConnectionLink('not a link at all'), isNull);
      expect(parseConnectionLink('host:notaport'), isNull);
    });
  });
}
