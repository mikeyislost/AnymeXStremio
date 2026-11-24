import 'dart:convert';
import 'package:http/http.dart' as http;

class AniSkipApi {
  static const String apiUrl = "https://api.aniskip.com";
  static const String skipTimeEndpoint = "/v2/skip-times/";

  Future<EpisodeSkipTimes?> getSkipTimes(SkipSearchQuery query) async {
    if (query.idMAL == null || query.episodeNumber == null) return null;
    final String idMAL = query.idMAL!;
    final String episodeNumber = query.episodeNumber!;
    final int episodeLength = query.episodeLength ?? 0;

    final String uri =
        "$apiUrl$skipTimeEndpoint$idMAL/$episodeNumber"
        "?types[]=op&types[]=ed&types[]=recap&types[]=mixed-op&types[]=mixed-ed"
        "&episodeLength=$episodeLength";

    try {
      final response = await http.get(Uri.parse(uri));

      if (response.statusCode != 200) return null;

      final skipData = jsonDecode(response.body);
      if (skipData['found'] == true) {
        final results = <SkipResult>[];
        for (final element in skipData['results'] as List<dynamic>) {
          final interval = element['interval'];
          if (interval == null) continue;
          results.add(SkipResult(
            type: element['skipType'] as String? ?? '',
            start: (interval['startTime'] as num).toDouble(),
            end: (interval['endTime'] as num).toDouble(),
            length: (element['episodeLength'] as num?)?.toDouble() ?? 0,
          ));
        }
        if (results.isEmpty) return null;
        return EpisodeSkipTimes.fromResults(results, episodeLength);
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }
}

class EpisodeSkipTimes {
  final SkipIntervals? op;
  final SkipIntervals? ed;
  final SkipIntervals? recap;

  /// Every AniSkip submission, kept so the times can be picked again once
  /// the video's real length is known ([fittedTo]).
  final List<SkipResult> results;

  /// The video length (seconds) these times were picked for; 0 = unknown.
  final int fittedTo;

  EpisodeSkipTimes({this.op, this.ed, this.recap, this.results = const [], this.fittedTo = 0});

  /// Picks, for each kind, the submission made on the release closest in
  /// length to the video ([lengthSec]). Endings line up with the end of the
  /// video, so an ending is moved by the difference in length; openings and
  /// recaps stay as submitted. With no length known, the first one wins.
  factory EpisodeSkipTimes.fromResults(List<SkipResult> results, int lengthSec) {
    SkipIntervals? pick(bool Function(String) isType, {bool fromEnd = false}) {
      final list = results.where((r) => isType(r.type)).toList();
      if (list.isEmpty) return null;
      var best = list.first;
      if (lengthSec > 0) {
        for (final r in list) {
          if (r.length > 0 && (best.length <= 0 || (r.length - lengthSec).abs() < (best.length - lengthSec).abs())) best = r;
        }
      }
      var shift = 0.0;
      // Only for small differences (a few seconds of logos or a different
      // cut); a big one means another version of the episode entirely.
      if (fromEnd && lengthSec > 0 && best.length > 0 && (lengthSec - best.length).abs() <= 90) {
        shift = lengthSec - best.length;
      }
      final start = (best.start + shift).round();
      final end = (best.end + shift).round();
      if (end <= start) return null;
      return SkipIntervals(start: start < 0 ? 0 : start, end: end);
    }

    return EpisodeSkipTimes(
      op: pick((t) => t == 'op' || t == 'mixed-op'),
      ed: pick((t) => t == 'ed' || t == 'mixed-ed', fromEnd: true),
      recap: pick((t) => t == 'recap'),
      results: results,
      fittedTo: lengthSec,
    );
  }

  /// The same times picked again for a video [lengthSec] long (no change if
  /// already fitted to it or there's nothing to pick from).
  EpisodeSkipTimes fittedFor(int lengthSec) {
    if (lengthSec <= 0 || lengthSec == fittedTo || results.isEmpty) return this;
    return EpisodeSkipTimes.fromResults(results, lengthSec);
  }
}

/// One AniSkip submission: where it is, and how long the episode it was
/// timed on was (seconds).
class SkipResult {
  final String type;
  final double start;
  final double end;
  final double length;
  const SkipResult({required this.type, required this.start, required this.end, required this.length});
}

class SkipIntervals {
  final int start;
  final int end;

  SkipIntervals({required this.start, required this.end});
}

class SkipSearchQuery {
  final String? idMAL;
  final String? episodeNumber;
  final int? episodeLength;

  SkipSearchQuery({this.idMAL, this.episodeNumber, this.episodeLength});
}
