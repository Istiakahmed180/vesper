import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/services/url_utils.dart';
import 'package:vesper/features/history/presentation/history_panel.dart';

void main() {
  group('UrlParts', () {
    test('splits base, query and fragment', () {
      final p = UrlParts.split('https://x.dev/a?b=1&c=2#frag');
      expect(p.base, 'https://x.dev/a');
      expect(p.query, 'b=1&c=2');
      expect(p.fragment, 'frag');
    });

    test('handles variables in URL', () {
      final p = UrlParts.split('{{base_url}}/users?id={{id}}');
      expect(p.base, '{{base_url}}/users');
      expect(p.query, 'id={{id}}');
    });
  });

  group('params <-> url sync', () {
    test('parses params from URL', () {
      final params = UrlUtils.paramsFromUrl('https://x.dev?a=1&b=&c', const []);
      expect(params.map((p) => (p.key, p.value)), [
        ('a', '1'),
        ('b', ''),
        ('c', ''),
      ]);
    });

    test('keeps disabled params and reuses ids', () {
      final prev = [
        KeyValue(id: 'p1', key: 'a', value: '1'),
        KeyValue(id: 'p2', key: 'off', value: 'x', enabled: false),
      ];
      final params = UrlUtils.paramsFromUrl('https://x.dev?a=2', prev);
      expect(params.first.id, 'p1');
      expect(params.first.value, '2');
      expect(params.any((p) => p.id == 'p2' && !p.enabled), isTrue);
    });

    test('rebuilds URL from enabled params', () {
      final url = UrlUtils.urlWithParams('https://x.dev/a?old=1#top', [
        KeyValue(key: 'q', value: 'hello world'),
        KeyValue(key: 'skip', value: '1', enabled: false),
        KeyValue(key: 'flag'),
      ]);
      expect(url, 'https://x.dev/a?q=hello world&flag#top');
    });
  });

  group('buildRequestUrl', () {
    test('encodes query values without double encoding', () {
      final url = UrlUtils.buildRequestUrl('https://x.dev/search', [
        ('q', 'a b&c'),
        ('pre', 'already%20encoded'),
      ]);
      expect(url, 'https://x.dev/search?q=a%20b%26c&pre=already%20encoded');
    });

    test('adds http scheme when missing', () {
      expect(
        UrlUtils.buildRequestUrl('localhost:8080/x', const []),
        'http://localhost:8080/x',
      );
    });

    test('encodes spaces and unicode in path', () {
      expect(
        UrlUtils.buildRequestUrl('https://x.dev/a b/ü', const []),
        'https://x.dev/a%20b/%C3%BC',
      );
    });
  });

  test('history display path keeps variables readable', () {
    expect(displayPath('{{base_url}}/users?id=1'), '/users');
    expect(displayPath('https://api.x.dev/v1/me'), '/v1/me');
    expect(displayPath('https://api.x.dev'), '');
  });
}
