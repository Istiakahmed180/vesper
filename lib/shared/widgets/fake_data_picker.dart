import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../features/api_client/domain/services/fake_data.dart';

/// Small dice button that lets the user pick a fake-data variable and hands
/// back its `{{$name}}` token.
class FakeDataButton extends StatelessWidget {
  const FakeDataButton({super.key, required this.onPicked});

  /// Receives the token to insert, e.g. `{{$randomEmail}}`.
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 28,
    height: 28,
    child: IconButton(
      key: const ValueKey('fake-data-button'),
      tooltip: 'Insert fake data',
      padding: EdgeInsets.zero,
      iconSize: 15,
      color: context.colors.textMuted,
      onPressed: () async {
        final name = await showFakeDataPicker(context);
        if (name != null) onPicked('{{$name}}');
      },
      icon: const Icon(Icons.casino_outlined),
    ),
  );
}

/// Lists the fake-data variables by category with a sample of each. Returns
/// the chosen variable name (with `$`), or null.
Future<String?> showFakeDataPicker(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _FakeDataPicker(),
);

class _FakeDataPicker extends StatefulWidget {
  const _FakeDataPicker();

  @override
  State<_FakeDataPicker> createState() => _FakeDataPickerState();
}

class _FakeDataPickerState extends State<_FakeDataPicker> {
  final _search = TextEditingController();
  final _fake = FakeData();
  late Map<String, String> _samples = _sample();

  Map<String, String> _sample() => {
    for (final v in FakeData.variables) v.name: v.generate(_fake),
  };

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = AppTheme.mono(context, size: 12.5, color: colors.variable);
    final q = _search.text.trim().toLowerCase();
    bool matches(FakeVariable v) =>
        q.isEmpty ||
        v.name.toLowerCase().contains(q) ||
        v.description.toLowerCase().contains(q) ||
        v.category.toLowerCase().contains(q);

    final rows = <Widget>[];
    for (final category in FakeData.categories) {
      final vars = FakeData.variables
          .where((v) => v.category == category && matches(v))
          .toList();
      if (vars.isEmpty) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Text(
            category.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      );
      for (final v in vars) {
        rows.add(
          InkWell(
            key: ValueKey('fake-${v.name}'),
            borderRadius: BorderRadius.circular(5),
            onTap: () => Navigator.pop(context, v.name),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 190,
                    child: Text(
                      v.name,
                      overflow: TextOverflow.ellipsis,
                      style: mono,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          v.description,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        Text(
                          _samples[v.name] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return AlertDialog(
      title: const Text('Insert fake data'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('fake-data-search'),
                    controller: _search,
                    autofocus: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 16),
                      hintText: 'Search (email, city, price…)',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'New samples',
                  iconSize: 16,
                  onPressed: () => setState(() => _samples = _sample()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        'No matches',
                        style: TextStyle(color: colors.textMuted),
                      ),
                    )
                  : ListView(children: rows),
            ),
            const SizedBox(height: 8),
            Text(
              'A new value is generated every time the request is sent.',
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
