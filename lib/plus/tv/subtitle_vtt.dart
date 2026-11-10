/// AnymeX+: turns a subtitle file (WebVTT, SRT or ASS/SSA) into WebVTT text,
/// the one format the TV app reads. ASS styling (fonts, colours, positions)
/// is dropped; the lines and their timing are kept.
String plusSubtitleToVtt(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.startsWith('﻿')) text = text.substring(1).trim();
  if (text.startsWith('WEBVTT')) return text;
  if (text.contains('[Events]') || RegExp(r'^Dialogue:', multiLine: true).hasMatch(text)) {
    return _assToVtt(text);
  }
  // SRT: the same cues with a comma in the times.
  final time = RegExp(r'(\d{1,2}:\d{2}:\d{2}),(\d{1,3})');
  final body = text.split('\n').map((l) {
    return l.contains('-->') ? l.replaceAllMapped(time, (m) => '${m[1]}.${m[2]!.padRight(3, '0')}') : l;
  }).join('\n');
  return 'WEBVTT\n\n$body';
}

String _assToVtt(String text) {
  // The "Format:" line of [Events] says where each field is.
  var fields = const ['layer', 'start', 'end', 'style', 'name', 'marginl', 'marginr', 'marginv', 'effect', 'text'];
  final cues = <(int, int, String)>[];
  var inEvents = false;
  for (final line in text.split('\n')) {
    final l = line.trim();
    if (l.startsWith('[')) {
      inEvents = l.toLowerCase() == '[events]';
      continue;
    }
    if (inEvents && l.startsWith('Format:')) {
      fields = l.substring(7).split(',').map((f) => f.trim().toLowerCase()).toList();
      continue;
    }
    if (!l.startsWith('Dialogue:')) continue;
    final parts = l.substring(9).split(',');
    final iText = fields.indexOf('text');
    final iStart = fields.indexOf('start');
    final iEnd = fields.indexOf('end');
    if (iText < 0 || iStart < 0 || iEnd < 0 || parts.length <= iText) continue;
    final start = _assTime(parts[iStart]);
    final end = _assTime(parts[iEnd]);
    if (start == null || end == null || end <= start) continue;
    var t = parts.sublist(iText).join(',');
    // Drawings (vector shapes) are not text.
    if (RegExp(r'\{[^}]*\\p[1-9]').hasMatch(t)) continue;
    t = t
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .replaceAll(RegExp(r'\\[Nn]'), '\n')
        .replaceAll(r'\h', ' ')
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('\n');
    if (t.isEmpty) continue;
    cues.add((start, end, t));
  }
  cues.sort((a, b) => a.$1.compareTo(b.$1));
  final b = StringBuffer('WEBVTT\n');
  for (final (start, end, t) in cues) {
    b.write('\n${_vttTime(start)} --> ${_vttTime(end)}\n$t\n');
  }
  return b.toString().trim();
}

/// "0:01:02.34" → milliseconds.
int? _assTime(String s) {
  final m = RegExp(r'^\s*(\d+):(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\s*$').firstMatch(s);
  if (m == null) return null;
  final frac = (m[4] ?? '0').padRight(3, '0');
  return int.parse(m[1]!) * 3600000 + int.parse(m[2]!) * 60000 + int.parse(m[3]!) * 1000 + int.parse(frac);
}

String _vttTime(int ms) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}.${(ms % 1000).toString().padLeft(3, '0')}';
}
