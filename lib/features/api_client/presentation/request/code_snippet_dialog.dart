import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/dialogs.dart';
import '../../domain/models/prepared_request.dart';
import '../../domain/services/code_snippet_generator.dart';

/// Language last chosen in the code snippet dialog (kept for the session).
final snippetLanguageProvider =
    NotifierProvider<SnippetLanguageController, SnippetLanguage>(
      SnippetLanguageController.new,
    );

class SnippetLanguageController extends Notifier<SnippetLanguage> {
  @override
  SnippetLanguage build() => SnippetLanguage.curl;

  void select(SnippetLanguage language) => state = language;
}

Future<void> showCodeSnippetDialog(
  BuildContext context,
  PreparedRequest request,
) => showDialog<void>(
  context: context,
  builder: (_) => CodeSnippetDialog(request: request),
);

/// Shows a request as code in several languages, with copy to clipboard.
class CodeSnippetDialog extends ConsumerWidget {
  const CodeSnippetDialog({super.key, required this.request});

  final PreparedRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final language = ref.watch(snippetLanguageProvider);
    final code = const CodeSnippetGenerator().generate(request, language);
    final unresolved = request.unresolvedVariables;

    return Dialog(
      child: SizedBox(
        width: 940,
        height: 600,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 220,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: colors.border)),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 8,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Text(
                      'Code snippet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final l in SnippetLanguage.values)
                    _LanguageItem(
                      language: l,
                      selected: l == language,
                      onTap: () =>
                          ref.read(snippetLanguageProvider.notifier).select(l),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            language.label,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('copy-snippet'),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: code));
                            if (context.mounted) {
                              showToast(context, '${language.label} copied');
                            }
                          },
                          icon: const Icon(Icons.copy, size: 15),
                          label: const Text('Copy'),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    if (unresolved.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Unresolved: ${unresolved.map((n) => '{{$n}}').join(', ')}. '
                          'Select an environment that defines them.',
                          style: TextStyle(fontSize: 12, color: colors.warning),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: colors.canvas,
                          border: Border.all(color: colors.border),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: _CodeBlock(key: ValueKey(language), code: code),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Variables are resolved with the active environment and the '
                      "request's collection, and authorization is included. "
                      'Treat snippets that contain credentials like passwords.',
                      style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageItem extends StatelessWidget {
  const _LanguageItem({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final SnippetLanguage language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      key: ValueKey('snippet-${language.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? colors.selection : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Text(
              language.language,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? colors.accent : colors.textPrimary,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                language.library,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({super.key, required this.code});
  final String code;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scrollbar(
      controller: _vertical,
      child: SingleChildScrollView(
        controller: _vertical,
        padding: const EdgeInsets.all(14),
        child: Scrollbar(
          controller: _horizontal,
          notificationPredicate: (n) => n.depth == 0,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SelectableText.rich(
              TextSpan(children: highlightSnippet(widget.code, colors)),
              style: AppTheme.mono(
                context,
                size: 12.5,
                color: colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _token = RegExp(
  r'("(?:[^"\\\n]|\\.)*"|'
  r"'(?:[^'\\\n]|\\.)*'"
  r'|`[^`]*`)'
  r'|(//[^\n]*|(?<=^|\s)#[^\n]*)'
  r'|\b(\d+(?:\.\d+)?)\b'
  r'|\b(const|let|var|final|await|async|import|from|require|new|return|func|'
  r'package|if|else|try|catch|using|def|true|false|null|nil|None|True|False|'
  r'void|public|class|defer|echo|print|println)\b',
  multiLine: true,
);

/// Lightweight, language-agnostic colouring for generated snippets.
List<TextSpan> highlightSnippet(String code, VesperColors colors) {
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in _token.allMatches(code)) {
    if (m.start > last) {
      spans.add(TextSpan(text: code.substring(last, m.start)));
    }
    final color = m.group(1) != null
        ? colors.syntaxString
        : m.group(2) != null
        ? colors.textMuted
        : m.group(3) != null
        ? colors.syntaxNumber
        : colors.syntaxKey;
    spans.add(
      TextSpan(
        text: m.group(0),
        style: TextStyle(color: color),
      ),
    );
    last = m.end;
  }
  if (last < code.length) spans.add(TextSpan(text: code.substring(last)));
  return spans;
}
