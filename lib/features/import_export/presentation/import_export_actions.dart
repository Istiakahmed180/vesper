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
import '../../api_client/domain/models/api_request.dart';
import '../../collections/domain/collection_models.dart';
import '../../collections/domain/collection_repository.dart';
import '../../collections/presentation/collection_providers.dart';
import '../../environments/domain/environment_models.dart';
import '../../workspace/presentation/workspace_controller.dart';
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

  /// Parses each file and hands it to [store], which returns the document
  /// it stored, or null when the user skipped it. One bad file does not
  /// stop the others. Reports a summary toast and any notes.
  Future<void> _importFiles(
    List<_PickedFile> files,
    Future<CollectionDocument?> Function(CollectionDocument doc) store, {
    required String Function(CollectionDocument doc, String counts) single,
    required String Function(int count, String counts) many,
    List<String> Function(CollectionDocument doc)? extraNotes,
  }) async {
    if (files.isEmpty) return;
    final service = ref.read(importServiceProvider);
    final notes = <String>[];
    final imported = <CollectionDocument>[];
    final failed = <String>[];
    var skipped = 0;
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
        final stored = await store(result.value);
        if (stored == null) {
          skipped++;
          continue;
        }
        imported.add(stored);
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
    if (imported.isEmpty && failed.isEmpty) return;
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
        '${skipped == 0 ? '' : ' · $skipped skipped'}'
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

  /// Imports one or more collection files, each as a new collection. When a
  /// collection with the same name exists, asks whether to replace it or
  /// add the import as a copy.
  Future<void> importCollection({String? fromText}) async {
    final files = fromText != null
        ? [_PickedFile('Pasted text', text: fromText)]
        : await _pickJsonFiles('Import collections');
    if (files.isEmpty) return;
    final repo = ref.read(collectionRepositoryProvider);
    final existing = {
      for (final t in await repo.watchTrees().first)
        t.collection.name: t.collection.id,
    };
    final resolve = _duplicateResolver('collection', many: files.length > 1);
    final ids = <String>[];
    final replaced = <String>{};
    await _importFiles(
      files,
      (doc) async {
        var target = doc;
        if (existing[doc.name] case final id?) {
          switch (await resolve(doc.name)) {
            case null:
              return null;
            case _DuplicateAction.replace:
              await repo.replaceCollection(id, doc);
              ids.add(id);
              replaced.add(doc.name);
              return doc;
            case _DuplicateAction.copy:
              target = CollectionDocument(
                name: _copyName(doc.name, existing.keys),
                description: doc.description,
                items: doc.items,
                settings: doc.settings,
              );
          }
        }
        final id = await repo.importCollection(target);
        existing[target.name] = id;
        ids.add(id);
        return target;
      },
      single: (doc, counts) =>
          '${replaced.contains(doc.name) ? 'Replaced' : 'Imported'} '
          '"${doc.name}": $counts',
      many: (n, counts) => 'Imported $n collections: $counts',
    );
    if (ids.length == 1) ref.read(expandedNodesProvider.notifier).expand(ids);
  }

  /// Returns a function asking what to do with an imported [kind] whose
  /// name is taken; it returns null when the user skips that one. With
  /// [many], the dialog offers to reuse the answer for the remaining
  /// duplicates of this import.
  Future<_DuplicateAction?> Function(String name) _duplicateResolver(
    String kind, {
    bool many = false,
  }) {
    _DuplicateAction? forAll;
    return (name) async {
      if (forAll != null) return forAll;
      if (!context.mounted) return null;
      final answer = await _askDuplicate(kind, name, offerForAll: many);
      if (answer == null) return null;
      if (answer.forAll) forAll = answer.action;
      return answer.action;
    };
  }

  /// "[name] copy", or "[name] copy 2", "[name] copy 3"… when taken.
  static String _copyName(String name, Iterable<String> taken) {
    final names = taken.toSet();
    var candidate = '$name copy';
    for (var n = 2; names.contains(candidate); n++) {
      candidate = '$name copy $n';
    }
    return candidate;
  }

  Future<({_DuplicateAction action, bool forAll})?> _askDuplicate(
    String kind,
    String name, {
    required bool offerForAll,
  }) => showDialog(
    context: context,
    builder: (context) {
      var forAll = false;
      return StatefulBuilder(
        builder: (context, setState) {
          final colors = context.colors;
          void pick(_DuplicateAction action) =>
              Navigator.pop(context, (action: action, forAll: forAll));
          return AlertDialog(
            title: Text('Duplicate $kind'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A $kind named "$name" already exists. Replace it with '
                    'the imported one, or add the import as a copy?',
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                  if (offerForAll) ...[
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: forAll,
                      onChanged: (v) => setState(() => forAll = v ?? false),
                      title: const Text(
                        'Do this for all duplicates',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Skip'),
              ),
              TextButton(
                onPressed: () => pick(_DuplicateAction.copy),
                child: const Text('Add as copy'),
              ),
              FilledButton(
                autofocus: true,
                style: FilledButton.styleFrom(backgroundColor: colors.danger),
                onPressed: () => pick(_DuplicateAction.replace),
                child: const Text('Replace'),
              ),
            ],
          );
        },
      );
    },
  );

  /// Imports one or more collection files and appends their folders and
  /// requests to the existing collection [collectionId], or to its folder
  /// [folderId] when given. [targetName] names the collection or folder.
  Future<void> importIntoCollection(
    String collectionId,
    String targetName, {
    String? folderId,
  }) async {
    final files = await _pickJsonFiles('Import into "$targetName"');
    await _importFiles(
      files,
      (doc) async {
        await ref
            .read(collectionRepositoryProvider)
            .importIntoCollection(collectionId, doc, folderId: folderId);
        return doc;
      },
      single: (_, counts) => 'Imported $counts into "$targetName"',
      many: (n, counts) => 'Imported $n files into "$targetName": $counts',
      extraNotes: (doc) => [
        if (!doc.settings.isEmpty)
          'Collection authorization and variables from the file were not '
              'imported; the collection keeps its own.',
      ],
    );
    final trees = ref.read(collectionTreesProvider).value ?? const [];
    ref
        .read(expandedNodesProvider.notifier)
        .expand(
          folderId == null
              ? [collectionId]
              : trees.ancestorIdsForLocation(
                  TreeLocation(collectionId, folderId),
                ),
        );
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
      final repo = ref.read(environmentRepositoryProvider);
      final envs = [
        for (final e in await repo.watchEnvironments().first)
          if (!e.isGlobal) e,
      ];
      final imported = result.value;
      var name = imported.name;
      var verb = 'Imported';
      final match = envs.where((e) => e.name == name).firstOrNull;
      final action = match == null
          ? null
          : await _duplicateResolver('environment')(name);
      if (match != null && action == null) return;
      if (match != null && action == _DuplicateAction.replace) {
        // Secret values left out of the file keep their local value.
        final local = {for (final v in match.variables) v.key: v};
        await repo.saveEnvironment(
          match.copyWith(
            variables: [
              for (final v in imported.variables)
                v.isSecret && v.value.isEmpty
                    ? v.copyWith(value: local[v.key]?.value ?? '')
                    : v,
            ],
          ),
        );
        verb = 'Replaced';
      } else {
        if (match != null) {
          name = _copyName(name, [for (final e in envs) e.name]);
        }
        await repo.createEnvironment(name, variables: imported.variables);
      }
      if (!context.mounted) return;
      showToast(context, '$verb environment "$name"');
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

  /// Exports only the folder [id]: its subfolders and requests, plus the
  /// collection's auth and variables so inherited auth keeps working.
  Future<void> exportFolder(String id, String name) async {
    final includeSecrets = await _askIncludeSecrets('folder');
    if (includeSecrets == null) return;
    try {
      final doc = await ref
          .read(collectionRepositoryProvider)
          .exportFolder(id, includeSecrets: includeSecrets);
      final json = const VesperCollectionCodec().encode(
        doc,
        includeSecrets: includeSecrets,
      );
      await _save('${Formatters.slug(name)}.vesper.json', json);
    } catch (e) {
      if (context.mounted) showToast(context, e.userMessage, error: true);
    }
  }

  /// Exports only the request [id], plus the collection's auth and
  /// variables so inherited auth keeps working.
  Future<void> exportRequest(String id, String name) async {
    final includeSecrets = await _askIncludeSecrets('request');
    if (includeSecrets == null) return;
    try {
      final doc = await ref
          .read(collectionRepositoryProvider)
          .exportRequest(id, includeSecrets: includeSecrets);
      final json = const VesperCollectionCodec().encode(
        doc,
        includeSecrets: includeSecrets,
      );
      await _save('${Formatters.slug(name)}.vesper.json', json);
    } catch (e) {
      if (context.mounted) showToast(context, e.userMessage, error: true);
    }
  }

  /// Replaces the saved request [id] with the first request in a picked
  /// file, keeping its place in the tree. Open tabs show the new content.
  Future<void> replaceRequest(String id, String name) async {
    try {
      final text = await _pickJson('Replace "$name"');
      if (text == null) return;
      final result = ref
          .read(importServiceProvider)
          .parseCollection(await ImportService.decode(text));
      final requests = _requests(result.value.items);
      if (requests.isEmpty) {
        throw const ImportFailure('The file does not contain a request.');
      }
      final source = requests.first;
      if (!context.mounted) return;
      final ok = await confirmDialog(
        context,
        title: 'Replace request',
        message:
            'Replace "$name" with "${source.name}" from the file? Unsaved '
            'changes in its open tab are discarded. This cannot be undone.',
        confirmLabel: 'Replace',
      );
      if (!ok) return;
      final saved = await ref
          .read(collectionRepositoryProvider)
          .replaceRequest(id, source);
      ref.read(workspaceProvider.notifier).reloadSavedRequest(saved);
      if (!context.mounted) return;
      showToast(context, 'Replaced "$name" (${result.source})');
      final notes = [
        if (requests.length > 1)
          'The file has ${requests.length} requests; only the first, '
              '"${source.name}", was used.',
        if (!result.value.settings.isEmpty)
          'Collection authorization and variables from the file were not '
              'imported; the collection keeps its own.',
        ...result.warnings,
      ];
      if (notes.isNotEmpty) await _showWarnings(notes);
    } catch (e) {
      if (context.mounted) showToast(context, e.userMessage, error: true);
    }
  }

  /// All requests in [items], depth first.
  static List<ApiRequest> _requests(List<CollectionItem> items) => [
    for (final i in items)
      ...switch (i) {
        FolderItem(:final items) => _requests(items),
        RequestItem(:final request) => [request],
      },
  ];

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

/// What to do with an imported item whose name is already taken.
enum _DuplicateAction { replace, copy }

class _PickedFile {
  const _PickedFile(this.name, {this.text, this.error});
  final String name;
  final String? text;
  final String? error;
}
