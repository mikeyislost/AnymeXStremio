import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/services/cast/cast_service.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// AnymeX+: casting MKV files with the audio track picked in the app.
///
/// Google Cast / DLNA TVs get the whole file and pick the audio themselves
/// (the first audio track, or the one marked default). As the file passes
/// through the phone's cast proxy, its track list is rewritten so the picked
/// audio comes first and is the only one marked default. Only the order of
/// the entries in the Tracks element changes, so its size and every other
/// byte stay the same, and seeking keeps working.
class MkvTrackPatch {
  /// File offset of the first patched byte.
  final int start;
  final Uint8List bytes;
  const MkvTrackPatch(this.start, this.bytes);
  int get end => start + bytes.length;

  /// Rewrites the part of [chunk] (which starts at file offset [offset])
  /// that overlaps the patch.
  List<int> apply(List<int> chunk, int offset) {
    final chunkEnd = offset + chunk.length;
    if (chunkEnd <= start || offset >= end) return chunk;
    final out = Uint8List.fromList(chunk);
    final from = math.max(start, offset), to = math.min(end, chunkEnd);
    out.setRange(from - offset, to - offset, bytes, from - start);
    return out;
  }

  /// Builds the patch from the first bytes of an MKV file. [audioIndex] is
  /// the audio track's position among audio tracks (0 = first). Returns null
  /// if it isn't an MKV, the track list isn't in [head], or nothing changes.
  static MkvTrackPatch? build(Uint8List head, int audioIndex) {
    final ebml = _El.read(head, 0);
    if (ebml == null || ebml.id != 0x1A45DFA3 || ebml.size < 0) return null;
    final seg = _El.read(head, ebml.dataEnd);
    if (seg == null || seg.id != 0x18538067) return null;
    var p = seg.dataStart;
    while (p < head.length) {
      final e = _El.read(head, p);
      if (e == null) return null;
      if (e.id == 0x1F43B675) return null; // a Cluster before the track list
      if (e.id == 0x1654AE6B) {
        if (e.size < 0 || e.dataEnd > head.length) return null;
        return _patchTracks(head, e, audioIndex);
      }
      if (e.size < 0) return null;
      p = e.dataEnd;
    }
    return null;
  }

  static MkvTrackPatch? _patchTracks(Uint8List b, _El tracks, int audioIndex) {
    final children = <_Child>[];
    var p = tracks.dataStart;
    while (p < tracks.dataEnd) {
      final e = _El.read(b, p);
      if (e == null || e.size < 0 || e.dataEnd > tracks.dataEnd) return null;
      final child = _Child(e.start, e.dataEnd);
      if (e.id == 0xAE) {
        var q = e.dataStart;
        while (q < e.dataEnd) {
          final c = _El.read(b, q);
          if (c == null || c.size < 0 || c.dataEnd > e.dataEnd) return null;
          if (c.id == 0x83 && c.size > 0) child.isAudio = b[c.dataEnd - 1] == 2;
          if (c.id == 0x88 && c.size > 0) child.flagDefault = (c.dataStart, c.dataEnd);
          q = c.dataEnd;
        }
      }
      children.add(child);
      p = e.dataEnd;
    }
    final audio = children.where((c) => c.isAudio).toList();
    if (audioIndex < 0 || audioIndex >= audio.length) return null;
    final chosen = audio[audioIndex];

    // Move the picked audio in front of the first audio track (if it isn't
    // first already); the default flags are fixed either way.
    final order = [...children];
    if (chosen != audio.first) {
      order.remove(chosen);
      order.insert(order.indexOf(audio.first), chosen);
    }

    final out = BytesBuilder(copy: false);
    for (final c in order) {
      final bytes = Uint8List.fromList(b.sublist(c.start, c.end));
      final f = c.flagDefault;
      if (c.isAudio && f != null) {
        for (var i = f.$1; i < f.$2; i++) {
          bytes[i - c.start] = 0;
        }
        bytes[f.$2 - 1 - c.start] = c == chosen ? 1 : 0;
      }
      out.add(bytes);
    }
    final patched = out.takeBytes();
    final original = b.sublist(tracks.dataStart, tracks.dataEnd);
    var same = patched.length == original.length;
    for (var i = 0; same && i < patched.length; i++) {
      if (patched[i] != original[i]) same = false;
    }
    if (same || patched.length != original.length) return null;
    return MkvTrackPatch(tracks.dataStart, patched);
  }
}

class _Child {
  final int start, end;
  bool isAudio = false;
  (int, int)? flagDefault;
  _Child(this.start, this.end);
}

/// One EBML element: its ID, where its data starts and ends (size -1 = unknown).
class _El {
  final int id, start, dataStart, size;
  const _El(this.id, this.start, this.dataStart, this.size);
  int get dataEnd => size < 0 ? 1 << 62 : dataStart + size;

  static _El? read(Uint8List b, int p) {
    final id = _vint(b, p, keepMarker: true);
    if (id == null) return null;
    final size = _vint(b, p + id.$2, keepMarker: false);
    if (size == null) return null;
    return _El(id.$1, p, p + id.$2 + size.$2, size.$1);
  }

  static (int, int)? _vint(Uint8List b, int p, {required bool keepMarker}) {
    if (p >= b.length) return null;
    final first = b[p];
    if (first == 0) return null;
    var len = 1, mask = 0x80;
    while ((first & mask) == 0) {
      mask >>= 1;
      len++;
    }
    if (len > 8 || p + len > b.length) return null;
    var v = keepMarker ? first : first & (mask - 1);
    var allOnes = (first & (mask - 1)) == mask - 1;
    for (var i = 1; i < len; i++) {
      v = (v << 8) | b[p + i];
      if (b[p + i] != 0xFF) allOnes = false;
    }
    if (!keepMarker && allOnes) return (-1, len);
    return (v, len);
  }
}

/// The audio pick for casting, and re-casting when it changes.
class PlusMkvAudio {
  /// Position of the picked audio among the file's audio tracks, or null to
  /// leave the file alone ("Auto").
  static int? audioIndex;

  static final _patches = <String, Future<MkvTrackPatch?>>{};
  static Worker? _worker;
  static Future<void> Function()? _recast;

  static int? _indexOf(PlayerController c) {
    final id = c.selectedAudioTrack.value?.id;
    final n = id == null ? null : int.tryParse(id);
    return (n == null || n < 1) ? null : n - 1; // mpv numbers audio tracks from 1
  }

  /// Called when a cast starts: takes the app's current audio pick and
  /// re-casts at the TV's spot whenever it changes while casting.
  static void castStarted(Future<void> Function(Duration at) recast) {
    if (!Get.isRegistered<PlayerController>()) {
      audioIndex = null;
      return;
    }
    final c = Get.find<PlayerController>();
    audioIndex = _indexOf(c);
    _recast = () => recast(CastService.instance.castPosition.value);
    _worker?.dispose();
    _worker = ever(c.selectedAudioTrack, (_) async {
      final cast = CastService.instance;
      if (!cast.isCasting.value) {
        _worker?.dispose();
        _worker = null;
        return;
      }
      final next = _indexOf(c);
      if (next == audioIndex) return;
      audioIndex = next;
      await _recast?.call();
    });
  }

  /// Wraps a proxied response so the TV sees the picked audio first.
  static Future<Stream<List<int>>> wrap(
    Stream<List<int>> body, {
    required String url,
    required Map<String, String> headers,
    required int statusCode,
    String? contentRange,
  }) async {
    final index = audioIndex;
    if (index == null || (statusCode != 200 && statusCode != 206)) return body;
    final patch = await _patchFor(url, headers, index);
    if (patch == null) return body;
    var offset = 0;
    if (statusCode == 206) {
      final m = RegExp(r'bytes\s+(\d+)-').firstMatch(contentRange ?? '');
      if (m == null) return body;
      offset = int.parse(m.group(1)!);
    }
    if (offset >= patch.end) return body;
    var pos = offset;
    return body.map((chunk) {
      final out = patch.apply(chunk, pos);
      pos += chunk.length;
      return out;
    });
  }

  static Future<MkvTrackPatch?> _patchFor(String url, Map<String, String> headers, int index) =>
      _patches.putIfAbsent('$index|$url', () async {
        try {
          final head = await _head(url, headers, 2 << 20);
          return head == null ? null : MkvTrackPatch.build(head, index);
        } catch (_) {
          return null;
        }
      });

  /// First [max] bytes of the file.
  static Future<Uint8List?> _head(String url, Map<String, String> headers, int max) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(headers)
        ..headers['range'] = 'bytes=0-${max - 1}';
      final resp = await client.send(req).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 && resp.statusCode != 206) return null;
      final out = BytesBuilder(copy: false);
      await for (final chunk in resp.stream) {
        out.add(chunk);
        if (out.length >= max) break;
      }
      return out.takeBytes();
    } finally {
      client.close();
    }
  }
}
