import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/features/api_client/data/cookie_store.dart';

void main() {
  var now = DateTime(2026, 1, 1, 12);
  late CookieStore store;
  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    store = CookieStore(clock: () => now);
  });

  test('host-only cookies match only the exact host', () {
    store.storeFromHeaders(Uri.parse('https://api.example.com/v1/login'), [
      'sid=1; Path=/',
    ]);
    expect(
      store.cookieHeaderFor(Uri.parse('https://api.example.com/x')),
      'sid=1',
    );
    expect(store.cookieHeaderFor(Uri.parse('https://example.com/x')), isNull);
    expect(
      store.cookieHeaderFor(Uri.parse('https://sub.api.example.com/x')),
      isNull,
    );
  });

  test('domain cookies match subdomains; unrelated domains are rejected', () {
    store.storeFromHeaders(Uri.parse('https://a.example.com/'), [
      'shared=1; Domain=.example.com; Path=/',
      'evil=1; Domain=other.com; Path=/',
    ]);
    expect(
      store.cookieHeaderFor(Uri.parse('https://b.example.com/')),
      'shared=1',
    );
    expect(store.all.length, 1);
  });

  test('path, secure and expiry rules', () {
    store.storeFromHeaders(Uri.parse('https://x.dev/'), [
      'p=1; Path=/admin',
      's=1; Path=/; Secure',
      'm=1; Path=/; Max-Age=60',
    ]);
    expect(
      store.cookieHeaderFor(Uri.parse('https://x.dev/admin/users')),
      contains('p=1'),
    );
    expect(
      store.cookieHeaderFor(Uri.parse('https://x.dev/administrator')),
      isNot(contains('p=1')),
    );
    expect(
      store.cookieHeaderFor(Uri.parse('http://x.dev/')),
      isNot(contains('s=1')),
    );
    now = now.add(const Duration(minutes: 2));
    expect(
      store.cookieHeaderFor(Uri.parse('https://x.dev/')),
      isNot(contains('m=1')),
    );
  });

  test('replaces cookies with the same name and ignores malformed values', () {
    final uri = Uri.parse('https://x.dev/');
    store.storeFromHeaders(uri, ['a=1; Path=/', 'garbage']);
    store.storeFromHeaders(uri, ['a=2; Path=/']);
    expect(store.cookieHeaderFor(uri), 'a=2');
    store.clear();
    expect(store.all, isEmpty);
  });
}
