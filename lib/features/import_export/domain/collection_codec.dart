import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/json_read.dart';
import '../../api_client/domain/models/api_request.dart';
import '../../collections/domain/collection_repository.dart';
import '../../environments/domain/environment_models.dart';

/// Native, versioned Vesper exchange formats.
class VesperFormat {
  const VesperFormat._();

  static const collectionFormat = 'vesper.collection';
  static const environmentFormat = 'vesper.environment';
  static const version = 1;
}

class ImportResult<T> {
  const ImportResult(
    this.value, {
    this.warnings = const [],
    required this.source,
  });
  final T value;
  final List<String> warnings;

  /// Human readable name of the detected format.
  final String source;
}

/// Guards against hostile or corrupt files: nesting depth, item counts and
/// field sizes are bounded. Nothing in an import is ever executed.
class ImportLimits {
  const ImportLimits({
    this.maxDepth = 32,
    this.maxItems = 20000,
    this.maxStringLength = 10 * 1024 * 1024,
  });

  final int maxDepth;
  final int maxItems;
  final int maxStringLength;

  static void checkSize(int bytes) {
    if (bytes > AppConstants.maxImportBytes) {
      throw const ImportFailure(
        'The file is too large to import (limit ${AppConstants.maxImportBytes ~/ (1024 * 1024)} MB).',
      );
    }
  }
}

class ImportCounter {
  ImportCounter(this.limits);
  final ImportLimits limits;
  int items = 0;

  void item(int depth) {
    if (depth > limits.maxDepth) {
      throw const ImportFailure('The collection is nested too deeply.');
    }
    if (++items > limits.maxItems) {
      throw ImportFailure(
        'The collection has more than ${limits.maxItems} items.',
      );
    }
  }

  String text(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final s = value is String ? value : '$value';
    if (s.length > limits.maxStringLength) {
      throw const ImportFailure('The file contains a value that is too large.');
    }
    return s;
  }
}

abstract class CollectionImporter {
  String get name;
  bool canImport(JsonMap json);
  ImportResult<CollectionDocument> parse(
    JsonMap json, {
    ImportLimits limits = const ImportLimits(),
  });
}

abstract class EnvironmentImporter {
  String get name;
  bool canImport(JsonMap json);
  ImportResult<Environment> parse(JsonMap json);
}

class VesperCollectionCodec implements CollectionImporter {
  const VesperCollectionCodec();

  @override
  String get name => 'Vesper collection';

  @override
  bool canImport(JsonMap json) =>
      json.str('format') == VesperFormat.collectionFormat;

  JsonMap encode(CollectionDocument doc, {bool includeSecrets = false}) => {
    'format': VesperFormat.collectionFormat,
    'version': VesperFormat.version,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'secretsIncluded': includeSecrets,
    'collection': {
      'name': doc.name,
      if (doc.description.isNotEmpty) 'description': doc.description,
      'items': _encodeItems(doc.items, includeSecrets),
    },
  };

  List<JsonMap> _encodeItems(List<CollectionItem> items, bool includeSecrets) =>
      [
        for (final item in items)
          switch (item) {
            FolderItem(:final name, :final items) => {
              'type': 'folder',
              'name': name,
              'items': _encodeItems(items, includeSecrets),
            },
            RequestItem(:final request) => {
              'type': 'request',
              ...request.toJson(includeSecrets: includeSecrets)..remove('id'),
            },
          },
      ];

  @override
  ImportResult<CollectionDocument> parse(
    JsonMap json, {
    ImportLimits limits = const ImportLimits(),
  }) {
    final version = json.integer('version', -1);
    if (version < 1) {
      throw const ImportFailure('The file has no valid Vesper format version.');
    }
    if (version > VesperFormat.version) {
      throw ImportFailure(
        'This file was created by a newer version of Vesper (format v$version).',
      );
    }
    final collection = json.objOrNull('collection');
    if (collection == null) {
      throw const ImportFailure('The file does not contain a collection.');
    }
    final counter = ImportCounter(limits);
    final name = counter
        .text(collection['name'], fallback: 'Imported collection')
        .trim();
    return ImportResult(
      CollectionDocument(
        name: name.isEmpty ? 'Imported collection' : name,
        description: counter.text(collection['description']),
        items: _decodeItems(collection.objList('items'), counter, 1),
      ),
      source: name,
    );
  }

  List<CollectionItem> _decodeItems(
    List<JsonMap> items,
    ImportCounter counter,
    int depth,
  ) {
    final out = <CollectionItem>[];
    for (final item in items) {
      counter.item(depth);
      switch (item.str('type')) {
        case 'folder':
          out.add(
            FolderItem(
              counter.text(item['name'], fallback: 'Folder'),
              _decodeItems(item.objList('items'), counter, depth + 1),
            ),
          );
        case 'request':
          for (final key in ['url', 'name']) {
            counter.text(item[key]);
          }
          out.add(RequestItem(ApiRequest.fromJson(item, keepId: false)));
        default:
          // Unknown item types from future versions are skipped.
          break;
      }
    }
    return out;
  }
}

class VesperEnvironmentCodec implements EnvironmentImporter {
  const VesperEnvironmentCodec();

  @override
  String get name => 'Vesper environment';

  @override
  bool canImport(JsonMap json) =>
      json.str('format') == VesperFormat.environmentFormat;

  JsonMap encode(Environment env, {bool includeSecrets = false}) => {
    'format': VesperFormat.environmentFormat,
    'version': VesperFormat.version,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'secretsIncluded': includeSecrets,
    'environment': {
      'name': env.name,
      'variables': [
        for (final v in env.variables) v.toJson(includeSecrets: includeSecrets),
      ],
    },
  };

  @override
  ImportResult<Environment> parse(JsonMap json) {
    final version = json.integer('version', -1);
    if (version < 1 || version > VesperFormat.version) {
      throw const ImportFailure('Unsupported Vesper environment version.');
    }
    final env = json.objOrNull('environment');
    if (env == null) {
      throw const ImportFailure('The file does not contain an environment.');
    }
    final vars = env.objList('variables');
    if (vars.length > 5000) {
      throw const ImportFailure('The environment has too many variables.');
    }
    final secretsBlank = vars
        .where((v) => v.boolean('secret') && v.str('value').isEmpty)
        .length;
    return ImportResult(
      Environment(
        name: env.str('name', 'Imported environment'),
        variables: [for (final v in vars) EnvVariable.fromJson(v)],
      ),
      warnings: [
        if (secretsBlank > 0)
          '$secretsBlank secret value(s) were not included in the export and are empty.',
      ],
      source: name,
    );
  }
}
