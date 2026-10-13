import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesper/core/theme/app_theme.dart';
import 'package:vesper/features/api_client/presentation/response/body_formatter.dart';
import 'package:vesper/shared/widgets/code/code_view.dart';

void main() {
  final primary = Platform.isMacOS
      ? LogicalKeyboardKey.meta
      : LogicalKeyboardKey.control;

  late String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  // 300 items: far more lines than fit on screen.
  final json = jsonEncode({
    'items': [
      for (var i = 0; i < 300; i++) {'id': i, 'name': 'item $i'},
    ],
  });

  Future<CodeViewController> pump(WidgetTester tester) async {
    final controller = CodeViewController(formatText(json, CodeLanguage.json));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 400,
            child: CodeView(controller: controller),
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(primary);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(primary);
    await tester.pump();
  }

  testWidgets('select all and copy cover lines that are not on screen', (
    tester,
  ) async {
    final controller = await pump(tester);
    final body = controller.body;
    expect(body.lines.length, greaterThan(1000));

    await tester.tapAt(
      tester.getTopLeft(find.byType(CodeView)) + const Offset(120, 30),
    );
    await tester.pump();
    expect(controller.caret, isNotNull);

    await shortcut(tester, LogicalKeyboardKey.keyA);
    expect(controller.selectedText, body.text);

    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, body.text);
    expect(jsonDecode(clipboard!), jsonDecode(json));

    // Folded lines are still part of the selection.
    controller.collapseAll();
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyA);
    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, body.text);
  });

  testWidgets('click places the caret, shift+arrows and drag select', (
    tester,
  ) async {
    final controller = await pump(tester);
    final origin = tester.getTopLeft(find.byType(CodeView));
    final lineHeight = (12.5 * 1.6).roundToDouble();

    // Second line is `  "items": [`; click near its start.
    await tester.tapAt(origin + Offset(200, 6 + lineHeight * 1.5));
    await tester.pump();
    final caret = controller.caret!;
    expect(caret.line, 1);
    expect(controller.hasSelection, isFalse);

    controller.moveCaret(const CodePosition(1, 2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(controller.selectedText, '"items"');

    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, '"items"');

    // Dragging across lines selects them.
    final gesture = await tester.startGesture(
      origin + Offset(200, 6 + lineHeight * 2.5),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(origin + Offset(200, 6 + lineHeight * 5.5));
    await gesture.up();
    await tester.pump();
    final range = controller.selection!;
    expect(range.$1.line, 2);
    expect(range.$2.line, 5);
    expect(controller.selectedText.split('\n'), hasLength(4));
  });
}
