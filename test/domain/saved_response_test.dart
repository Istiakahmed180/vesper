import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/security/redactor.dart';
import 'package:vesper/features/api_client/domain/models/api_request.dart';
import 'package:vesper/features/api_client/domain/models/api_response.dart';
import 'package:vesper/features/api_client/domain/models/http_method.dart';
import 'package:vesper/features/api_client/domain/models/saved_response.dart';
import 'package:vesper/features/collections/domain/collection_repository.dart';
import 'package:vesper/features/history/domain/history_models.dart';
import 'package:vesper/features/import_export/domain/collection_codec.dart';
import 'package:vesper/features/import_export/domain/postman_importer.dart';

ApiResponse _response({
  int status = 200,
  String message = 'OK',
  String body = '{"status":true}',
  String contentType = 'application/json',
  List<MapEntry<String, String>> headers = const [],
}) => ApiResponse(
  statusCode: status,
  statusMessage: message,
  headers: [MapEntry('content-type', contentType), ...headers],
  bodyBytes: Uint8List.fromList(utf8.encode(body)),
  duration: const Duration(milliseconds: 12),
  requestUrl: 'https://api.test/cards',
  method: HttpMethod.post,
);

void main() {
  group('SavedResponse', () {
    test('isSuccess is true only for 2xx', () {
      expect(SavedResponse(name: 'a', statusCode: 200).isSuccess, isTrue);
      expect(SavedResponse(name: 'a', statusCode: 299).isSuccess, isTrue);
      expect(SavedResponse(name: 'a', statusCode: 422).isSuccess, isFalse);
      expect(SavedResponse(name: 'a', statusCode: 500).isSuccess, isFalse);
    });

    test('fromApiResponse keeps status and body, default name from status', () {
      final e = SavedResponse.fromApiResponse(
        _response(
          status: 422,
          message: 'Unprocessable Entity',
          body: '{"a":1}',
        ),
      );
      expect(e.name, '422 Unprocessable Entity');
      expect(e.statusCode, 422);
      expect(e.body, '{"a":1}');
      expect(e.isSuccess, isFalse);
    });

    test('fromApiResponse uses the trimmed given name', () {
      final e = SavedResponse.fromApiResponse(_response(), name: '  Happy  ');
      expect(e.name, 'Happy');
    });

    test('masks sensitive headers', () {
      final e = SavedResponse.fromApiResponse(
        _response(
          headers: const [
            MapEntry('set-cookie', 'session=secret'),
            MapEntry('x-request-id', 'abc'),
          ],
        ),
      );
      final map = Map.fromEntries(e.headers);
      expect(map['set-cookie'], Redactor.mask);
      expect(map['x-request-id'], 'abc');
    });

    test('cuts bodies over the cap', () {
      final big = 'x' * (SavedResponse.maxBodyChars + 10);
      final e = SavedResponse.fromApiResponse(_response(body: big));
      expect(e.body.length, SavedResponse.maxBodyChars);
      expect(e.isTruncated, isTrue);
    });

    test('canSave refuses binary and image responses', () {
      expect(SavedResponse.canSave(_response()), isTrue);
      expect(
        SavedResponse.canSave(_response(contentType: 'image/png')),
        isFalse,
      );
      expect(
        SavedResponse.canSave(_response(contentType: 'application/pdf')),
        isFalse,
      );
    });

    test('toApiResponse renders like a live response', () {
      final e = SavedResponse(
        name: 'Err',
        statusCode: 403,
        statusMessage: 'Forbidden',
        headers: const [MapEntry('content-type', 'application/json')],
        body: '{"status":false}',
      );
      final r = e.toApiResponse(requestUrl: 'https://x.test');
      expect(r.statusCode, 403);
      expect(r.bodyText, '{"status":false}');
      expect(r.contentKind, ResponseContentKind.json);
    });

    test('json round trip, with and without ids', () {
      final e = SavedResponse(
        name: 'Ok',
        statusCode: 200,
        statusMessage: 'OK',
        headers: const [MapEntry('x-a', 'b')],
        body: 'hi',
      );
      final same = SavedResponse.fromJson(e.toJson());
      expect(same.id, e.id);
      expect(same.name, 'Ok');
      expect(same.headers.single, const MapEntry('x-a', 'b'));
      expect(same.body, 'hi');
      expect(SavedResponse.fromJson(e.toJson(), keepId: false).id, isNot(e.id));
    });

    test('fromJson tolerates missing and wrong-typed fields', () {
      final e = SavedResponse.fromJson({'status': '404', 'headers': 'nope'});
      expect(e.statusCode, 404);
      expect(e.name, 'Example');
      expect(e.headers, isEmpty);
      expect(e.body, '');
    });
  });

  group('ApiRequest examples', () {
    final example = SavedResponse(name: 'Ok', statusCode: 200, body: '{}');

    test('are ignored by sameContentAs', () {
      final a = ApiRequest(name: 'r');
      expect(a.sameContentAs(a.copyWith(examples: [example])), isTrue);
    });

    test('round trip through toJson and fromJson', () {
      final r = ApiRequest(name: 'r', examples: [example]);
      final back = ApiRequest.fromJson(r.toJson());
      expect(back.examples.single.name, 'Ok');
      expect(back.examples.single.id, example.id);
    });

    test('toJson omits an empty examples list', () {
      expect(ApiRequest(name: 'r').toJson().containsKey('examples'), isFalse);
    });

    test('history sanitizer drops examples', () {
      final r = ApiRequest(name: 'r', examples: [example]);
      expect(const HistorySanitizer().sanitize(r).examples, isEmpty);
    });
  });

  group('Postman import of saved responses', () {
    Map<String, Object?> collection(List<Object?> responses) => {
      'info': {
        'name': 'Cards',
        'schema':
            'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
      },
      'item': [
        {
          'name': 'Top Up',
          'request': {'method': 'POST', 'url': 'https://api.test/topup'},
          'response': responses,
        },
        {
          'name': 'No examples',
          'request': {'method': 'GET', 'url': 'https://api.test/x'},
        },
      ],
    };

    List<SavedResponse> examplesOf(Map<String, Object?> json, int index) {
      final doc = const PostmanCollectionImporter().parse(json).value;
      return (doc.items[index] as RequestItem).request.examples;
    }

    test('maps success and error examples in order', () {
      final examples = examplesOf(
        collection([
          {
            'name': 'Success',
            'status': 'OK',
            'code': 200,
            'header': [
              {'key': 'Content-Type', 'value': 'application/json'},
            ],
            'body': '{"status":true}',
          },
          {
            'name': 'Invalid amount',
            'status': 'Unprocessable Entity',
            'code': 422,
            'body': '{"status":false}',
          },
          {'name': 'KYC Gate', 'status': 'Forbidden', 'code': 403, 'body': ''},
        ]),
        0,
      );
      expect(examples.map((e) => e.name), [
        'Success',
        'Invalid amount',
        'KYC Gate',
      ]);
      expect(examples.map((e) => e.statusCode), [200, 422, 403]);
      expect(examples.map((e) => e.isSuccess), [true, false, false]);
      expect(examples[0].statusMessage, 'OK');
      expect(examples[0].headers.single.key, 'content-type');
      expect(examples[1].body, '{"status":false}');
    });

    test('requests without response get no examples', () {
      expect(examplesOf(collection([]), 1), isEmpty);
    });

    test('caps examples per request', () {
      final many = [
        for (var i = 0; i < 80; i++)
          {'name': 'e$i', 'code': 200, 'status': 'OK', 'body': ''},
      ];
      expect(examplesOf(collection(many), 0).length, 50);
    });

    test('cuts oversized bodies', () {
      final examples = examplesOf(
        collection([
          {
            'name': 'big',
            'code': 200,
            'body': 'x' * (SavedResponse.maxBodyChars + 5),
          },
        ]),
        0,
      );
      expect(examples.single.body.length, SavedResponse.maxBodyChars);
    });
  });

  group('Vesper codec', () {
    const codec = VesperCollectionCodec();

    test('round trips examples', () {
      final doc = CollectionDocument(
        name: 'API',
        items: [
          RequestItem(
            ApiRequest(
              name: 'Top Up',
              examples: [
                SavedResponse(name: 'Ok', statusCode: 200, body: '{}'),
                SavedResponse(name: 'Bad', statusCode: 422, body: '{"x":1}'),
              ],
            ),
          ),
        ],
      );
      final json =
          jsonDecode(jsonEncode(codec.encode(doc))) as Map<String, Object?>;
      final back = codec.parse(json).value;
      final examples = (back.items.single as RequestItem).request.examples;
      expect(examples.map((e) => e.statusCode), [200, 422]);
      expect(examples[1].body, '{"x":1}');
    });

    test('imports files written before examples existed', () {
      final json = {
        'format': VesperFormat.collectionFormat,
        'version': 1,
        'collection': {
          'name': 'Old',
          'items': [
            {'type': 'request', 'name': 'r', 'method': 'GET', 'url': 'x'},
          ],
        },
      };
      final back = codec.parse(json).value;
      expect((back.items.single as RequestItem).request.examples, isEmpty);
    });
  });
}
