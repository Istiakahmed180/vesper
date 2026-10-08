import 'package:flutter/material.dart';

/// Semantic palette exposed as a [ThemeExtension] so widgets never hardcode
/// colours and both themes stay consistent.
@immutable
class VesperColors extends ThemeExtension<VesperColors> {
  const VesperColors({
    required this.canvas,
    required this.sidebar,
    required this.panel,
    required this.panelRaised,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentMuted,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.selection,
    required this.hover,
    required this.methodGet,
    required this.methodPost,
    required this.methodPut,
    required this.methodPatch,
    required this.methodDelete,
    required this.methodHead,
    required this.methodOptions,
    required this.syntaxKey,
    required this.syntaxString,
    required this.syntaxNumber,
    required this.syntaxBool,
    required this.syntaxNull,
    required this.syntaxPunctuation,
    required this.variable,
    required this.variableUnresolved,
    required this.searchHighlight,
  });

  final Color canvas;
  final Color sidebar;
  final Color panel;
  final Color panelRaised;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentMuted;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color selection;
  final Color hover;
  final Color methodGet;
  final Color methodPost;
  final Color methodPut;
  final Color methodPatch;
  final Color methodDelete;
  final Color methodHead;
  final Color methodOptions;
  final Color syntaxKey;
  final Color syntaxString;
  final Color syntaxNumber;
  final Color syntaxBool;
  final Color syntaxNull;
  final Color syntaxPunctuation;
  final Color variable;
  final Color variableUnresolved;
  final Color searchHighlight;

  static const dark = VesperColors(
    canvas: Color(0xFF15171C),
    sidebar: Color(0xFF191B21),
    panel: Color(0xFF1D2027),
    panelRaised: Color(0xFF242832),
    border: Color(0xFF2A2E38),
    borderStrong: Color(0xFF383D4A),
    textPrimary: Color(0xFFE6E8EE),
    textSecondary: Color(0xFFA9AEBC),
    textMuted: Color(0xFF6E7485),
    accent: Color(0xFF8B7CF6),
    accentMuted: Color(0xFF2E2950),
    success: Color(0xFF4CC38A),
    warning: Color(0xFFE5B65C),
    danger: Color(0xFFF0707A),
    info: Color(0xFF5EB1EF),
    selection: Color(0xFF2B2F3B),
    hover: Color(0xFF23262F),
    methodGet: Color(0xFF4CC38A),
    methodPost: Color(0xFFE5B65C),
    methodPut: Color(0xFF5EB1EF),
    methodPatch: Color(0xFFB79CF7),
    methodDelete: Color(0xFFF0707A),
    methodHead: Color(0xFF4FC4CF),
    methodOptions: Color(0xFFE38BC4),
    syntaxKey: Color(0xFF9DB8F5),
    syntaxString: Color(0xFF9FD49A),
    syntaxNumber: Color(0xFFF2AE72),
    syntaxBool: Color(0xFFC79BF2),
    syntaxNull: Color(0xFF8A90A0),
    syntaxPunctuation: Color(0xFF8A90A0),
    variable: Color(0xFF7FD3C6),
    variableUnresolved: Color(0xFFF0707A),
    searchHighlight: Color(0x66E5B65C),
  );

  static const light = VesperColors(
    canvas: Color(0xFFF6F7F9),
    sidebar: Color(0xFFEFF1F4),
    panel: Color(0xFFFFFFFF),
    panelRaised: Color(0xFFF3F4F7),
    border: Color(0xFFE0E3E9),
    borderStrong: Color(0xFFC9CED8),
    textPrimary: Color(0xFF1C1F26),
    textSecondary: Color(0xFF4F5566),
    textMuted: Color(0xFF8A90A0),
    accent: Color(0xFF6A58E8),
    accentMuted: Color(0xFFE7E3FD),
    success: Color(0xFF1E9E63),
    warning: Color(0xFFB7801B),
    danger: Color(0xFFD23F4B),
    info: Color(0xFF2B7BC0),
    selection: Color(0xFFE6E8F0),
    hover: Color(0xFFEDEFF3),
    methodGet: Color(0xFF1E9E63),
    methodPost: Color(0xFFB7801B),
    methodPut: Color(0xFF2B7BC0),
    methodPatch: Color(0xFF7A55D6),
    methodDelete: Color(0xFFD23F4B),
    methodHead: Color(0xFF168C96),
    methodOptions: Color(0xFFB8418C),
    syntaxKey: Color(0xFF2F5BB8),
    syntaxString: Color(0xFF2E7D32),
    syntaxNumber: Color(0xFFB45309),
    syntaxBool: Color(0xFF7A3EC2),
    syntaxNull: Color(0xFF6B7280),
    syntaxPunctuation: Color(0xFF6B7280),
    variable: Color(0xFF0F8A7A),
    variableUnresolved: Color(0xFFD23F4B),
    searchHighlight: Color(0x66F2C14E),
  );

  @override
  VesperColors copyWith() => this;

  @override
  VesperColors lerp(ThemeExtension<VesperColors>? other, double t) {
    if (other is! VesperColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return VesperColors(
      canvas: l(canvas, other.canvas),
      sidebar: l(sidebar, other.sidebar),
      panel: l(panel, other.panel),
      panelRaised: l(panelRaised, other.panelRaised),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      accent: l(accent, other.accent),
      accentMuted: l(accentMuted, other.accentMuted),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      info: l(info, other.info),
      selection: l(selection, other.selection),
      hover: l(hover, other.hover),
      methodGet: l(methodGet, other.methodGet),
      methodPost: l(methodPost, other.methodPost),
      methodPut: l(methodPut, other.methodPut),
      methodPatch: l(methodPatch, other.methodPatch),
      methodDelete: l(methodDelete, other.methodDelete),
      methodHead: l(methodHead, other.methodHead),
      methodOptions: l(methodOptions, other.methodOptions),
      syntaxKey: l(syntaxKey, other.syntaxKey),
      syntaxString: l(syntaxString, other.syntaxString),
      syntaxNumber: l(syntaxNumber, other.syntaxNumber),
      syntaxBool: l(syntaxBool, other.syntaxBool),
      syntaxNull: l(syntaxNull, other.syntaxNull),
      syntaxPunctuation: l(syntaxPunctuation, other.syntaxPunctuation),
      variable: l(variable, other.variable),
      variableUnresolved: l(variableUnresolved, other.variableUnresolved),
      searchHighlight: l(searchHighlight, other.searchHighlight),
    );
  }

  Color statusColor(int? status) {
    if (status == null) return danger;
    if (status >= 500) return danger;
    if (status >= 400) return warning;
    if (status >= 300) return info;
    if (status >= 200) return success;
    return textSecondary;
  }
}

extension VesperColorsContext on BuildContext {
  VesperColors get colors => Theme.of(this).extension<VesperColors>()!;
}
