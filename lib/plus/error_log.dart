// AnymeX+: the last 50 errors, kept on the device (a small file in the
// app's support folder) and shown in the Self Test, ready to copy and send.
// Fed by Logger.e, so it catches crashes, Flutter errors and logged
// failures alike. It never logs its own failures (that would loop).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

class PlusErrorEntry {
  final DateTime time;
  String message;

  PlusErrorEntry(this.time, this.message);

  Map<String, dynamic> toJson() =>
      {'t': time.toIso8601String(), 'm': message};

  static PlusErrorEntry? fromJson(dynamic j) {
    if (j is! Map) return null;
    final t = DateTime.tryParse('${j['t']}');
    if (t == null) return null;
    return PlusErrorEntry(t, '${j['m'] ?? ''}');
  }
}

class PlusErrorLog {
  PlusErrorLog._();

  static const max = 50;
  static const _maxChars = 1500;
  static final RxList<PlusErrorEntry> entries = <PlusErrorEntry>[].obs;

  static bool _loaded = false;
  static bool _busy = false;
  static Timer? _saveTimer;

  /// Adds an error (newest last). A "STACK: …" line right after an error
  /// is joined to it.
  static void add(String message, {Object? error, DateTime? now}) {
    if (_busy) return;
    _busy = true;
    try {
      final at = now ?? DateTime.now();
      var text = redact(error == null ? message : '$message\n$error');
      if (text.length > _maxChars) text = '${text.substring(0, _maxChars)}…';
      final last = entries.isEmpty ? null : entries.last;
      if (last != null &&
          text.startsWith('STACK:') &&
          at.difference(last.time).inSeconds.abs() <= 2) {
        last.message = _trim('${last.message}\n$text');
        entries.refresh();
      } else {
        entries.add(PlusErrorEntry(at, text));
        if (entries.length > max) {
          entries.removeRange(0, entries.length - max);
        }
      }
      _scheduleSave();
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  /// Keys and tokens in URLs or headers are blanked out.
  static String redact(String s) => s
      .replaceAllMapped(
          RegExp(r'((?:api_?key|access_token|refresh_token|token|authKey|key|password)=)[^&\s"]+',
              caseSensitive: false),
          (m) => '${m[1]}…')
      .replaceAllMapped(RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]+'), (m) => '${m[1]}…')
      // Long secrets in addon URLs (e.g. a debrid key in Torrentio's path).
      .replaceAll(RegExp(r'(?<==)[A-Za-z0-9_\-]{24,}'), '…');

  static String _trim(String s) =>
      s.length > _maxChars * 2 ? '${s.substring(0, _maxChars * 2)}…' : s;

  /// Loads the saved errors (once), keeping any added since launch.
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString());
      if (list is! List) return;
      final saved =
          list.map(PlusErrorEntry.fromJson).whereType<PlusErrorEntry>();
      final merged = [...saved, ...entries];
      entries.assignAll(merged.length > max
          ? merged.sublist(merged.length - max)
          : merged);
    } catch (_) {}
  }

  static Future<void> clear() async {
    entries.clear();
    _loaded = true;
    await _save();
  }

  /// Plain text for copying, newest first.
  static String report() {
    final b = StringBuffer('AnymeX+ recent errors (${entries.length})\n');
    for (final e in entries.reversed) {
      b
        ..writeln()
        ..writeln('[${e.time.toLocal().toIso8601String().substring(0, 19)}]')
        ..writeln(e.message);
    }
    return b.toString();
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      await ensureLoaded();
      await _save();
    });
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(
          jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/anymexplus_errors.json');
  }
}
