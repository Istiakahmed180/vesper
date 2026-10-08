import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vesper/app.dart';
import 'package:vesper/core/security/secret_vault.dart';
import 'package:vesper/features/api_client/domain/models/api_response.dart';
import 'package:vesper/features/api_client/presentation/request/request_editor.dart';
import 'package:vesper/features/api_client/presentation/request/url_bar.dart';
import 'package:vesper/features/api_client/presentation/response/response_panel.dart';
import 'package:vesper/features/settings/domain/app_settings.dart';
import 'package:vesper/features/settings/presentation/settings_controller.dart';
import 'package:vesper/features/workspace/domain/workspace_models.dart';
import 'package:vesper/features/workspace/presentation/response_controller.dart';
import 'package:vesper/features/workspace/presentation/workspace_controller.dart';

/// Helpers for the macOS verification suites. They drive the real UI of the
/// app built from `bootstrap()` (real SQLite file, real Keychain).
class Harness {
  Harness(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;
  static final boundary = GlobalKey();
  static const shotDir = String.fromEnvironment('SHOT_DIR');
  static final results = <String>[];

  static void record(String name, {String detail = ''}) {
    final line = 'CHECK PASS  $name${detail.isEmpty ? '' : ' — $detail'}';
    results.add(line);
    // ignore: avoid_print
    print(line);
  }

  static Widget wrap(ProviderContainer c) => UncontrolledProviderScope(
    container: c,
    child: RepaintBoundary(key: boundary, child: const VesperApp()),
  );

  Future<void> shot(String name) async {
    if (shotDir.isEmpty) return;
    await tester.pump(const Duration(milliseconds: 150));
    final ro = boundary.currentContext!.findRenderObject()!;
    final image = await (ro as RenderRepaintBoundary).toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    final file = safe.length > 80 ? safe.substring(0, 80) : safe;
    await File('$shotDir/$file.png').writeAsBytes(bytes!.buffer.asUint8List());
  }

  Future<void> pumpFor(Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
    String? what,
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
      if (condition()) return;
    }
    await shot('timeout_${what ?? 'condition'}');
    throw TestFailure('Timed out waiting for ${what ?? 'condition'}');
  }

  Future<void> untilFound(
    Finder f, {
    Duration timeout = const Duration(seconds: 20),
  }) => until(
    () => f.evaluate().isNotEmpty,
    timeout: timeout,
    what: f.toString(),
  );

  Future<void> tap(Finder f, {int buttons = 1}) async {
    await untilFound(f);
    await tester.tap(f.first, buttons: buttons);
    await tester.pump(const Duration(milliseconds: 120));
  }

  Future<void> rightClick(Finder f) => tap(f, buttons: 2);

  /// The topmost (then leftmost) on-screen element matched by [f] — what a
  /// person means by "the first field".
  Element topmost(Finder f) {
    final elements = f.evaluate().toList()
      ..sort((a, b) {
        final pa = (a.renderObject! as RenderBox).localToGlobal(Offset.zero);
        final pb = (b.renderObject! as RenderBox).localToGlobal(Offset.zero);
        final dy = pa.dy.compareTo(pb.dy);
        return dy != 0 ? dy : pa.dx.compareTo(pb.dx);
      });
    return elements.first;
  }

  /// Types like a user: clicks the topmost matching field, then delivers the
  /// text through the same EditableText path the macOS text input uses.
  Future<void> type(Finder field, String text) async {
    await untilFound(field);
    final target = topmost(field);
    final box = target.renderObject! as RenderBox;
    await tester.tapAt(box.localToGlobal(box.size.center(Offset.zero)));
    await tester.pump();
    final editable = find.descendant(
      of: find.byElementPredicate((e) => identical(e, target)),
      matching: find.byType(EditableText),
    );
    tester
        .state<EditableTextState>(editable.first)
        .userUpdateTextEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
          SelectionChangedCause.keyboard,
        );
    await tester.pump(const Duration(milliseconds: 120));
  }

  /// An *empty* text field showing [hint] as its placeholder. (Flutter keeps
  /// the hint widget in the tree, invisible, once a field has text.)
  Finder fieldWithHint(String hint, {Finder? within}) {
    final f = find.byElementPredicate((e) {
      final w = e.widget;
      if (w is! TextField || w.decoration?.hintText != hint) return false;
      var text = '';
      void visit(Element c) {
        final cw = c.widget;
        if (cw is EditableText) {
          text = cw.controller.text;
        } else {
          c.visitChildElements(visit);
        }
      }

      e.visitChildElements(visit);
      return text.isEmpty;
    });
    return within == null ? f : find.descendant(of: within, matching: f);
  }

  Finder inWidget<T>(Finder f) =>
      find.descendant(of: find.byType(T), matching: f);
  Finder dialogText(String text) =>
      find.descendant(of: find.byType(Dialog), matching: find.text(text));
  Finder menuItem(String label) => find.widgetWithText(MenuItemButton, label);

  // ----------------------------------------------------------- workspace

  WorkspaceState get ws => container.read(workspaceProvider);
  String get tabId => ws.activeTab!.id;
  RequestTab get tab => ws.activeTab! as RequestTab;
  ResponseState get response => container.read(responseProvider(tabId));
  AppSettings get settings => container.read(settingsProvider);

  Finder get urlField => find.descendant(
    of: find.byType(UrlBar),
    matching: find.byType(TextField),
  );

  Future<void> setUrl(String url) => type(urlField, url);

  Future<void> newTab() async {
    final before = ws.tabs.length;
    await tap(find.byTooltip('New tab (⌘T)'));
    await until(() => ws.tabs.length == before + 1, what: 'new tab');
  }

  Future<void> chooseMethod(String method) async {
    await tap(
      find.descendant(of: find.byType(UrlBar), matching: find.byType(InkWell)),
    );
    await tap(menuItem(method));
  }

  Future<void> requestSection(String name) => tap(
    find.descendant(of: find.byType(RequestEditor), matching: find.text(name)),
  );

  Future<void> responseSection(String name) => tap(
    find.descendant(of: find.byType(ResponsePanel), matching: find.text(name)),
  );

  /// Taps Send and waits for a terminal response state.
  Future<ResponseState> send({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = tabId;
    await tap(
      find.descendant(of: find.byType(UrlBar), matching: find.text('Send')),
    );
    await until(
      () =>
          container.read(responseProvider(id)) is! ResponseLoading &&
          container.read(responseProvider(id)) is! ResponseIdle,
      timeout: timeout,
      what: 'response',
    );
    await tester.pump(const Duration(milliseconds: 200));
    return container.read(responseProvider(id));
  }

  ApiResponse get success {
    final r = response;
    if (r is! ResponseSuccess) {
      throw TestFailure(
        'Expected a response but got $r '
        '${r is ResponseFailure ? r.failure.message : ''}',
      );
    }
    return r.response;
  }

  Map<String, Object?> get echo =>
      (jsonDecode(success.bodyText) as Map).cast<String, Object?>();

  Map<String, Object?> get echoHeaders =>
      (echo['headers']! as Map).cast<String, Object?>();

  String get failureMessage => (response as ResponseFailure).failure.message;

  // ----------------------------------------------------------- storage

  static Future<Directory> supportDir() => getApplicationSupportDirectory();

  /// Every byte Vesper persisted on disk (database incl. WAL, logs).
  static Future<List<int>> persistedBytes() async {
    final dir = await supportDir();
    final out = <int>[];
    for (final name in [
      'vesper.sqlite',
      'vesper.sqlite-wal',
      'vesper.sqlite-journal',
    ]) {
      final f = File(p.join(dir.path, name));
      if (f.existsSync()) out.addAll(f.readAsBytesSync());
    }
    final logs = Directory(p.join(dir.path, 'logs'));
    if (logs.existsSync()) {
      for (final f in logs.listSync().whereType<File>()) {
        out.addAll(f.readAsBytesSync());
      }
    }
    return out;
  }

  static bool bytesContain(List<int> haystack, String needle) {
    final n = utf8.encode(needle);
    outer:
    for (var i = 0; i <= haystack.length - n.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (haystack[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Whether the macOS Keychain holds an item for [key] (checked with the
  /// `security` tool; values are not read, so no access prompt appears).
  static Future<bool> keychainHas(String key) async {
    final r = await Process.run('security', [
      'find-generic-password',
      '-s',
      'co.tdevs.vesper',
      '-a',
      key,
    ]);
    return r.exitCode == 0;
  }

  static Future<List<String>> keychainVesperKeys(SecretVault vault) async =>
      (await vault.readAll()).keys.toList();
}
