import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/security/redactor.dart';
import '../../../../core/utils/id.dart';
import '../../../../core/utils/json_read.dart';
import 'api_response.dart';
import 'http_method.dart';

/// A response stored on a request as a named example (success or error).
@immutable
class SavedResponse {
  SavedResponse({
    String? id,
    required this.name,
    required this.statusCode,
    this.statusMessage = '',
    this.headers = const [],
    this.body = '',
    DateTime? savedAt,
  }) : id = id ?? newId(),
       savedAt = savedAt ?? DateTime.now();

  /// Largest body kept; longer bodies are cut.
  static const maxBodyChars = 1024 * 1024;

  final String id;
  final String name;
  final int statusCode;
  final String statusMessage;

  /// Header name/value pairs; names are lower-case.
  final List<MapEntry<String, String>> headers;
  final String body;
  final DateTime savedAt;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Whether the body was cut to [maxBodyChars] when it was saved.
  bool get isTruncated => body.length >= maxBodyChars;

  String get label => '$statusCode${statusMessage.isEmpty ? '' : ' $statusMessage'}';

  /// Whether [response] can be stored as an example: binary and image bodies
  /// are not.
  static bool canSave(ApiResponse response) => response.isTextual;

  /// Sensitive headers (cookies, tokens) are masked before saving.
  factory SavedResponse.fromApiResponse(ApiResponse r, {String? name}) {
    final text = r.bodyText;
    return SavedResponse(
      name: name == null || name.trim().isEmpty
          ? '${r.statusCode} ${r.statusMessage}'.trim()
          : name.trim(),
      statusCode: r.statusCode,
      statusMessage: r.statusMessage,
      headers: [
        for (final h in r.headers)
          MapEntry(
            h.key,
            Redactor.isSensitiveHeader(h.key) ? Redactor.mask : h.value,
          ),
      ],
      body: text.length > maxBodyChars ? text.substring(0, maxBodyChars) : text,
    );
  }

  /// Renders like a live response so the response panel can show it.
  ApiResponse toApiResponse({required String requestUrl, HttpMethod? method}) {
    return ApiResponse(
      statusCode: statusCode,
      statusMessage: statusMessage,
      headers: headers,
      bodyBytes: Uint8List.fromList(utf8.encode(body)),
      duration: Duration.zero,
      requestUrl: requestUrl,
      method: method ?? HttpMethod.get,
      receivedAt: savedAt,
    );
  }

  SavedResponse copyWith({String? name}) => SavedResponse(
    id: id,
    name: name ?? this.name,
    statusCode: statusCode,
    statusMessage: statusMessage,
    headers: headers,
    body: body,
    savedAt: savedAt,
  );

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'status': statusCode,
    if (statusMessage.isNotEmpty) 'statusText': statusMessage,
    if (headers.isNotEmpty)
      'headers': [
        for (final h in headers) {'key': h.key, 'value': h.value},
      ],
    'body': body,
    'savedAt': savedAt.toUtc().toIso8601String(),
  };

  factory SavedResponse.fromJson(JsonMap json, {bool keepId = true}) =>
      SavedResponse(
        id: keepId ? json.strOrNull('id') : null,
        name: json.str('name', 'Example'),
        statusCode: json.integer('status', 200),
        statusMessage: json.str('statusText'),
        headers: [
          for (final h in json.objList('headers'))
            MapEntry(h.str('key').toLowerCase(), h.str('value')),
        ],
        body: json.str('body'),
        savedAt: DateTime.tryParse(json.str('savedAt')),
      );

  static List<SavedResponse> listFromJson(
    List<JsonMap> raw, {
    bool keepId = true,
  }) => [for (final e in raw) SavedResponse.fromJson(e, keepId: keepId)];

  static List<JsonMap> listToJson(List<SavedResponse> list) => [
    for (final e in list) e.toJson(),
  ];

  @override
  bool operator ==(Object other) =>
      other is SavedResponse &&
      other.id == id &&
      other.name == name &&
      other.statusCode == statusCode &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, name, statusCode, body);
}
