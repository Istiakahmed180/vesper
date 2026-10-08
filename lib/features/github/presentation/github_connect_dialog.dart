import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../domain/github_models.dart';
import 'github_providers.dart';

/// Runs the GitHub Device Flow: shows the one-time code, opens github.com and
/// waits for the user to authorize. Returns true when connected.
Future<bool> showGitHubConnectDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _GitHubConnectDialog(),
    ) ??
    false;

class _GitHubConnectDialog extends ConsumerStatefulWidget {
  const _GitHubConnectDialog();

  @override
  ConsumerState<_GitHubConnectDialog> createState() =>
      _GitHubConnectDialogState();
}

class _GitHubConnectDialogState extends ConsumerState<_GitHubConnectDialog> {
  DeviceCode? _code;
  String? _error;
  final _cancel = Completer<void>();

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    if (!_cancel.isCompleted) _cancel.complete();
    super.dispose();
  }

  Future<void> _start() async {
    final controller = ref.read(githubSessionProvider.notifier);
    try {
      final code = await controller.startConnect();
      if (!mounted) return;
      setState(() => _code = code);
      await controller.completeConnect(code, cancelled: _cancel.future);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      if (e is AuthFailure && e.kind == AuthFailureKind.cancelled) return;
      setState(() => _error = e.userMessage);
    }
  }

  Future<void> _openGitHub() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code.userCode));
    await launchUrl(
      Uri.parse(code.verificationUri),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final code = _code;
    return AlertDialog(
      title: const Text('Connect GitHub'),
      content: SizedBox(
        width: 420,
        child: _error != null
            ? Text(
                _error!,
                style: TextStyle(color: colors.danger, fontSize: 13),
              )
            : code == null
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Enter this code on GitHub to authorize Vesper:',
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    code.userCode,
                    style: AppTheme.mono(
                      context,
                      size: 28,
                    ).copyWith(letterSpacing: 4, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _openGitHub,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Copy code and open GitHub'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Waiting for authorization…',
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (!_cancel.isCompleted) _cancel.complete();
            Navigator.pop(context, false);
          },
          child: Text(_error != null ? 'Close' : 'Cancel'),
        ),
      ],
    );
  }
}
