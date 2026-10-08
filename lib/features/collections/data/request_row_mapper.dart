import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../../../core/utils/json_read.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../api_client/domain/models/http_method.dart';
import '../../api_client/domain/models/key_value.dart';
import '../../api_client/domain/models/request_auth.dart';
import '../../api_client/domain/models/request_body.dart';

/// Converts between [RequestRow]s and [ApiRequest]s. Secret auth values are
/// never written to the row.
class RequestRowMapper {
  const RequestRowMapper();

  /// Every field name a [RequestAuth] may report as secret.
  static const secretFields = [
    'token',
    'password',
    'value',
    'clientSecret',
    'accessToken',
    'refreshToken',
  ];

  ApiRequest fromRow(RequestRow row) => ApiRequest(
    id: row.id,
    name: row.name,
    method: HttpMethod.parse(row.method),
    url: row.url,
    params: KeyValueList.fromJson(_list(row.paramsJson)),
    headers: KeyValueList.fromJson(_list(row.headersJson)),
    body: RequestBody.fromJson(_map(row.bodyJson)),
    auth: RequestAuth.fromJson(_map(row.authJson)),
    options: RequestOptions.fromJson(_map(row.optionsJson)),
    description: row.description,
    collectionId: row.collectionId,
    folderId: row.folderId,
    sortOrder: row.sortOrder,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  RequestsCompanion toCompanion(ApiRequest r) => RequestsCompanion(
    id: Value(r.id),
    collectionId: Value(r.collectionId!),
    folderId: Value(r.folderId),
    name: Value(r.name),
    method: Value(r.method.value),
    url: Value(r.url),
    paramsJson: Value(jsonEncode(r.params.toJson())),
    headersJson: Value(jsonEncode(r.headers.toJson())),
    bodyJson: Value(jsonEncode(r.body.toJson())),
    authJson: Value(jsonEncode(r.auth.toJson())),
    optionsJson: Value(jsonEncode(r.options.toJson())),
    description: Value(r.description),
    sortOrder: Value(r.sortOrder),
    createdAt: Value(r.createdAt),
    updatedAt: Value(r.updatedAt),
  );

  static JsonMap _map(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, Object?>() : {};
    } catch (_) {
      return {};
    }
  }

  static List<JsonMap> _list(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! List) return const [];
      return [
        for (final e in v)
          if (e is Map) e.cast<String, Object?>(),
      ];
    } catch (_) {
      return const [];
    }
  }
}
