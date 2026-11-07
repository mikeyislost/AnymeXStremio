// Dart port of stremio-watched-bitfield
// (github.com/Stremio/stremio-core/tree/development/stremio-watched-bitfield).
//
// Stremio stores which episodes of a series were watched as
//   "<anchorVideoId>:<anchorLength>:<base64(zlib(bitfield bytes))>"
// where bit i corresponds to the i-th video when the meta's videos are
// sorted by (season, episode, released).

import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:anymex/plus/stremio/stremio_models.dart';

class WatchedBitField {
  final List<String> videoIds;
  Uint8List _values;
  int _length;

  WatchedBitField._(this.videoIds, this._values, this._length);

  factory WatchedBitField.empty(List<String> videoIds) {
    return WatchedBitField._(
      videoIds,
      Uint8List((videoIds.length / 8).ceil()),
      videoIds.length,
    );
  }

  /// Video ids in the exact order Stremio uses for the bitfield.
  static List<String> orderedVideoIds(List<StremioVideo> videos) {
    // stremio-core sorts missing values as i64::MIN; any value below every
    // real season/episode/timestamp gives the same order.
    const minVal = -(1 << 62);
    int key(int? v) => v ?? minVal;
    final sorted = List<StremioVideo>.from(videos)
      ..sort((a, b) {
        final s = key(a.season).compareTo(key(b.season));
        if (s != 0) return s;
        final e = key(a.episode).compareTo(key(b.episode));
        if (e != 0) return e;
        return key(a.released?.millisecondsSinceEpoch)
            .compareTo(key(b.released?.millisecondsSinceEpoch));
      });
    return sorted.map((v) => v.id).toList();
  }

  /// Rebuilds the bitfield from Stremio's serialized form, re-aligning it to
  /// the current list of videos (new episodes may have been added since).
  factory WatchedBitField.construct(String? serialized, List<String> videoIds) {
    if (serialized == null || serialized.isEmpty) {
      return WatchedBitField.empty(videoIds);
    }
    try {
      final parts = serialized.split(':');
      if (parts.length < 3) return WatchedBitField.empty(videoIds);
      final encoded = parts.removeLast();
      final anchorLength = int.parse(parts.removeLast());
      final anchorVideo = parts.join(':');

      final compressed = base64.decode(encoded);
      final decoded = Uint8List.fromList(ZLibCodec().decode(compressed));

      final anchorIdx = videoIds.indexOf(anchorVideo);
      if (anchorIdx == -1) return WatchedBitField.empty(videoIds);

      // new_with_values(values, Some(len)) pads to the needed byte count.
      final bytes = (videoIds.length / 8).ceil();
      final padded = Uint8List(decoded.length > bytes ? decoded.length : bytes)
        ..setRange(0, decoded.length, decoded);
      final source = WatchedBitField._(videoIds, padded, videoIds.length);

      final offset = anchorLength - anchorIdx - 1;
      if (offset == 0) return source;

      final resized = WatchedBitField.empty(videoIds);
      for (var i = 0; i < videoIds.length; i++) {
        final prev = i + offset;
        if (prev >= 0 && prev < source._length) {
          resized._set(i, source._get(prev));
        }
      }
      return resized;
    } catch (_) {
      return WatchedBitField.empty(videoIds);
    }
  }

  bool _get(int i) {
    final index = i ~/ 8;
    if (index >= _values.length) return false;
    return (_values[index] >> (i % 8)) & 1 != 0;
  }

  void _set(int i, bool v) {
    final index = i ~/ 8;
    if (index >= _values.length) {
      final grown = Uint8List(index + 1)..setRange(0, _values.length, _values);
      _values = grown;
      _length = _values.length * 8;
    }
    final mask = 1 << (i % 8);
    if (v) {
      _values[index] |= mask;
    } else {
      _values[index] &= (~mask) & 0xFF;
    }
  }

  bool getVideo(String videoId) {
    final pos = videoIds.indexOf(videoId);
    return pos == -1 ? false : _get(pos);
  }

  void setVideo(String videoId, bool watched) {
    final pos = videoIds.indexOf(videoId);
    if (pos != -1) _set(pos, watched);
  }

  int? _lastIndexOfTrue() {
    for (var i = _length - 1; i >= 0; i--) {
      if (_get(i)) return i;
    }
    return null;
  }

  /// Serializes to Stremio's `state.watched` string.
  String serialize() {
    final lastId = _lastIndexOfTrue() ?? 0;
    final anchor = lastId < videoIds.length ? videoIds[lastId] : 'undefined';
    final packed = base64.encode(ZLibCodec(level: 6).encode(_values));
    return '$anchor:${lastId + 1}:$packed';
  }
}
