import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/section_tabs.dart';
import '../domain/github_models.dart';
import 'github_providers.dart';

/// Lists the user's repositories and lets them choose a sync target.
class RepoPicker extends ConsumerStatefulWidget {
  const RepoPicker({super.key, required this.onSelected, this.initial});

  final ValueChanged<SyncTarget> onSelected;
  final SyncTarget? initial;

  @override
  ConsumerState<RepoPicker> createState() => _RepoPickerState();
}

class _RepoPickerState extends ConsumerState<RepoPicker> {
  String _query = '';
  GitHubRepo? _selected;
  late final _branch = TextEditingController(
    text: widget.initial?.branch ?? '',
  );
  late final _path = TextEditingController(
    text: widget.initial?.basePath ?? 'api-client',
  );

  @override
  void dispose() {
    _branch.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final repos = ref.watch(githubReposProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: 'Search repositories',
            prefixIcon: Icon(Icons.search, size: 16),
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 260,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: repos.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline,
                title: 'Could not load repositories',
                message: e.userMessage,
                action: TextButton(
                  onPressed: () => ref.invalidate(githubReposProvider),
                  child: const Text('Retry'),
                ),
              ),
              data: (list) {
                final filtered = list
                    .where(
                      (r) =>
                          _query.isEmpty ||
                          r.fullName.toLowerCase().contains(_query),
                    )
                    .toList();
                if (filtered.isEmpty) {
                  return const EmptyState(
                    icon: Icons.search_off,
                    title: 'No repositories',
                  );
                }
                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final r = filtered[i];
                    final selected =
                        _selected?.fullName == r.fullName ||
                        (_selected == null &&
                            widget.initial?.repo == r.fullName);
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor: colors.selection,
                      leading: Icon(
                        r.isPrivate ? Icons.lock_outline : Icons.public,
                        size: 16,
                      ),
                      title: Text(
                        r.fullName,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        [
                          if (!r.canPush) 'read-only',
                          'default: ${r.defaultBranch}',
                          if (r.updatedAt != null)
                            'updated ${Formatters.relativeTime(r.updatedAt!)}',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: r.canPush ? colors.textMuted : colors.warning,
                        ),
                      ),
                      onTap: () => setState(() {
                        _selected = r;
                        _branch.text = r.defaultBranch;
                      }),
                    );
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _branch,
                decoration: const InputDecoration(labelText: 'Branch'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: 'Folder in repository',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _selected == null && widget.initial == null
                ? null
                : () {
                    final repo = _selected?.fullName ?? widget.initial!.repo;
                    final path = _path.text.trim().replaceAll(
                      RegExp(r'^/+|/+$'),
                      '',
                    );
                    widget.onSelected(
                      SyncTarget(
                        repo: repo,
                        branch: _branch.text.trim().isEmpty
                            ? (_selected?.defaultBranch ?? 'main')
                            : _branch.text.trim(),
                        basePath: path.isEmpty ? 'api-client' : path,
                      ),
                    );
                  },
            child: const Text('Use this repository'),
          ),
        ),
      ],
    );
  }
}
