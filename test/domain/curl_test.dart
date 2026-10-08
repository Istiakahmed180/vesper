import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/api_client/domain/services/curl_generator.dart';
import 'package:vesper/features/api_client/domain/services/curl_parser.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';

void main() {
  const parser = CurlParser();

  group('CurlParser', () {
    test('parses the documented example', () {
      final r = parser.parse('''curl --request GET \\
  --url https://api.example.com/users \\
  --header 'Authorization: Bearer token' ''').request;
      expect(r.method, HttpMethod.get);
      expect(r.url, 'https://api.example.com/users');
      expect(r.auth, const BearerAuth(token: 'token'));
      expect(r.headers, isEmpty);
    });

    test('defaults to POST with data and detects JSON', () {
      final r = parser.parse(
        """curl https://x.dev/items -H "Content-Type: application/json" -d '{"a": 1}'""",
      ).request;
      expect(r.method, HttpMethod.post);
      expect(r.body.type, BodyType.json);
      expect(r.body.text, '{"a": 1}');
    });

    test('parses url-encoded data into fields', () {
      final r = parser
          .parse("curl -X PUT https://x.dev -d 'a=1&b=hello%20world'")
          .request;
      expect(r.method, HttpMethod.put);
      expect(r.body.type, BodyType.urlEncoded);
      expect(r.body.urlEncoded.map((e) => (e.key, e.value)), [
        ('a', '1'),
        ('b', 'hello world'),
      ]);
    });

    test('parses multipart form with files', () {
      final r = parser
          .parse(
            "curl https://x.dev/upload -F 'name=vesper' -F 'file=@/tmp/a.png;type=image/png'",
          )
          .request;
      expect(r.body.type, BodyType.formData);
      expect(r.body.formData[0].value, 'vesper');
      expect(r.body.formData[1].kind, FormFieldKind.file);
      expect(r.body.formData[1].filePath, '/tmp/a.png');
      expect(r.body.formData[1].contentType, 'image/png');
    });

    test('parses basic auth, combined flags and attached values', () {
      final r = parser
          .parse('curl -sSL -XDELETE -u user:pa:ss "https://x.dev/a?b=1"')
          .request;
      expect(r.method, HttpMethod.delete);
      expect(r.auth, const BasicAuth(username: 'user', password: 'pa:ss'));
      expect(r.options.followRedirects, isTrue);
      expect(r.params.single.key, 'b');
    });

    test('supports --get moving data to the query', () {
      final r = parser
          .parse("curl -G https://x.dev/search --data-urlencode 'q=a b'")
          .request;
      expect(r.method, HttpMethod.get);
      expect(r.url, 'https://x.dev/search?q=a+b');
      expect(r.body.type, BodyType.none);
    });

    test('handles Windows cmd line continuation', () {
      final r = parser
          .parse('curl ^\n  "https://x.dev" ^\n  -H "Accept: text/plain"')
          .request;
      expect(r.url, 'https://x.dev');
      expect(r.headers.single.value, 'text/plain');
    });

    test('ANSI-C quoted strings', () {
      final r = parser
          .parse(r"curl https://x.dev --data-raw $'line1\nline2'")
          .request;
      expect(r.body.text, 'line1\nline2');
    });

    test('throws useful errors', () {
      expect(() => parser.parse(''), throwsA(isA<CurlParseException>()));
      expect(
        () => parser.parse('wget https://x'),
        throwsA(isA<CurlParseException>()),
      );
      expect(
        () => parser.parse('curl -H "A: b"'),
        throwsA(isA<CurlParseException>()),
      );
      expect(
        () => parser.parse("curl 'https://x"),
        throwsA(isA<CurlParseException>()),
      );
      expect(() => parser.parse('curl -X'), throwsA(isA<CurlParseException>()));
    });

    test('reports unknown flags as warnings', () {
      final result = parser.parse('curl --frobnicate https://x.dev');
      expect(result.warnings, isNotEmpty);
      expect(result.request.url, 'https://x.dev');
    });
  });

  group('CurlGenerator', () {
    const preparer = RequestPreparer();
    const generator = CurlGenerator();

    String gen(ApiRequest r, [VariableResolver? resolver]) =>
        generator.generate(
          preparer.prepare(r, resolver ?? VariableResolver()),
          multiline: false,
        );

    test('GET with headers', () {
      final out = gen(
        ApiRequest(
          url: 'https://x.dev/a?b=1',
          params: [KeyValue(key: 'b', value: '1')],
          headers: [KeyValue(key: 'X-Test', value: "it's")],
        ),
      );
      expect(out, startsWith("curl --url 'https://x.dev/a?b=1' --location"));
      expect(out, contains(r"--header 'X-Test: it'\''s'"));
    });

    test('POST JSON with bearer auth resolves variables', () {
      final out = gen(
        ApiRequest(
          method: HttpMethod.post,
          url: '{{base}}/items',
          body: const RequestBody(type: BodyType.json, text: '{"a":1}'),
          auth: const BearerAuth(token: '{{token}}'),
        ),
        VariableResolver(
          environment: {
            'base': const VariableValue(
              'https://x.dev',
              VariableSource.environment,
            ),
            'token': const VariableValue('abc', VariableSource.environment),
          },
        ),
      );
      expect(out, contains('--request POST'));
      expect(out, contains("--header 'Authorization: Bearer abc'"));
      expect(out, contains("--header 'Content-Type: application/json'"));
      expect(out, contains(r"""--data-raw '{"a":1}'"""));
    });

    test('round trips through the parser', () {
      final original = ApiRequest(
        method: HttpMethod.patch,
        url: 'https://x.dev/users/1',
        headers: [KeyValue(key: 'X-Trace', value: 'abc def')],
        body: const RequestBody(
          type: BodyType.json,
          text: '{"name":"O\'Brien"}',
        ),
        auth: const BasicAuth(username: 'u', password: 'p'),
      );
      final command = generator.generate(
        preparer.prepare(original, VariableResolver()),
      );
      final parsed = parser.parse(command).request;
      expect(parsed.method, HttpMethod.patch);
      expect(parsed.url, original.url);
      expect(parsed.body.text, original.body.text);
      expect(parsed.auth, const BasicAuth(username: 'u', password: 'p'));
      expect(
        parsed.headers.any((h) => h.key == 'X-Trace' && h.value == 'abc def'),
        isTrue,
      );
    });

    test('multipart uses --form and omits content-type', () {
      final out = gen(
        ApiRequest(
          method: HttpMethod.post,
          url: 'https://x.dev/up',
          body: RequestBody(
            type: BodyType.formData,
            formData: [
              FormDataField(key: 'a', value: '@notafile'),
              FormDataField(
                key: 'f',
                kind: FormFieldKind.file,
                filePath: '/tmp/x.bin',
              ),
            ],
          ),
        ),
      );
      expect(out, contains('--form-string a=@notafile'));
      expect(out, contains('--form f=@/tmp/x.bin'));
      expect(out, isNot(contains('Content-Type')));
    });
  });
}
