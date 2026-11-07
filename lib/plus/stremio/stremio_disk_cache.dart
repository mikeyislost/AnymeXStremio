import 'dart:convert';
import 'dart:io';

import 'package:anymex/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One saved value and when it was saved.
class DiskCacheEntry {
  final dynamic value;
  final DateTime savedAt;
  const DiskCacheEntry(this.value, this.savedAt);

  Duration get age => DateTime.now().difference(savedAt);
  bool isFresherThan(Duration d) => age < d;
}

/// AnymeX+: a small JSON cache on the device for Movies & TV data (addon
/// list, library, home rows, title details, anime id matches). Screens show
/// the last saved copy straight away and refresh it in the background, so
/// Movies & TV no longer starts from spinners on every launch.
///
/// One file per key in the app-support folder; values must be JSON.
class StremioDiskCache {
  StremioDiskCache._();

  static Future<Directory>? _dir;

  static Future<Directory> _root() {
    return _dir ??= () async {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'anymexplus_cache'));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }();
  }

  /// Stable short file name for a key (two 32-bit FNV-1a hashes).
  static String fileNameFor(String key) {
    final bytes = utf8.encode(key);
    var a = 0x811c9dc5, b = 0x01000193 ^ 0x5bd1e995;
    for (final c in bytes) {
      a = ((a ^ c) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ c) * 0x01000193 + 0x9e3779b9) & 0xFFFFFFFF;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}'
        '${b.toRadixString(16).padLeft(8, '0')}.json';
  }

  static Future<File> _file(String key) async =>
      File(p.join((await _root()).path, fileNameFor(key)));

  static Future<DiskCacheEntry?> read(String key) async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['k'] != key) return null;
      final t = data['t'];
      if (t is! int) return null;
      return DiskCacheEntry(data['v'], DateTime.fromMillisecondsSinceEpoch(t));
    } catch (e) {
      Logger.i('Disk cache read failed for $key: $e');
      return null;
    }
  }

  static Future<void> write(String key, Object? value) async {
    try {
      final file = await _file(key);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'k': key,
        't': DateTime.now().millisecondsSinceEpoch,
        'v': value,
      }));
      await tmp.rename(file.path);
    } catch (e) {
      Logger.i('Disk cache write failed for $key: $e');
    }
  }

  static Future<void> remove(String key) async {
    try {
      final file = await _file(key);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Drops files older than [maxAge] and keeps at most [maxFiles] (newest).
  static Future<void> prune({
    Duration maxAge = const Duration(days: 30),
    int maxFiles = 1500,
  }) async {
    try {
      final dir = await _root();
      final files = <(File, DateTime)>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        files.add((e, stat.modified));
      }
      files.sort((x, y) => y.$2.compareTo(x.$2));
      final now = DateTime.now();
      for (var i = 0; i < files.length; i++) {
        final (file, modified) = files[i];
        if (i >= maxFiles || now.difference(modified) > maxAge) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      Logger.i('Disk cache prune failed: $e');
    }
  }
}
