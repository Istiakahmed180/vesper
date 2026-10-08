import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/redactor.dart';

void main() {
  test('safeUrl strips credentials, query and fragment', () {
    expect(
      Redactor.safeUrl('https://u:p@api.x.dev:8443/a/b?token=1#f'),
      'https://api.x.dev:8443/a/b?…',
    );
    expect(
      Redactor.safeUrl('http://127.0.0.1:8080/echo'),
      'http://127.0.0.1:8080/echo',
    );
    expect(Redactor.safeUrl('{{base}}/x?key=1'), '{{base}}/x?…');
  });

  test('scrub masks tokens in free text', () {
    final out = Redactor.scrub(
      'Authorization: Bearer abc.def password=hunter2 ghp_${'a' * 30}',
    );
    expect(out, isNot(contains('abc.def')));
    expect(out, isNot(contains('hunter2')));
    expect(out, isNot(contains('a' * 30)));
  });

  test('sensitive header detection', () {
    expect(Redactor.isSensitiveHeader('Authorization'), isTrue);
    expect(Redactor.isSensitiveHeader('X-Api-Key'), isTrue);
    expect(Redactor.isSensitiveHeader('Content-Type'), isFalse);
  });
}
