import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/errors/app_failure.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/key_value.dart';
import 'package:vesper/features/api_client/domain/models/request_auth.dart';
import 'package:vesper/features/api_client/domain/models/request_body.dart';
import 'package:vesper/features/collections/domain/collection_repository.dart';
import 'package:vesper/features/environments/domain/environment_models.dart';
import 'package:vesper/features/import_export/domain/collection_codec.dart';
import 'package:vesper/features/import_export/domain/import_service.dart';

void main() {
  const service = ImportService();
  const codec = VesperCollectionCodec();

  final doc = CollectionDocument(
    name: 'API',
    description: 'Demo',
    items: [
      FolderItem('Auth', [
        RequestItem(
          ApiRequest(
            name: 'Login',
            method: HttpMethod.post,
            url: '{{base_url}}/login',
            headers: [KeyValue(key: 'X-Trace', value: '1')],
            body: const RequestBody(type: BodyType.json, text: '{"u":"a"}'),
            auth: const BearerAuth(token: 'secret-token'),
          ),
        ),
      ]),
      RequestItem(ApiRequest(name: 'Health', url: '{{base_url}}/health')),
    ],
  );

  group('Vesper format', () {
    test('round trips a collection without secrets by default', () {
      final json = codec.encode(doc);
      final text = jsonEncode(json);
      expect(text, isNot(contains('secret-token')));
      final parsed = service
          .parseCollection(jsonDecode(text) as Map<String, Object?>)
          .value;
      expect(parsed.name, 'API');
      final login =
          ((parsed.items.first as FolderItem).items.single as RequestItem)
              .request;
      expect(login.method, HttpMethod.post);
      expect(login.url, '{{base_url}}/login');
      expect(login.body.text, '{"u":"a"}');
      expect(login.auth, const BearerAuth());
    });

    test('includes secrets only when asked', () {
      final text = jsonEncode(codec.encode(doc, includeSecrets: true));
      expect(text, contains('secret-token'));
    });

    test('rejects newer versions and malformed files', () {
      expect(
        () => service.parseCollection({
          'format': 'vesper.collection',
          'version': 99,
          'collection': <String, Object?>{},
        }),
        throwsA(isA<ImportFailure>()),
      );
      expect(
        () => service.parseCollection({'hello': 'world'}),
        throwsA(isA<ImportFailure>()),
      );
      expect(ImportService.decode('not json'), throwsA(isA<ImportFailure>()));
      expect(ImportService.decode('[1,2]'), throwsA(isA<ImportFailure>()));
    });

    test('limits nesting depth', () {
      Map<String, Object?> nest(int depth) => depth == 0
          ? {'type': 'request', 'name': 'x', 'url': 'u'}
          : {
              'type': 'folder',
              'name': 'f',
              'items': [nest(depth - 1)],
            };
      final json = {
        'format': 'vesper.collection',
        'version': 1,
        'collection': {
          'name': 'deep',
          'items': [nest(40)],
        },
      };
      expect(
        () => service.parseCollection(json),
        throwsA(isA<ImportFailure>()),
      );
    });

    test('environment export masks secrets', () {
      final env = Environment(
        name: 'Dev',
        variables: [
          EnvVariable(key: 'base_url', value: 'https://dev'),
          EnvVariable(key: 'token', value: 'abc', isSecret: true),
        ],
      );
      final json = const VesperEnvironmentCodec().encode(env);
      expect(jsonEncode(json), isNot(contains('abc')));
      final parsed = service.parseEnvironment(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      );
      expect(parsed.value.variables.last.isSecret, isTrue);
      expect(parsed.warnings, isNotEmpty);
      expect(
        () => service.parseCollection(json),
        throwsA(isA<ImportFailure>()),
      );
    });
  });

  group('Postman v2.1 importer', () {
    final postman = {
      'info': {
        'name': 'Shop',
        'schema':
            'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
      },
      'event': [
        {
          'listen': 'prerequest',
          'script': {
            'exec': ['console.log(1)'],
          },
        },
      ],
      'item': [
        {
          'name': 'Users',
          'item': [
            {
              'name': 'Create user',
              'event': [
                {'listen': 'test'},
              ],
              'request': {
                'method': 'POST',
                'header': [
                  {
                    'key': 'Accept',
                    'value': 'application/json',
                    'disabled': true,
                  },
                ],
                'url': {
                  'raw': '{{host}}/users?active=true',
                  'host': ['{{host}}'],
                  'path': ['users'],
                },
                'body': {
                  'mode': 'raw',
                  'raw': '{"name":"a"}',
                  'options': {
                    'raw': {'language': 'json'},
                  },
                },
                'auth': {
                  'type': 'bearer',
                  'bearer': [
                    {'key': 'token', 'value': '{{token}}'},
                  ],
                },
              },
            },
          ],
        },
        {
          'name': 'Login',
          'request': {
            'method': 'POST',
            'url': 'https://shop.dev/login',
            'body': {
              'mode': 'urlencoded',
              'urlencoded': [
                {'key': 'user', 'value': 'bob'},
              ],
            },
            'auth': {
              'type': 'apikey',
              'apikey': [
                {'key': 'key', 'value': 'X-Key'},
                {'key': 'value', 'value': 'k'},
                {'key': 'in', 'value': 'query'},
              ],
            },
          },
        },
        {
          'name': 'Query',
          'request': {
            'method': 'POST',
            'url': 'https://shop.dev/graphql',
            'body': {
              'mode': 'graphql',
              'graphql': {'query': '{ me { id } }', 'variables': '{"a":1}'},
            },
          },
        },
      ],
    };

    test('maps folders, requests, bodies and auth', () {
      final result = service.parseCollection(postman);
      expect(result.source, 'Postman Collection v2');
      final doc = result.value;
      expect(doc.name, 'Shop');
      final create =
          ((doc.items[0] as FolderItem).items.single as RequestItem).request;
      expect(create.method, HttpMethod.post);
      expect(create.url, '{{host}}/users?active=true');
      expect(create.params.single.key, 'active');
      expect(create.headers.single.enabled, isFalse);
      expect(create.body.type, BodyType.json);
      expect(create.auth, const BearerAuth(token: '{{token}}'));

      final login = (doc.items[1] as RequestItem).request;
      expect(login.body.type, BodyType.urlEncoded);
      expect(
        login.auth,
        const ApiKeyAuth(
          key: 'X-Key',
          value: 'k',
          location: ApiKeyLocation.query,
        ),
      );

      final gql = (doc.items[2] as RequestItem).request;
      expect(gql.body.type, BodyType.json);
      expect(jsonDecode(gql.body.text), {
        'query': '{ me { id } }',
        'variables': {'a': 1},
      });
    });

    test('reports ignored scripts', () {
      final result = service.parseCollection(postman);
      expect(result.warnings.any((w) => w.contains('2 script(s)')), isTrue);
    });

    test('imports Postman environments', () {
      final env = service.parseEnvironment({
        'name': 'Prod',
        'values': [
          {'key': 'host', 'value': 'https://shop.dev', 'enabled': true},
          {'key': 'token', 'value': 'x', 'type': 'secret', 'enabled': true},
        ],
      }).value;
      expect(env.name, 'Prod');
      expect(env.variables.last.isSecret, isTrue);
    });
  });
}
