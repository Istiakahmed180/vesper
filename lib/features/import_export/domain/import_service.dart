import 'dart:convert';
import 'dart:isolate';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/json_read.dart';
import '../../collections/domain/collection_repository.dart';
import '../../environments/domain/environment_models.dart';
import 'collection_codec.dart';
import 'postman_importer.dart';

/// Detects the format of an imported file and dispatches to the matching
/// importer. New formats are added by registering another importer.
class ImportService {
  const ImportService({
    this.collectionImporters = const [
      VesperCollectionCodec(),
      PostmanCollectionImporter(),
    ],
    this.environmentImporters = const [
      VesperEnvironmentCodec(),
      PostmanEnvironmentImporter(),
    ],
  });

  final List<CollectionImporter> collectionImporters;
  final List<EnvironmentImporter> environmentImporters;

  static Future<JsonMap> decode(String text) async {
    ImportLimits.checkSize(text.length);
    Object? decoded;
    try {
      decoded = text.length > 512 * 1024
          ? await Isolate.run(() => jsonDecode(text))
          : jsonDecode(text);
    } on FormatException catch (e) {
      throw ImportFailure('The file is not valid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const ImportFailure('The file does not contain a JSON object.');
    }
    return decoded.cast<String, Object?>();
  }

  ImportResult<CollectionDocument> parseCollection(JsonMap json) {
    for (final importer in collectionImporters) {
      if (importer.canImport(json)) {
        try {
          return importer.parse(json);
        } on AppFailure {
          rethrow;
        } catch (_) {
          throw ImportFailure('The ${importer.name} file is malformed.');
        }
      }
    }
    if (environmentImporters.any((i) => i.canImport(json))) {
      throw const ImportFailure(
        'This file is an environment. Import it from the Environments panel.',
      );
    }
    throw const ImportFailure(
      'Unrecognised collection format. Supported: Vesper and Postman Collection v2.x.',
    );
  }

  ImportResult<Environment> parseEnvironment(JsonMap json) {
    for (final importer in environmentImporters) {
      if (importer.canImport(json)) {
        try {
          return importer.parse(json);
        } on AppFailure {
          rethrow;
        } catch (_) {
          throw ImportFailure('The ${importer.name} file is malformed.');
        }
      }
    }
    throw const ImportFailure(
      'Unrecognised environment format. Supported: Vesper and Postman environments.',
    );
  }
}
