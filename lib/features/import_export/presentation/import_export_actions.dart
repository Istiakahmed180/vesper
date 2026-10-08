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
    final files = await FilePicker.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = files.firstOrNull;
    if (file == null) return null;
    final bytes = await file.xFile.length();
    ImportLimits.checkSize(bytes);
    return file.xFile.readAsString();
  }

  Future<void> importCollection({String? fromText}) async {
    try {
      final text = fromText ?? await _pickJson('Import collection');
      if (text == null) return;
      final service = ref.read(importServiceProvider);
      final result = service.parseCollection(await ImportService.decode(text));
      final id = await ref
          .read(collectionRepositoryProvider)
          .importCollection(result.value);
      ref.read(expandedNodesProvider.notifier).expand([id]);
      if (!context.mounted) return;
      showToast(context, 'Imported "${result.value.name}" (${result.source})');
      if (result.warnings.isNotEmpty) await _showWarnings(result.warnings);
    } catch (e) {
      if (context.mounted) showToast(context, e.userMessage, error: true);
    }
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
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
