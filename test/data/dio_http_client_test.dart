import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/core/logging/app_logger.dart';
import 'package:vesper/core/network/cancel_handle.dart';
import 'package:vesper/features/api_client/data/cookie_store.dart';
import 'package:vesper/features/api_client/data/dio_http_client.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/api_response.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/api_client/domain/services/request_preparer.dart';
import 'package:vesper/features/api_client/domain/services/variable_resolver.dart';
import 'package:vesper/features/settings/domain/app_settings.dart';

import '../support/test_server.dart';

class _MemorySink implements LogSink {
  final lines = <String>[];
  @override
  void write(LogRecord record) => lines.add(record.format());
  @override
  Future<void> close() async {}
}

void main() {
  late TestServer server;
  late DioHttpClient client;
  late CookieStore cookies;
  late _MemorySink logs;
  const settings = NetworkSettings();
  const preparer = RequestPreparer();

  setUpAll(() async => server = await TestServer.start());
  tearDownAll(() async => server.close());

  setUp(() {
    logs = _MemorySink();
    cookies = CookieStore();
    client = DioHttpClient(
      logger: AppLogger(sinks: [logs]),
      cookies: cookies,
    );
  });
  tearDown(() => client.dispose());

  Future<ApiResponse> send(
    ApiRequest r, {
    CancelHandle? cancel,
    NetworkSettings s = settings,
  }) => client.send(
    preparer.prepare(r, VariableResolver()),
    settings: s,
    cancel: cancel,
  );

  Map<String, Object?> json(ApiResponse r) =>
      (jsonDecode(r.bodyText) as Map).cast<String, Object?>();

  for (final method in [
    HttpMethod.get,
    HttpMethod.post,
    HttpMethod.put,
    HttpMethod.patch,
    HttpMethod.delete,
    HttpMethod.options,
  ]) {
    test('sends ${method.value}', () async {
      final r = await send(
        ApiRequest(method: method, url: '${server.baseUrl}/echo'),
      );
      expect(r.statusCode, 200);
      expect(json(r)['method'], method.value);
      expect(r.duration, greaterThan(Duration.zero));
    });
  }

  test('HEAD returns headers without body', () async {
    final r = await send(
      ApiRequest(method: HttpMethod.head, url: '${server.baseUrl}/echo'),
    );
    expect(r.statusCode, 200);
    expect(r.bodyBytes, isEmpty);
    expect(r.contentType, contains('json'));
  });

  test('sends query params, headers and JSON body', () async {
    final r = await send(
      ApiRequest(
        method: HttpMethod.post,
        url: '${server.baseUrl}/echo?a=1&b=x y',
        params: [
          KeyValue(key: 'a', value: '1'),
          KeyValue(key: 'b', value: 'x y'),
        ],
        headers: [KeyValue(key: 'X-Custom', value: 'yes')],
        body: const RequestBody(type: BodyType.json, text: '{"hello":"world"}'),
      ),
    );
    final body = json(r);
    expect(body['query'], {'a': '1', 'b': 'x y'});
    expect((body['headers']! as Map)['x-custom'], 'yes');
    expect((body['headers']! as Map)['content-type'], 'application/json');
    expect(body['body'], '{"hello":"world"}');
  });

  test('url-encoded body', () async {
    final r = await send(
      ApiRequest(
        method: HttpMethod.post,
        url: '${server.baseUrl}/echo',
        body: RequestBody(
          type: BodyType.urlEncoded,
          urlEncoded: [KeyValue(key: 'a', value: '1 & 2')],
        ),
      ),
    );
    expect(json(r)['body'], 'a=1+%26+2');
  });

  test('multipart upload with a file', () async {
    final dir = await Directory.systemTemp.createTemp('vesper_test');
    final file = File('${dir.path}/hello.txt')
      ..writeAsStringSync('file-content');
    addTearDown(() => dir.delete(recursive: true));
    final r = await send(
      ApiRequest(
        method: HttpMethod.post,
        url: '${server.baseUrl}/upload',
        body: RequestBody(
          type: BodyType.formData,
          formData: [
            FormDataField(key: 'field', value: 'value'),
            FormDataField(
              key: 'file',
              kind: FormFieldKind.file,
              filePath: file.path,
            ),
          ],
        ),
      ),
    );
    final body = json(r);
    expect(body['contentType'], 'multipart/form-data');
    expect(body['raw'], contains('file-content'));
    expect(body['raw'], contains('filename="hello.txt"'));
    expect(body['raw'], contains('value'));
  });

  test('binary file body', () async {
    final dir = await Directory.systemTemp.createTemp('vesper_test');
    final file = File('${dir.path}/blob.bin')
      ..writeAsBytesSync(List.generate(1000, (i) => i % 256));
    addTearDown(() => dir.delete(recursive: true));
    final r = await send(
      ApiRequest(
        method: HttpMethod.post,
        url: '${server.baseUrl}/upload',
        body: RequestBody(type: BodyType.binary, binaryFilePath: file.path),
      ),
    );
    expect(json(r)['length'], 1000);
  });

  test('missing upload file gives a readable error', () async {
    await expectLater(
      send(
        ApiRequest(
          method: HttpMethod.post,
          url: '${server.baseUrl}/upload',
          body: const RequestBody(
            type: BodyType.binary,
            binaryFilePath: '/definitely/not/here.bin',
          ),
        ),
      ),
      throwsA(
        isA<NetworkFailure>().having(
          (f) => f.kind,
          'kind',
          NetworkFailureKind.fileNotFound,
        ),
      ),
    );
  });

  test('reports HTTP error statuses as responses, not failures', () async {
    final r = await send(
      ApiRequest(url: '${server.baseUrl}/status?code=503&reason=Unavailable'),
    );
    expect(r.statusCode, 503);
    expect(r.statusMessage, 'Unavailable');
  });

  test('handles a 10 MB response', () async {
    final r = await send(
      ApiRequest(url: '${server.baseUrl}/large?bytes=${10 * 1024 * 1024}'),
    );
    expect(r.bodySize, 10 * 1024 * 1024);
  });

  test('detects binary responses', () async {
    final r = await send(ApiRequest(url: '${server.baseUrl}/binary'));
    expect(r.contentKind, ResponseContentKind.image);
    expect(r.bodySize, 12);
  });

  test('follows redirects when enabled and records them', () async {
    final r = await send(ApiRequest(url: '${server.baseUrl}/redirect'));
    expect(r.statusCode, 200);
    expect(r.redirects, isNotEmpty);
    final noFollow = await send(
      ApiRequest(
        url: '${server.baseUrl}/redirect',
        options: const RequestOptions(followRedirects: false),
      ),
    );
    expect(noFollow.statusCode, 302);
  });

  test('stores cookies and sends them on later requests', () async {
    final r = await send(ApiRequest(url: '${server.baseUrl}/cookie'));
    expect(r.cookies.single.name, 'session');
    final echo = await send(ApiRequest(url: '${server.baseUrl}/echo'));
    expect((json(echo)['headers']! as Map)['cookie'], 'session=abc123');
  });

  test('cancellation', () async {
    final cancel = CancelHandle();
    final future = send(
      ApiRequest(url: '${server.baseUrl}/slow?ms=3000'),
      cancel: cancel,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancel.cancel();
    await expectLater(
      future,
      throwsA(
        isA<NetworkFailure>().having(
          (f) => f.kind,
          'kind',
          NetworkFailureKind.cancelled,
        ),
      ),
    );
  });

  test('timeout with readable message', () async {
    await expectLater(
      send(
        ApiRequest(
          url: '${server.baseUrl}/slow?ms=3000',
          options: const RequestOptions(timeoutMs: 300),
        ),
      ),
      throwsA(
        isA<NetworkFailure>()
            .having((f) => f.kind, 'kind', NetworkFailureKind.receiveTimeout)
            .having(
              (f) => f.message,
              'message',
              'Request timed out after 0.3 seconds.',
            ),
      ),
    );
  });

  test('connection refused', () async {
    final port = await unusedPort();
    await expectLater(
      send(ApiRequest(url: 'http://127.0.0.1:$port/')),
      throwsA(
        isA<NetworkFailure>().having(
          (f) => f.kind,
          'kind',
          NetworkFailureKind.connectionRefused,
        ),
      ),
    );
  });

  test('DNS failure', () async {
    await expectLater(
      send(ApiRequest(url: 'http://nonexistent.invalid/')),
      throwsA(
        isA<NetworkFailure>().having(
          (f) => f.kind,
          'kind',
          NetworkFailureKind.dnsFailure,
        ),
      ),
    );
  });

  test('never logs secrets or query values', () async {
    await send(
      ApiRequest(
        url: '${server.baseUrl}/echo?api_key=supersecret',
        params: [KeyValue(key: 'api_key', value: 'supersecret')],
        headers: [KeyValue(key: 'Authorization', value: 'Bearer supersecret')],
      ),
    );
    expect(logs.lines.join('\n'), isNot(contains('supersecret')));
  });
}
