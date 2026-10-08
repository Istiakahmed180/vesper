import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/utils/id.dart';
import '../../../../core/utils/json_read.dart';
import 'key_value.dart';

enum BodyType {
  none('None'),
  json('JSON'),
  raw('Raw'),
  formData('Form Data'),
  urlEncoded('x-www-form-urlencoded'),
  binary('Binary');

  const BodyType(this.label);
  final String label;

  static BodyType parse(String? name) =>
      values.firstWhereOrNull((e) => e.name == name) ?? BodyType.none;
}

enum RawLanguage {
  text('Text', 'text/plain'),
  json('JSON', 'application/json'),
  xml('XML', 'application/xml'),
  html('HTML', 'text/html'),
  javascript('JavaScript', 'application/javascript');

  const RawLanguage(this.label, this.contentType);
  final String label;
  final String contentType;

  static RawLanguage parse(String? name) =>
      values.firstWhereOrNull((e) => e.name == name) ?? RawLanguage.text;
}

enum FormFieldKind { text, file }

@immutable
class FormDataField {
  FormDataField({
    String? id,
    this.key = '',
    this.value = '',
    this.kind = FormFieldKind.text,
    this.filePath,
    this.contentType = '',
    this.enabled = true,
  }) : id = id ?? newId();

  final String id;
  final String key;

  /// Text value when [kind] is text.
  final String value;
  final FormFieldKind kind;

  /// Absolute path of the file to upload when [kind] is file.
  final String? filePath;

  /// Optional explicit content type for the part.
  final String contentType;
  final bool enabled;

  bool get isActive => enabled && key.isNotEmpty;
  bool get isEmpty => key.isEmpty && value.isEmpty && filePath == null;

  FormDataField copyWith({
    String? key,
    String? value,
    FormFieldKind? kind,
    String? Function()? filePath,
    String? contentType,
    bool? enabled,
  }) => FormDataField(
    id: id,
    key: key ?? this.key,
    value: value ?? this.value,
    kind: kind ?? this.kind,
    filePath: filePath != null ? filePath() : this.filePath,
    contentType: contentType ?? this.contentType,
    enabled: enabled ?? this.enabled,
  );

  JsonMap toJson() => {
    'id': id,
    'key': key,
    'value': value,
    'kind': kind.name,
    if (filePath != null) 'filePath': filePath,
    if (contentType.isNotEmpty) 'contentType': contentType,
    'enabled': enabled,
  };

  factory FormDataField.fromJson(JsonMap json) => FormDataField(
    id: json.strOrNull('id'),
    key: json.str('key'),
    value: json.str('value'),
    kind: json.str('kind') == 'file' ? FormFieldKind.file : FormFieldKind.text,
    filePath: json.strOrNull('filePath'),
    contentType: json.str('contentType'),
    enabled: json.boolean('enabled', true),
  );

  @override
  bool operator ==(Object other) =>
      other is FormDataField &&
      other.id == id &&
      other.key == key &&
      other.value == value &&
      other.kind == kind &&
      other.filePath == filePath &&
      other.contentType == contentType &&
      other.enabled == enabled;

  @override
  int get hashCode =>
      Object.hash(id, key, value, kind, filePath, contentType, enabled);
}

/// The request body. Every body type keeps its own content so switching type
/// in the UI never loses what the user typed.
@immutable
class RequestBody {
  const RequestBody({
    this.type = BodyType.none,
    this.text = '',
    this.rawLanguage = RawLanguage.text,
    this.formData = const [],
    this.urlEncoded = const [],
    this.binaryFilePath,
  });

  final BodyType type;

  /// Shared editor text for [BodyType.json] and [BodyType.raw].
  final String text;
  final RawLanguage rawLanguage;
  final List<FormDataField> formData;
  final List<KeyValue> urlEncoded;
  final String? binaryFilePath;

  String? get impliedContentType => switch (type) {
    BodyType.none => null,
    BodyType.json => 'application/json',
    BodyType.raw => rawLanguage.contentType,
    BodyType.formData => 'multipart/form-data',
    BodyType.urlEncoded => 'application/x-www-form-urlencoded',
    BodyType.binary => 'application/octet-stream',
  };

  RequestBody copyWith({
    BodyType? type,
    String? text,
    RawLanguage? rawLanguage,
    List<FormDataField>? formData,
    List<KeyValue>? urlEncoded,
    String? Function()? binaryFilePath,
  }) => RequestBody(
    type: type ?? this.type,
    text: text ?? this.text,
    rawLanguage: rawLanguage ?? this.rawLanguage,
    formData: formData ?? this.formData,
    urlEncoded: urlEncoded ?? this.urlEncoded,
    binaryFilePath: binaryFilePath != null
        ? binaryFilePath()
        : this.binaryFilePath,
  );

  JsonMap toJson() => {
    'type': type.name,
    'text': text,
    'rawLanguage': rawLanguage.name,
    'formData': [for (final f in formData) f.toJson()],
    'urlEncoded': urlEncoded.toJson(),
    if (binaryFilePath != null) 'binaryFilePath': binaryFilePath,
  };

  factory RequestBody.fromJson(JsonMap json) => RequestBody(
    type: BodyType.parse(json.strOrNull('type')),
    text: json.str('text'),
    rawLanguage: RawLanguage.parse(json.strOrNull('rawLanguage')),
    formData: [
      for (final f in json.objList('formData')) FormDataField.fromJson(f),
    ],
    urlEncoded: KeyValueList.fromJson(json.objList('urlEncoded')),
    binaryFilePath: json.strOrNull('binaryFilePath'),
  );

  static const _listEq = ListEquality<Object>();

  @override
  bool operator ==(Object other) =>
      other is RequestBody &&
      other.type == type &&
      other.text == text &&
      other.rawLanguage == rawLanguage &&
      _listEq.equals(other.formData, formData) &&
      _listEq.equals(other.urlEncoded, urlEncoded) &&
      other.binaryFilePath == binaryFilePath;

  @override
  int get hashCode => Object.hash(
    type,
    text,
    rawLanguage,
    _listEq.hash(formData),
    _listEq.hash(urlEncoded),
    binaryFilePath,
  );
}
