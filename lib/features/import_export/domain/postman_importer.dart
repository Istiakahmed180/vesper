import 'dart:convert';

import '../../../core/utils/json_read.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/http_method.dart';
import '../../api_client/domain/models/key_value.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/domain/models/request_body.dart';
import '../../api_client/domain/services/url_utils.dart';
import '../../collections/domain/collection_models.dart';
import '../../collections/domain/collection_repository.dart';
import '../../environments/domain/environment_models.dart';
import 'collection_codec.dart';

/// Imports the publicly documented Postman Collection Format v2.0 / v2.1.
/// Pre-request and test scripts are never executed; they are dropped and
/// reported as warnings.
class PostmanCollectionImporter implements CollectionImporter {
  const PostmanCollectionImporter();

  @override
  String get name => 'Postman Collection v2';

  @override
  bool canImport(JsonMap json) {
    final schema = json.obj('info').str('schema');
    return schema.contains('collection/v2') ||
        (json['info'] is Map && json['item'] is List);
  }

  @override
  ImportResult<CollectionDocument> parse(
    JsonMap json, {
    ImportLimits limits = const ImportLimits(),
  }) {
    final counter = ImportCounter(limits);
    final warnings = <String>[];
    var scripts = 0;
    final info = json.obj('info');
    scripts += json.list('event').length;

    // Vesper has no folder-level auth, so a folder's auth is copied onto the
    // requests below it that inherit; [folderAuth] is null when they inherit
    // from the collection.
    List<CollectionItem> items(
      List<JsonMap> raw,
      int depth,
      RequestAuth? folderAuth,
    ) {
      final out = <CollectionItem>[];
      for (final item in raw) {
        counter.item(depth);
        scripts += item.list('event').length;
        final name = counter.text(item['name'], fallback: 'Untitled');
        if (item['item'] is List) {
          final own = item['auth'] is Map
              ? _auth(item.obj('auth'), warnings)
              : null;
          out.add(
            FolderItem(
              name,
              items(item.objList('item'), depth + 1, own ?? folderAuth),
            ),
          );
        } else if (item['request'] != null) {
          final request = _request(item, name, counter, warnings);
          out.add(
            RequestItem(
              request.auth is InheritAuth && folderAuth != null
                  ? request.copyWith(auth: folderAuth)
                  : request,
            ),
          );
        }
      }
      return out;
    }

    final docItems = items(json.objList('item'), 1, null);
    if (scripts > 0) {
      warnings.add(
        '$scripts script(s) were ignored; Vesper never runs imported scripts.',
      );
    }
    final collectionAuth = json['auth'] is Map
        ? _auth(json.obj('auth'), warnings)
        : null;
    final variables = [
      for (final v in json.objList('variable'))
        EnvVariable(
          key: counter.text(v['key']),
          value: counter.text(v['value']),
          enabled: !v.boolean('disabled'),
          isSecret: v.str('type') == 'secret',
        ),
    ];

    return ImportResult(
      CollectionDocument(
        name: counter.text(info['name'], fallback: 'Imported collection'),
        description: _description(info['description']),
        items: docItems,
        settings: CollectionSettings(
          auth: collectionAuth ?? const NoAuth(),
          variables: variables,
        ),
      ),
      warnings: warnings,
      source: name,
    );
  }

  ApiRequest _request(
    JsonMap item,
    String name,
    ImportCounter counter,
    List<String> warnings,
  ) {
    final raw = item['request'];
    if (raw is String) {
      return ApiRequest(
        name: name,
        url: raw,
        params: UrlUtils.paramsFromUrl(raw, const []),
      );
    }
    final req = (raw! as Map).cast<String, Object?>();
    final url = _url(req['url'], counter);
    final headers = [
      for (final h in req.objList('header'))
        KeyValue(
          key: counter.text(h['key']),
          value: counter.text(h['value']),
          enabled: !h.boolean('disabled'),
          description: _description(h['description']),
        ),
    ];
    return ApiRequest(
      name: name,
      method: HttpMethod.parse(req.str('method', 'GET')),
      url: url,
      params: UrlUtils.paramsFromUrl(url, const []),
      headers: headers,
      body: _body(req.objOrNull('body'), counter, warnings),
      // Postman requests without an auth block inherit from their parent.
      auth: req['auth'] is Map
          ? _auth(req.obj('auth'), warnings) ?? const InheritAuth()
          : const InheritAuth(),
      description: _description(req['description']),
    );
  }

  String _url(Object? url, ImportCounter counter) {
    if (url is String) return counter.text(url);
    if (url is Map) {
      final m = url.cast<String, Object?>();
      final raw = m.str('raw');
      if (raw.isNotEmpty) return counter.text(raw);
      final protocol = m.str('protocol');
      final host = m['host'] is List ? m.list('host').join('.') : m.str('host');
      final path = m['path'] is List ? m.list('path').join('/') : m.str('path');
      final query = m
          .objList('query')
          .map((q) => '${q.str('key')}=${q.str('value')}')
          .join('&');
      return '${protocol.isEmpty ? '' : '$protocol://'}$host${path.isEmpty ? '' : '/$path'}${query.isEmpty ? '' : '?$query'}';
    }
    return '';
  }

  RequestBody _body(
    JsonMap? body,
    ImportCounter counter,
    List<String> warnings,
  ) {
    if (body == null) return const RequestBody();
    switch (body.str('mode')) {
      case 'raw':
        final text = counter.text(body['raw']);
        final lang = body.obj('options').obj('raw').str('language');
        if (lang == 'json') return RequestBody(type: BodyType.json, text: text);
        return RequestBody(
          type: BodyType.raw,
          text: text,
          rawLanguage: switch (lang) {
            'xml' => RawLanguage.xml,
            'html' => RawLanguage.html,
            'javascript' => RawLanguage.javascript,
            _ => RawLanguage.text,
          },
        );
      case 'urlencoded':
        return RequestBody(
          type: BodyType.urlEncoded,
          urlEncoded: [
            for (final f in body.objList('urlencoded'))
              KeyValue(
                key: counter.text(f['key']),
                value: counter.text(f['value']),
                enabled: !f.boolean('disabled'),
              ),
          ],
        );
      case 'formdata':
        return RequestBody(
          type: BodyType.formData,
          formData: [
            for (final f in body.objList('formdata'))
              f.str('type') == 'file'
                  ? FormDataField(
                      key: counter.text(f['key']),
                      kind: FormFieldKind.file,
                      filePath: f['src'] is String ? f.str('src') : null,
                      contentType: f.str('contentType'),
                      enabled: !f.boolean('disabled'),
                    )
                  : FormDataField(
                      key: counter.text(f['key']),
                      value: counter.text(f['value']),
                      contentType: f.str('contentType'),
                      enabled: !f.boolean('disabled'),
                    ),
          ],
        );
      case 'file':
        final src = body.obj('file').strOrNull('src');
        return RequestBody(type: BodyType.binary, binaryFilePath: src);
      case 'graphql':
        final g = body.obj('graphql');
        Object? variables;
        try {
          variables = g.str('variables').trim().isEmpty
              ? null
              : jsonDecode(g.str('variables'));
        } catch (_) {
          variables = null;
        }
        warnings.add('GraphQL bodies were converted to JSON bodies.');
        return RequestBody(
          type: BodyType.json,
          text: const JsonEncoder.withIndent(
            '  ',
          ).convert({'query': g.str('query'), 'variables': ?variables}),
        );
      default:
        return const RequestBody();
    }
  }

  /// Null for `inherit`.
  RequestAuth? _auth(JsonMap auth, List<String> warnings) {
    String field(String type, String key) {
      final entries = auth[type];
      if (entries is List) {
        for (final e in entries) {
          if (e is Map && e['key'] == key) return e['value']?.toString() ?? '';
        }
      } else if (entries is Map) {
        return entries[key]?.toString() ?? '';
      }
      return '';
    }

    switch (auth.str('type')) {
      case 'bearer':
        return BearerAuth(token: field('bearer', 'token'));
      case 'basic':
        return BasicAuth(
          username: field('basic', 'username'),
          password: field('basic', 'password'),
        );
      case 'apikey':
        return ApiKeyAuth(
          key: field('apikey', 'key'),
          value: field('apikey', 'value'),
          location: field('apikey', 'in') == 'query'
              ? ApiKeyLocation.query
              : ApiKeyLocation.header,
        );
      case 'oauth2':
        return OAuth2Auth(
          accessToken: field('oauth2', 'accessToken'),
          authUrl: field('oauth2', 'authUrl'),
          tokenUrl: field('oauth2', 'accessTokenUrl'),
          clientId: field('oauth2', 'clientId'),
          clientSecret: field('oauth2', 'clientSecret'),
          scope: field('oauth2', 'scope'),
          grantType: field('oauth2', 'grant_type') == 'client_credentials'
              ? OAuth2GrantType.clientCredentials
              : OAuth2GrantType.authorizationCode,
        );
      case 'inherit':
        return null;
      case 'noauth' || '':
        return const NoAuth();
      default:
        warnings.add(
          'Unsupported auth type "${auth.str('type')}" was skipped.',
        );
        return const NoAuth();
    }
  }

  static String _description(Object? d) {
    if (d is String) return d;
    if (d is Map) return d['content']?.toString() ?? '';
    return '';
  }
}

/// Imports Postman environment exports (`values: [{key, value, enabled, type}]`).
class PostmanEnvironmentImporter implements EnvironmentImporter {
  const PostmanEnvironmentImporter();

  @override
  String get name => 'Postman environment';

  @override
  bool canImport(JsonMap json) =>
      json['values'] is List && json['name'] is String;

  @override
  ImportResult<Environment> parse(JsonMap json) {
    final values = json.objList('values');
    return ImportResult(
      Environment(
        name: json.str('name', 'Imported environment'),
        variables: [
          for (final v in values)
            EnvVariable(
              key: v.str('key'),
              value: v.str('value'),
              enabled: v.boolean('enabled', true),
              isSecret: v.str('type') == 'secret',
            ),
        ],
      ),
      source: name,
    );
  }
}
