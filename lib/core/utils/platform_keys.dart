import 'dart:io';

/// Human readable shortcut labels for the current platform.
class PlatformKeys {
  const PlatformKeys._();

  static bool get isMac => Platform.isMacOS;
  static String get mod => isMac ? '⌘' : 'Ctrl';
  static String get shift => isMac ? '⇧' : 'Shift';
  static String get enter => isMac ? '↵' : 'Enter';
  static String combo(String key, {bool shift = false}) => isMac
      ? '$mod${shift ? PlatformKeys.shift : ''}$key'
      : '$mod+${shift ? '${PlatformKeys.shift}+' : ''}$key';
}
