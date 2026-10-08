class Formatters {
  const Formatters._();

  static String bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : (value >= 10 ? 1 : 2))} ${units[unit]}';
  }

  static String duration(Duration d) {
    final ms = d.inMicroseconds / 1000;
    if (ms < 1000) return '${ms.round()} ms';
    final s = ms / 1000;
    if (s < 60) return '${s.toStringAsFixed(2)} s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  static String relativeTime(DateTime time, {DateTime? now}) {
    final diff = (now ?? DateTime.now()).difference(time);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return dateTime(time);
  }

  static String dateTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  static String slug(String input) {
    final s = input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'untitled' : s;
  }
}
