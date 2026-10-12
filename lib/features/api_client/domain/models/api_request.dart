import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/utils/id.dart';
import '../../../../core/utils/json_read.dart';
import 'http_method.dart';
import 'key_value.dart';
import 'request_auth.dart';
import 'request_body.dart';
import 'variable_extraction.dart';

/// Per-request overrides of the global network settings.
@immutable
class RequestOptions {
  const RequestOptions({
    this.timeoutMs,
    this.followRedirects,
    this.disabledDefaultHeaders = const {},
    this.extractions = const [],
  });

  /// null → use the global setting.
  final int? timeoutMs;
  final bool? followRedirects;

  /// Lowercase names of default headers (User-Agent, Accept, Content-Type)
  /// that are not added automatically.
  final Set<String> disabledDefaultHeaders;

  /// Variables set from a successful response (no-code post-response step).
  final List<VariableExtraction> extractions;

  RequestOptions copyWith({
    Set<String>? disabledDefaultHeaders,
    List<VariableExtraction>? extractions,
  }) => RequestOptions(
    timeoutMs: timeoutMs,
    followRedirects: followRedirects,
    disabledDefaultHeaders:
        disabledDefaultHeaders ?? this.disabledDefaultHeaders,
    extractions: extractions ?? this.extractions,
  );

  JsonMap toJson() => {
    if (timeoutMs != null) 'timeoutMs': timeoutMs,
    if (followRedirects != null) 'followRedirects': followRedirects,
    if (disabledDefaultHeaders.isNotEmpty)
      'disabledDefaultHeaders': disabledDefaultHeaders.toList()..sort(),
    if (extractions.isNotEmpty)
      'extractions': [for (final e in extractions) e.toJson()],
  };

  factory RequestOptions.fromJson(JsonMap json) => RequestOptions(
    timeoutMs: json.intOrNull('timeoutMs'),
    followRedirects: json['followRedirects'] is bool
        ? json['followRedirects']! as bool
        : null,
    disabledDefaultHeaders: {
      for (final v in json.list('disabledDefaultHeaders'))
        if (v is String) v.toLowerCase(),
    },
    extractions: [
      for (final e in json.objList('extractions'))
        VariableExtraction.fromJson(e),
    ],
  );

  static const _setEq = SetEquality<String>();
  static const _listEq = ListEquality<VariableExtraction>();

  @override
  bool operator ==(Object other) =>
      other is RequestOptions &&
      other.timeoutMs == timeoutMs &&
      other.followRedirects == followRedirects &&
      _setEq.equals(other.disabledDefaultHeaders, disabledDefaultHeaders) &&
      _listEq.equals(other.extractions, extractions);

  @override
  int get hashCode => Object.hash(
    timeoutMs,
    followRedirects,
    _setEq.hash(disabledDefaultHeaders),
    _listEq.hash(extractions),
  );
}

@immutable
class ApiRequest {
  ApiRequest({
    String? id,
    this.name = 'Untitled request',
    this.method = HttpMethod.get,
    this.url = '',
    this.params = const [],
    this.headers = const [],
    this.body = const RequestBody(),
    this.auth = const NoAuth(),
    this.options = const RequestOptions(),
    this.description = '',
    this.collectionId,
    this.folderId,
    this.sortOrder = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  final String id;
  final String name;
  final HttpMethod method;

  /// URL as typed, including the query string and `{{variables}}`.
  final String url;

  /// Query parameters; kept in sync with [url] by the editor.
  final List<KeyValue> params;
  final List<KeyValue> headers;
  final RequestBody body;
  final RequestAuth auth;
  final RequestOptions options;
  final String description;
  final String? collectionId;
  final String? folderId;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  ApiRequest copyWith({
    String? id,
    String? name,
    HttpMethod? method,
    String? url,
    List<KeyValue>? params,
    List<KeyValue>? headers,
    RequestBody? body,
    RequestAuth? auth,
    RequestOptions? options,
    String? description,
    String? Function()? collectionId,
    String? Function()? folderId,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ApiRequest(
    id: id ?? this.id,
    name: name ?? this.name,
    method: method ?? this.method,
    url: url ?? this.url,
    params: params ?? this.params,
    headers: headers ?? this.headers,
    body: body ?? this.body,
    auth: auth ?? this.auth,
    options: options ?? this.options,
    description: description ?? this.description,
    collectionId: collectionId != null ? collectionId() : this.collectionId,
    folderId: folderId != null ? folderId() : this.folderId,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Whether the user-editable content equals [other] (ignores identity,
  /// placement and timestamps). Used for dirty tracking.
  bool sameContentAs(ApiRequest other) =>
      name == other.name &&
      method == other.method &&
      url == other.url &&
      _eq.equals(params, other.params) &&
      _eq.equals(headers, other.headers) &&
      body == other.body &&
      auth == other.auth &&
      options == other.options &&
      description == other.description;

  static const _eq = ListEquality<KeyValue>();

  /// Portable representation used by export, history snapshots and sync.
  JsonMap toJson({bool includeSecrets = false}) => {
    'id': id,
    'name': name,
    'method': method.value,
    'url': url,
    'params': params.toJson(),
    'headers': headers.toJson(),
    'body': body.toJson(),
    'auth': auth.toJson(includeSecrets: includeSecrets),
    if (options.toJson().isNotEmpty) 'options': options.toJson(),
    if (description.isNotEmpty) 'description': description,
  };

  factory ApiRequest.fromJson(
    JsonMap json, {
    String? collectionId,
    String? folderId,
    bool keepId = true,
  }) => ApiRequest(
    id: keepId ? json.strOrNull('id') : null,
    name: json.str('name', 'Untitled request'),
    method: HttpMethod.parse(json.strOrNull('method')),
    url: json.str('url'),
    params: KeyValueList.fromJson(json.objList('params')),
    headers: KeyValueList.fromJson(json.objList('headers')),
    body: RequestBody.fromJson(json.obj('body')),
    auth: RequestAuth.fromJson(json.obj('auth')),
    options: RequestOptions.fromJson(json.obj('options')),
    description: json.str('description'),
    collectionId: collectionId,
    folderId: folderId,
  );
}
