import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/prepared_request.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/api_client/domain/services/code_snippet_generator.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';

PreparedRequest prepare(ApiRequest r, {RequestAuth? inherited}) =>
    const RequestPreparer().prepare(
      r,
      VariableResolver(
        environment: {
          'base': const VariableValue(
            'https://api.example.com',
            VariableSource.environment,
          ),
        },
      ),
      inheritedAuth: inherited,
    );

final samples = <String, PreparedRequest>{
  'get': prepare(
    ApiRequest(
      url: '{{base}}/users?page=1&q=it\'s "x"',
      headers: [KeyValue(key: 'X-Trace', value: r'a$b\c')],
      auth: const InheritAuth(),
    ),
    inherited: const BearerAuth(token: 'tok'),
  ),
  'json': prepare(
    ApiRequest(
      method: HttpMethod.post,
      url: '{{base}}/users',
      body: const RequestBody(
        type: BodyType.json,
        text: '{\n  "name": "O\'Brien",\n  "tags": ["a", "b"]\n}',
      ),
    ),
  ),
  'form': prepare(
    ApiRequest(
      method: HttpMethod.post,
      url: '{{base}}/login',
      body: RequestBody(
        type: BodyType.urlEncoded,
        urlEncoded: [
          KeyValue(key: 'user', value: 'me'),
          KeyValue(key: 'pass', value: 'p&ss word'),
        ],
      ),
    ),
  ),
  'multipart': prepare(
    ApiRequest(
      method: HttpMethod.post,
      url: '{{base}}/upload',
      body: RequestBody(
        type: BodyType.formData,
        formData: [
          FormDataField(key: 'title', value: 'Report'),
          FormDataField(
            key: 'file',
            kind: FormFieldKind.file,
            filePath: '/tmp/report.pdf',
            contentType: 'application/pdf',
          ),
        ],
      ),
    ),
  ),
  'binary': prepare(
    ApiRequest(
      method: HttpMethod.put,
      url: '{{base}}/blob',
      options: const RequestOptions(followRedirects: false),
      body: const RequestBody(
        type: BodyType.binary,
        binaryFilePath: '/tmp/data.bin',
      ),
    ),
  ),
};

void main() {
  const generator = CodeSnippetGenerator();

  test('every language renders every body kind', () {
    for (final language in SnippetLanguage.values) {
      for (final MapEntry(:key, :value) in samples.entries) {
        final code = generator.generate(value, language);
        expect(code, isNotEmpty, reason: '$language $key');
        expect(
          code,
          contains('api.example.com'),
          reason: 'variables are resolved ($language $key)',
        );
        expect(code, isNot(contains('Vesper/')), reason: 'no default UA');
      }
    }
  });

  test('inherited auth and headers are included', () {
    final python = generator.generate(
      samples['get']!,
      SnippetLanguage.pythonRequests,
    );
    expect(python, contains('"Authorization": "Bearer tok"'));
    expect(python, contains(r'"X-Trace": "a$b\\c"'));
    final dart = generator.generate(samples['get']!, SnippetLanguage.dartHttp);
    expect(dart, contains(r"'a\$b\\c'"), reason: r'Dart escapes $ and \');
  });

  test('multipart omits the content type so libraries add the boundary', () {
    final js = generator.generate(
      samples['multipart']!,
      SnippetLanguage.javascriptFetch,
    );
    expect(js, contains('new FormData()'));
    expect(js.toLowerCase(), isNot(contains('multipart/form-data')));
  });

  // Writes the snippets for syntax checks with real toolchains:
  //   flutter test test/domain/code_snippet_test.dart --dart-define=SNIPPET_DIR=/tmp/x
  test('export snippets', () {
    const dir = String.fromEnvironment('SNIPPET_DIR');
    if (dir.isEmpty) return;
    const ext = {
      SnippetLanguage.curl: 'sh',
      SnippetLanguage.http: 'http',
      SnippetLanguage.javascriptFetch: 'mjs',
      SnippetLanguage.nodeAxios: 'cjs',
      SnippetLanguage.pythonRequests: 'py',
      SnippetLanguage.dartHttp: 'dart',
      SnippetLanguage.dartDio: 'dart',
      SnippetLanguage.goNative: 'go',
      SnippetLanguage.phpCurl: 'php',
      SnippetLanguage.swiftUrlSession: 'swift',
      SnippetLanguage.javaOkHttp: 'java.txt',
      SnippetLanguage.csharpHttpClient: 'cs',
      SnippetLanguage.powershell: 'ps1',
    };
    for (final language in SnippetLanguage.values) {
      for (final MapEntry(:key, :value) in samples.entries) {
        File('$dir/${language.name}_$key.${ext[language]}')
          ..createSync(recursive: true)
          ..writeAsStringSync(generator.generate(value, language));
      }
    }
  });
}
