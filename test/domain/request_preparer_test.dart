import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/prepared_request.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';

void main() {
  const preparer = RequestPreparer();
  final resolver = VariableResolver(
    environment: {
      'base_url': const VariableValue(
        'https://api.example.com',
        VariableSource.environment,
      ),
      'token': const VariableValue(
        's3cret',
        VariableSource.environment,
        isSecret: true,
      ),
      'user': const VariableValue('alice', VariableSource.environment),
    },
  );

  String? header(PreparedRequest p, String name) => p.headers
      .where((h) => h.key.toLowerCase() == name.toLowerCase())
      .firstOrNull
      ?.value;

  test('resolves URL, params and headers', () {
    final p = preparer.prepare(
      ApiRequest(
        url: '{{base_url}}/users?name={{user}}',
        params: [
          KeyValue(key: 'name', value: '{{user}}'),
          KeyValue(key: 'x', value: '1', enabled: false),
        ],
        headers: [
          KeyValue(key: 'X-User', value: '{{user}}'),
          KeyValue(key: 'X-Off', value: '1', enabled: false),
        ],
      ),
      resolver,
    );
    expect(p.url, 'https://api.example.com/users?name=alice');
    expect(header(p, 'X-User'), 'alice');
    expect(header(p, 'X-Off'), isNull);
    expect(header(p, 'User-Agent'), startsWith('Vesper/'));
  });

  test('applies bearer, basic and api key auth', () {
    final bearer = preparer.prepare(
      ApiRequest(
        url: 'https://x.dev',
        auth: const BearerAuth(token: '{{token}}'),
      ),
      resolver,
    );
    expect(header(bearer, 'Authorization'), 'Bearer s3cret');

    final basic = preparer.prepare(
      ApiRequest(
        url: 'https://x.dev',
        auth: const BasicAuth(username: '{{user}}', password: 'pw'),
      ),
      resolver,
    );
    expect(
      header(basic, 'Authorization'),
      'Basic ${base64.encode(utf8.encode('alice:pw'))}',
    );

    final keyHeader = preparer.prepare(
      ApiRequest(
        url: 'https://x.dev',
        auth: const ApiKeyAuth(key: 'X-Api-Key', value: 'k'),
      ),
      resolver,
    );
    expect(header(keyHeader, 'X-Api-Key'), 'k');

    final keyQuery = preparer.prepare(
      ApiRequest(
        url: 'https://x.dev/a',
        auth: const ApiKeyAuth(
          key: 'api_key',
          value: 'k v',
          location: ApiKeyLocation.query,
        ),
      ),
      resolver,
    );
    expect(keyQuery.url, 'https://x.dev/a?api_key=k%20v');
  });

  test('auth header overrides a manual Authorization header', () {
    final p = preparer.prepare(
      ApiRequest(
        url: 'https://x.dev',
        headers: [KeyValue(key: 'authorization', value: 'old')],
        auth: const BearerAuth(token: 'new'),
      ),
      resolver,
    );
    expect(
      p.headers.where((h) => h.key.toLowerCase() == 'authorization').length,
      1,
    );
    expect(header(p, 'Authorization'), 'Bearer new');
  });

  test('sets implied content type unless user provided one', () {
    final json = preparer.prepare(
      ApiRequest(
        method: HttpMethod.post,
        url: 'https://x.dev',
        body: const RequestBody(type: BodyType.json, text: '{"t":"{{token}}"}'),
      ),
      resolver,
    );
    expect(header(json, 'Content-Type'), 'application/json');
    expect((json.body as TextBody).text, '{"t":"s3cret"}');

    final custom = preparer.prepare(
      ApiRequest(
        method: HttpMethod.post,
        url: 'https://x.dev',
        headers: [
          KeyValue(key: 'Content-Type', value: 'application/vnd.api+json'),
        ],
        body: const RequestBody(type: BodyType.json, text: '{}'),
      ),
      resolver,
    );
    expect(header(custom, 'Content-Type'), 'application/vnd.api+json');
  });

  test('builds url-encoded and multipart bodies', () {
    final form = preparer.prepare(
      ApiRequest(
        method: HttpMethod.post,
        url: 'https://x.dev',
        body: RequestBody(
          type: BodyType.urlEncoded,
          urlEncoded: [
            KeyValue(key: 'a', value: '1 2'),
            KeyValue(key: 'b', value: '{{user}}'),
          ],
        ),
      ),
      resolver,
    );
    expect((form.body as UrlEncodedBody).encode(), 'a=1+2&b=alice');

    final multipart = preparer.prepare(
      ApiRequest(
        method: HttpMethod.post,
        url: 'https://x.dev',
        body: RequestBody(
          type: BodyType.formData,
          formData: [
            FormDataField(key: 'name', value: '{{user}}'),
            FormDataField(
              key: 'file',
              kind: FormFieldKind.file,
              filePath: '/tmp/a',
            ),
          ],
        ),
      ),
      resolver,
    );
    final parts = (multipart.body as MultipartBody).parts;
    expect((parts[0] as MultipartTextPart).value, 'alice');
    expect((parts[1] as MultipartFilePart).path, '/tmp/a');
    expect(header(multipart, 'Content-Type'), isNull);
  });

  test('validates URLs with readable messages', () {
    expect(
      () => preparer.prepare(ApiRequest(url: ''), resolver),
      throwsA(
        isA<NetworkFailure>().having(
          (f) => f.kind,
          'kind',
          NetworkFailureKind.invalidUrl,
        ),
      ),
    );
    expect(
      () => preparer.prepare(ApiRequest(url: '{{missing}}/x'), resolver),
      throwsA(
        isA<NetworkFailure>().having(
          (f) => f.message,
          'message',
          contains('{{missing}}'),
        ),
      ),
    );
    expect(
      () => preparer.prepare(ApiRequest(url: 'ftp://x.dev'), resolver),
      throwsA(isA<NetworkFailure>()),
    );
  });

  test('uses request option overrides', () {
    final p = preparer.prepare(
      ApiRequest(
        url: 'x.dev',
        options: const RequestOptions(timeoutMs: 1500, followRedirects: false),
      ),
      resolver,
    );
    expect(p.url, 'http://x.dev');
    expect(p.timeout, const Duration(milliseconds: 1500));
    expect(p.followRedirects, isFalse);
  });
}
