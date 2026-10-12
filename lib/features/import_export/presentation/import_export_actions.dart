import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../collections/domain/collection_repository.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../environments/domain/environment_models.dart';
import '../domain/collection_codec.dart';
import '../domain/import_service.dart';

final importServiceProvider = Provider<ImportService>(
  (ref) => const ImportService(),
);

/// File-based import/export commands.
class ImportExportActions {
  const ImportExportActions(this.ref, this.context);

  final WidgetRef ref;
  final BuildContext context;

  Future<String?> _pickJson(String title) async {
    final file = (await _pickJsonFiles(title, multiple: false)).firstOrNull;
    if (file?.error case final error?) throw ImportFailure(error);
    return file?.text;
  }

  /// Picked `.json` files, read as text. A file that cannot be read becomes
  /// an entry with [_PickedFile.error] set.
  Future<List<_PickedFile>> _pickJsonFiles(
    String title, {
    bool multiple = true,
  }) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    return [
      for (final file in multiple ? files : files.take(1))
        await () async {
          try {
            ImportLimits.checkSize(await file.xFile.length());
            final text = await file.xFile.readAsString();
            return _PickedFile(file.name, text: text);
          } catch (e) {
            return _PickedFile(file.name, error: e.userMessage);
          }
        }(),
    ];
  }

  /// Parses each file and hands it to [store]; one bad file does not stop
  /// the others. Reports a summary toast and any notes.
  Future<void> _importFiles(
    List<_PickedFile> files,
    Future<void> Function(CollectionDocument doc) store, {
    required String Function(CollectionDocument doc, String counts) single,
    required String Function(int count, String counts) many,
    List<String> Function(CollectionDocument doc)? extraNotes,
  }) async {
    if (files.isEmpty) return;
    final service = ref.read(importServiceProvider);
    final notes = <String>[];
    final imported = <CollectionDocument>[];
    final failed = <String>[];
    var sources = '';
    for (final file in files) {
      final label = files.length > 1 ? '${file.name}: ' : '';
      try {
        final text = file.text;
        if (text == null) {
          throw ImportFailure(file.error ?? 'The file could not be read.');
        }
        final json = await ImportService.decode(text);
        final result = service.parseCollection(json);
        await store(result.value);
        imported.add(result.value);
        sources = result.source;
        final fileNotes = [
          ...result.warnings,
          ...?extraNotes?.call(result.value),
        ];
        notes.addAll([for (final w in fileNotes) '$label$w']);
      } catch (e) {
        failed.add('${file.name}: ${e.userMessage}');
      }
    }
    if (!context.mounted) return;

    final counts = _counts([for (final d in imported) ...d.items]);
    if (imported.isEmpty) {
      showToast(
        context,
        failed.length == 1 ? failed.single : 'No file could be imported.',
        error: true,
      );
    } else if (files.length == 1) {
      showToast(context, '${single(imported.single, counts)} ($sources)');
    } else {
      showToast(
        context,
        '${many(imported.length, counts)}'
        '${failed.isEmpty ? '' : ' · ${failed.length} failed'}',
        error: failed.isNotEmpty,
      );
    }
    final all = [
      if (imported.isNotEmpty || failed.length > 1)
        for (final f in failed) 'Not imported: $f',
      ...notes,
    ];
    if (all.isNotEmpty) await _showWarnings(all);
  }

  /// Imports one or more collection files, each as a new collection.
  Future<void> importCollection({String? fromText}) async {
    final files = fromText != null
        ? [_PickedFile('Pasted text', text: fromText)]
        : await _pickJsonFiles('Import collections');
    final ids = <String>[];
    await _importFiles(
      files,
      (doc) async => ids.add(
        await ref.read(collectionRepositoryProvider).importCollection(doc),
      ),
      single: (doc, counts) => 'Imported "${doc.name}": $counts',
      many: (n, counts) => 'Imported $n collections: $counts',
    );
    if (ids.length == 1) ref.read(expandedNodesProvider.notifier).expand(ids);
  }

  /// Imports one or more collection files and appends their folders and
  /// requests to the existing collection [collectionId].
  Future<void> importIntoCollection(
    String collectionId,
    String collectionName,
  ) async {
    final files = await _pickJsonFiles('Import into "$collectionName"');
    await _importFiles(
      files,
      (doc) => ref
          .read(collectionRepositoryProvider)
          .importIntoCollection(collectionId, doc),
      single: (_, counts) => 'Imported $counts into "$collectionName"',
      many: (n, counts) => 'Imported $n files into "$collectionName": $counts',
      extraNotes: (doc) => [
        if (!doc.settings.isEmpty)
          'Collection authorization and variables from the file were not '
              'imported; "$collectionName" keeps its own.',
      ],
    );
    ref.read(expandedNodesProvider.notifier).expand([collectionId]);
  }

  /// "12 requests, 3 folders" for the items of an imported collection.
  static String _counts(List<CollectionItem> items) {
    var requests = 0;
    var folders = 0;
    void walk(List<CollectionItem> list) {
      for (final i in list) {
        switch (i) {
          case FolderItem(:final items):
            folders++;
            walk(items);
          case RequestItem():
            requests++;
        }
      }
    }

    walk(items);
    return '$requests request(s), $folders folder(s)';
  }

  Future<void> importEnvironment({String? fromText}) async {
    try {
      final text = fromText ?? await _pickJson('Import environment');
      if (text == null) return;
      final result = ref
          .read(importServiceProvider)
          .parseEnvironment(await ImportService.decode(text));
      await ref
          .read(environmentRepositoryProvider)
          .createEnvironment(
            result.value.name,
            variables: result.value.variables,
          );
      if (!context.mounted) return;
      showToast(context, 'Imported environment "${result.value.name}"');
      if (result.warnings.isNotEmpty) await _showWarnings(result.warnings);
    } catch (e) {
      if (context.mounted) showToast(context, e.userMessage, error: true);
    }
  }

  Future<void> exportCollection(String id, String name) async {
    final includeSecrets = await _askIncludeSecrets('collection');
    if (includeSecrets == null) return;
    try {
      final doc = await ref
          .read(collectionRepositoryProvider)
          .exportCollection(id, includeSecrets: includeSecrets);
      final json = const VesperCollectionCodec().encode(
        doc,
        includeSecrets: includeSecrets,
      );
      await _save('${Formatters.slug(name)}.vesper.json', json);
    } catch (e) {
      if (context.mounted) showToast(context, e.userMessage, error: true);
    }
  }

  Future<void> exportEnvironment(Environment env) async {
    final hasSecrets = env.variables.any((v) => v.isSecret);
    final includeSecrets = hasSecrets
        ? await _askIncludeSecrets('environment')
        : false;
    if (includeSecrets == null) return;
    final json = const VesperEnvironmentCodec().encode(
      env,
      includeSecrets: includeSecrets,
    );
    await _save('${Formatters.slug(env.name)}.env.vesper.json', json);
  }

  Future<void> _save(String fileName, Map<String, Object?> json) async {
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
      );
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Export',
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        mimeType: 'application/json',
      );
      if (uri != null && context.mounted) {
        showToast(context, 'Exported $fileName');
      }
    } catch (_) {
      if (context.mounted) {
        showToast(
          context,
          const StorageFailure('Could not write the export file.').message,
          error: true,
        );
      }
    }
  }

  Future<bool?> _askIncludeSecrets(String what) => showDialog<bool>(
    context: context,
    builder: (context) {
      var include = false;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Export $what'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Secrets (tokens, passwords, API keys and secret variables) are excluded by default.',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: include,
                  onChanged: (v) => setState(() => include = v ?? false),
                  title: const Text(
                    'Include secret values',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: include
                      ? Text(
                          'Anyone with the file can read these secrets in plain text.',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.colors.warning,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, include),
              child: const Text('Export…'),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _showWarnings(List<String> warnings) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Imported with notes'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final w in warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '• $w',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.colors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class _PickedFile {
  const _PickedFile(this.name, {this.text, this.error});
  final String name;
  final String? text;
  final String? error;
}
