import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anymex/plus/tv/subtitle_vtt.dart';
import 'package:http/http.dart' as http;

/// AnymeX+: lets the TV app play video links that only work with special
/// headers (Referer, User-Agent…), as anime extensions give them.
///
/// The TV's player can't send headers, so it asks this device instead:
/// `http://<this device>:<port>/x/<key>/v.<ext>`. This device fetches the
/// real link with the right headers and passes it on. For HLS the playlists
/// are rewritten so that every playlist, segment, key and init part inside
/// them comes through here too (the first proxy, for casting, only knew
/// master playlists: a media playlist given straight away had its segments
/// treated as playlists, which the TV can't play — "format not supported").
///
/// Segments are also tidied: some sites hide TS video behind a few bytes of
/// a picture so it looks like an image. mpv looks past that; the TV doesn't,
/// so those bytes are cut off.
class PlusTvProxy {
  PlusTvProxy._();
  static final instance = PlusTvProxy._();

  static const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36';

  final _entries = <String, _Entry>{};
  final _client = http.Client();

  /// Where the TV reaches this device (set by the link).
  String Function() base = () => '';

  /// Makes a key for [url] with [headers]; the same link gets the same key.
  String register(String url, Map<String, String>? headers) {
    for (final e in _entries.entries) {
      if (e.value.url == url && _sameHeaders(e.value.headers, headers)) {
        e.value.at = DateTime.now();
        return e.key;
      }
    }
    final r = Random.secure();
    final key = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _entries[key] = _Entry(url, {...?headers});
    // Keep the newest 200.
    if (_entries.length > 200) {
      final old = _entries.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in old.take(_entries.length - 200)) {
        _entries.remove(e.key);
      }
    }
    return key;
  }

  static bool _sameHeaders(Map<String, String> a, Map<String, String>? b) {
    final bb = b ?? const {};
    if (a.length != bb.length) return false;
    for (final k in a.keys) {
      if (a[k] != bb[k]) return false;
    }
    return true;
  }

  /// The address the TV plays for [key] (a video of [kind]).
  String videoUrl(String key, String kind) => '${base()}/x/$key/v.${extFor(kind)}';

  /// The address the TV reads a subtitle file from (as WebVTT).
  String subtitleUrl(String key, String url) => '${base()}/x/$key/sub.vtt?u=${enc(url)}';

  static String extFor(String kind) => switch (kind) {
        'hls' => 'm3u8',
        'mkv' => 'mkv',
        'webm' => 'webm',
        'ts' => 'ts',
        _ => 'mp4',
      };

  static String enc(String url) => base64Url.encode(utf8.encode(url)).replaceAll('=', '');

  static String dec(String s) {
    var t = s;
    while (t.length % 4 != 0) {
      t += '=';
    }
    return utf8.decode(base64Url.decode(t));
  }

  Map<String, String> _headersFor(_Entry e) {
    final h = <String, String>{...e.headers};
    if (!h.keys.any((k) => k.toLowerCase() == 'user-agent')) h['User-Agent'] = ua;
    return h;
  }

  // ---- what kind of video a link is ----------------------------------------

  /// Looks at the first bytes of a link: hls, mkv, webm, mp4, ts, or '' when
  /// it can't tell. [ok] is false when the link doesn't answer.
  Future<({String kind, bool ok})> probe(String url, Map<String, String>? headers) async {
    final e = _Entry(url, {...?headers});
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(_headersFor(e))
        ..headers['Range'] = 'bytes=0-4095';
      final resp = await _client.send(req).timeout(const Duration(seconds: 8));
      if (resp.statusCode >= 400) {
        unawaited(resp.stream.drain<void>().catchError((_) {}));
        return (kind: guessFromUrl(url), ok: false);
      }
      final bytes = <int>[];
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = resp.stream.listen((c) {
        bytes.addAll(c);
        if (bytes.length >= 4096 && !done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 6), onTimeout: () {});
      unawaited(sub.cancel());
      final k = sniff(Uint8List.fromList(bytes), resp.headers['content-type'] ?? '');
      return (kind: k.isEmpty ? guessFromUrl(url) : k, ok: true);
    } catch (_) {
      return (kind: guessFromUrl(url), ok: false);
    }
  }

  static String guessFromUrl(String url) {
    final f = url.split('?').first.split('#').first.toLowerCase();
    if (f.endsWith('.m3u8') || url.contains('.m3u8')) return 'hls';
    if (f.endsWith('.mkv')) return 'mkv';
    if (f.endsWith('.webm')) return 'webm';
    if (f.endsWith('.ts')) return 'ts';
    if (f.endsWith('.mp4') || f.endsWith('.m4v')) return 'mp4';
    return '';
  }

  /// The kind of video from its first bytes (and the server's content type).
  static String sniff(Uint8List b, String contentType) {
    var i = 0;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) i = 3;
    while (i < b.length && (b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09)) {
      i++;
    }
    if (b.length - i >= 7 && String.fromCharCodes(b.sublist(i, i + 7)) == '#EXTM3U') return 'hls';
    if (b.length >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
      final head = String.fromCharCodes(b.sublist(0, min(b.length, 64)));
      return head.contains('webm') ? 'webm' : 'mkv';
    }
    if (b.length >= 8 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') return 'mp4';
    if (tsStart(b) >= 0) return 'ts';
    final ct = contentType.toLowerCase();
    if (ct.contains('mpegurl')) return 'hls';
    if (ct.contains('matroska')) return 'mkv';
    if (ct.contains('webm')) return 'webm';
    if (ct.contains('mp2t')) return 'ts';
    if (ct.contains('mp4')) return 'mp4';
    return '';
  }

  /// Where TS video starts in [b] (three sync bytes 188 apart), -1 if it
  /// doesn't look like TS.
  static int tsStart(Uint8List b) {
    for (var k = 0; k + 376 < b.length && k < 65536; k++) {
      if (b[k] == 0x47 && b[k + 188] == 0x47 && b[k + 376] == 0x47) return k;
    }
    return -1;
  }

  // ---- HLS playlists --------------------------------------------------------

  /// Rewrites an HLS playlist so every address in it goes through
  /// [route]: route(kind, absoluteUrl), kind = playlist, segment, key.
  static String rewritePlaylist(String text, Uri base, String Function(String kind, String url) route) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final master = lines.any((l) => l.trim().startsWith('#EXT-X-STREAM-INF'));
    final out = <String>[];
    final attr = RegExp(r'URI="([^"]*)"');
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (!line.contains('URI="')) {
          out.add(line);
          continue;
        }
        String kind;
        if (line.startsWith('#EXT-X-MEDIA:') || line.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
          kind = 'playlist';
        } else if (line.startsWith('#EXT-X-KEY') || line.startsWith('#EXT-X-SESSION-KEY')) {
          kind = 'key';
        } else if (line.startsWith('#EXT-X-MAP')) {
          kind = 'segment';
        } else {
          out.add(line);
          continue;
        }
        out.add(line.replaceAllMapped(attr, (m) {
          final u = m[1]!;
          if (u.isEmpty || u.startsWith('data:') || u.startsWith('skd:')) return m[0]!;
          return 'URI="${route(kind, base.resolve(u).toString())}"';
        }));
        continue;
      }
      out.add(route(master ? 'playlist' : 'segment', base.resolve(line).toString()));
    }
    return '${out.join('\n')}\n';
  }

  // ---- serving ------------------------------------------------------------

  /// Handles `/x/...` requests; false when the request isn't for this.
  Future<bool> handle(HttpRequest req) async {
    final seg = req.uri.pathSegments;
    if (seg.length != 3 || seg[0] != 'x') return false;
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', '*');
    res.headers.set('Access-Control-Expose-Headers', '*');
    if (req.method == 'OPTIONS') {
      await res.close();
      return true;
    }
    final e = _entries[seg[1]];
    if (e == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return true;
    }
    e.at = DateTime.now();
    final name = seg[2];
    final u = req.uri.queryParameters['u'];
    try {
      if (name == 'sub.vtt' && u != null) {
        await _subtitle(req, e, dec(u));
      } else if (name == 'p.m3u8' && u != null) {
        await _playlist(req, e, dec(u));
      } else if (name.startsWith('s.') && u != null) {
        await _segment(req, e, dec(u));
      } else if (name == 'k' && u != null) {
        await _pass(req, e, dec(u));
      } else if (name == 'v.m3u8') {
        await _playlist(req, e, e.url);
      } else if (name.startsWith('v.')) {
        await _pass(req, e, e.url, kind: name.substring(2));
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    } catch (_) {
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
    }
    return true;
  }

  String _route(String key, String kind, String url) {
    switch (kind) {
      case 'playlist':
        return '${base()}/x/$key/p.m3u8?u=${enc(url)}';
      case 'key':
        return '${base()}/x/$key/k?u=${enc(url)}';
    }
    final f = url.split('?').first.toLowerCase();
    final ext = RegExp(r'\.(m4s|mp4|m4v|m4a|aac|vtt|webvtt)$').firstMatch(f)?.group(1) ?? 'ts';
    return '${base()}/x/$key/s.$ext?u=${enc(url)}';
  }

  String _keyOf(_Entry e) => _entries.entries.firstWhere((x) => identical(x.value, e)).key;

  Future<void> _playlist(HttpRequest req, _Entry e, String url) async {
    final resp = await _client.get(Uri.parse(url), headers: _headersFor(e)).timeout(const Duration(seconds: 20));
    final res = req.response;
    if (resp.statusCode >= 400) {
      res.statusCode = resp.statusCode;
      await res.close();
      return;
    }
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final key = _keyOf(e);
    // The final address counts (after redirects) for relative links.
    final Object r = resp;
    final finalUrl = r is http.BaseResponseWithUrl ? r.url : Uri.parse(url);
    final body = rewritePlaylist(text, finalUrl, (kind, u) => _route(key, kind, u));
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-cache');
    res.write(body);
    await res.close();
  }

  static const _skip = {'transfer-encoding', 'access-control-allow-origin', 'connection', 'content-encoding', 'keep-alive'};

  /// Passes the link on as it is (Range requests included).
  Future<void> _pass(HttpRequest req, _Entry e, String url, {String kind = ''}) async {
    final r = http.Request(req.method == 'HEAD' ? 'HEAD' : 'GET', Uri.parse(url))..headers.addAll(_headersFor(e));
    final range = req.headers.value('range');
    if (range != null) r.headers['Range'] = range;
    final resp = await _client.send(r).timeout(const Duration(seconds: 25));
    final res = req.response;
    res.statusCode = resp.statusCode;
    resp.headers.forEach((k, v) {
      if (!_skip.contains(k.toLowerCase())) res.headers.set(k, v);
    });
    final mime = switch (kind) {
      'mp4' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'ts' => 'video/mp2t',
      _ => '',
    };
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    if (mime.isNotEmpty && !ct.startsWith('video/')) res.headers.set('Content-Type', mime);
    await res.addStream(resp.stream);
    await res.close();
  }

  /// A segment: TS hidden behind other bytes gets them cut off.
  Future<void> _segment(HttpRequest req, _Entry e, String url) async {
    final range = req.headers.value('range');
    final f = url.split('?').first.toLowerCase();
    final plainTsName = !RegExp(r'\.(m4s|mp4|m4v|m4a|aac|vtt|webvtt)$').hasMatch(f);
    if (range != null || !plainTsName) {
      await _pass(req, e, url, kind: plainTsName ? 'ts' : '');
      return;
    }
    final r = http.Request('GET', Uri.parse(url))..headers.addAll(_headersFor(e));
    final resp = await _client.send(r).timeout(const Duration(seconds: 25));
    final res = req.response;
    if (resp.statusCode >= 400) {
      res.statusCode = resp.statusCode;
      unawaited(resp.stream.drain<void>().catchError((_) {}));
      await res.close();
      return;
    }
    // Look at the start, then decide.
    final head = <int>[];
    final it = StreamIterator(resp.stream);
    while (head.length < 4096 && await it.moveNext()) {
      head.addAll(it.current);
    }
    final first = Uint8List.fromList(head);
    final at = tsStart(first);
    res.statusCode = HttpStatus.ok;
    if (at >= 0) {
      res.headers.contentType = ContentType('video', 'mp2t');
      res.add(at > 0 ? first.sublist(at) : first);
    } else {
      final ct = resp.headers['content-type'] ?? '';
      if (ct.isNotEmpty && !ct.startsWith('image/') && !ct.startsWith('text/')) {
        res.headers.set('Content-Type', ct);
      } else {
        res.headers.contentType = ContentType('video', 'mp2t');
      }
      res.add(first);
    }
    while (await it.moveNext()) {
      res.add(it.current);
    }
    await res.close();
  }

  Future<void> _subtitle(HttpRequest req, _Entry e, String url) async {
    final res = req.response;
    String raw;
    if (url.startsWith('http')) {
      final resp = await _client.get(Uri.parse(url), headers: _headersFor(e)).timeout(const Duration(seconds: 20));
      if (resp.statusCode >= 400) {
        res.statusCode = resp.statusCode;
        await res.close();
        return;
      }
      raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    } else {
      final path = url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
      raw = await File(path).readAsString();
    }
    res.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
    res.write(plusSubtitleToVtt(raw));
    await res.close();
  }
}

class _Entry {
  final String url;
  final Map<String, String> headers;
  DateTime at = DateTime.now();
  _Entry(this.url, this.headers);
}
