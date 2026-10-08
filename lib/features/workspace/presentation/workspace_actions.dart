import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../api_client/domain/services/curl_generator.dart';
import '../../api_client/domain/services/curl_parser.dart';
import '../../api_client/domain/services/request_preparer.dart';
import '../../environments/presentation/environment_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/workspace_models.dart';
import 'response_controller.dart';
import 'save_request_dialog.dart';
import 'workspace_controller.dart';

/// User-facing workspace commands shared by buttons, menus and shortcuts.
class WorkspaceActions {
  const WorkspaceActions(this.ref, this.context);

  final WidgetRef ref;
  final BuildContext context;

  WorkspaceController get _ws => ref.read(workspaceProvider.notifier);
  String? get _activeId => ref.read(workspaceProvider).activeTab?.id;

  void newTab() => _ws.newRequestTab();

  Future<void> send([String? tabId]) async {
    final id = tabId ?? _activeId;
    if (id == null || ref.read(workspaceProvider).tab(id) is! RequestTab) {
      return;
    }
    await ref.read(responseProvider(id).notifier).send();
  }

  void cancel([String? tabId]) {
    final id = tabId ?? _activeId;
    if (id != null) ref.read(responseProvider(id).notifier).cancel();
  }

  /// Saves the tab; asks for a location when the request was never saved.
  Future<bool> save([String? tabId, bool saveAs = false]) async {
    final id = tabId ?? _activeId;
    final tab = id == null ? null : ref.read(workspaceProvider).tab(id);
    if (tab is! RequestTab) return false;
    if (tab.isSaved && !saveAs) {
      return await guarded(context, () => _ws.save(tab.id), success: 'Saved') !=
          null;
    }
    final target = await showSaveRequestDialog(
      context,
      initialName: tab.draft.name,
    );
    if (target == null || !context.mounted) return false;
    return await guarded(
          context,
          () => _ws.save(tab.id, location: target.location, name: target.name),
          success: 'Saved "${target.name}"',
        ) !=
        null;
  }

  Future<void> closeTab([String? tabId]) async {
    final id = tabId ?? _activeId;
    final tab = id == null ? null : ref.read(workspaceProvider).tab(id);
    if (tab == null) return;
    if (tab is RequestTab &&
        tab.isDirty &&
        (tab.isSaved || tab.draft.url.isNotEmpty)) {
      final choice = await unsavedChangesDialog(context, tab.title);
      if (choice == UnsavedChoice.cancel) return;
      if (choice == UnsavedChoice.save && !await save(tab.id)) return;
    }
    _ws.closeTab(tab.id);
  }

  void duplicateTab([String? tabId]) {
    final id = tabId ?? _activeId;
    if (id != null) _ws.duplicateTab(id);
  }

  Future<void> copyAsCurl([String? tabId]) async {
    final id = tabId ?? _activeId;
    final tab = id == null ? null : ref.read(workspaceProvider).tab(id);
    if (tab is! RequestTab) return;
    try {
      final settings = ref.read(settingsProvider).network;
      final prepared = const RequestPreparer().prepare(
        tab.draft,
        ref.read(variableResolverProvider),
        defaults: RequestDefaults(
          timeoutMs: settings.timeoutMs,
          followRedirects: settings.followRedirects,
        ),
      );
      await Clipboard.setData(
        ClipboardData(text: const CurlGenerator().generate(prepared)),
      );
      if (context.mounted) {
        showToast(
          context,
          'cURL command copied (variables resolved, includes credentials)',
        );
      }
    } on AppFailure catch (f) {
      if (context.mounted) showToast(context, f.message, error: true);
    }
  }

  /// Opens a dialog to paste a cURL command and opens it in a new tab.
  Future<void> importCurl() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _CurlImportDialog(),
    );
    if (text == null) return;
    importCurlText(text);
  }

  bool importCurlText(String text, {String? replaceTabId}) {
    try {
      final result = const CurlParser().parse(text);
      if (replaceTabId != null) {
        _ws.updateDraft(
          replaceTabId,
          (d) => result.request.copyWith(
            id: d.id,
            name: d.name,
            collectionId: () => d.collectionId,
            folderId: () => d.folderId,
            sortOrder: d.sortOrder,
            createdAt: d.createdAt,
          ),
        );
      } else {
        _ws.newRequestTab(result.request);
      }
      if (context.mounted) {
        showToast(
          context,
          result.warnings.isEmpty
              ? 'cURL command imported'
              : 'Imported with ${result.warnings.length} ignored option(s): ${result.warnings.first}',
        );
      }
      return true;
    } on CurlParseException catch (e) {
      if (context.mounted) {
        showToast(context, 'Could not parse cURL: ${e.message}', error: true);
      }
      return false;
    }
  }
}

class _CurlImportDialog extends StatefulWidget {
  const _CurlImportDialog();

  @override
  State<_CurlImportDialog> createState() => _CurlImportDialogState();
}

class _CurlImportDialogState extends State<_CurlImportDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      const CurlParser().parse(_controller.text);
      Navigator.pop(context, _controller.text);
    } on CurlParseException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Import cURL'),
    content: SizedBox(
      width: 560,
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 10,
        minLines: 6,
        style: const TextStyle(
          fontFamily: 'SF Mono',
          fontFamilyFallback: ['Menlo', 'Consolas'],
          fontSize: 12.5,
        ),
        decoration: InputDecoration(
          hintText:
              "curl --request GET \\\n  --url https://api.example.com/users \\\n  --header 'Accept: application/json'",
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Import')),
    ],
  );
}
