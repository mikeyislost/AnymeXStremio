import 'package:anymex/utils/aniskip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AniSkip: times picked for the video length', () {
    // Two releases: a 1420 s one and a 1440 s one (20 s longer at the end).
    const results = [
      SkipResult(type: 'op', start: 90, end: 180, length: 1420),
      SkipResult(type: 'op', start: 95, end: 185, length: 1440),
      SkipResult(type: 'ed', start: 1300, end: 1390, length: 1420),
      SkipResult(type: 'ed', start: 1320, end: 1410, length: 1440),
    ];

    test('picks the submission closest in length', () {
      final t = EpisodeSkipTimes.fromResults(results, 1441);
      expect(t.op!.start, 95);
      expect(t.ed!.start, 1321); // 1 s longer than its release: ending moves 1 s
    });

    test('moves the ending by the length difference', () {
      final t = EpisodeSkipTimes.fromResults(const [SkipResult(type: 'ed', start: 1300, end: 1390, length: 1420)], 1450);
      expect(t.ed!.start, 1330);
      expect(t.ed!.end, 1420);
    });

    test('leaves openings where they were submitted', () {
      final t = EpisodeSkipTimes.fromResults(const [SkipResult(type: 'op', start: 90, end: 180, length: 1420)], 1450);
      expect(t.op!.start, 90);
    });

    test('no shift for a very different length (another version)', () {
      final t = EpisodeSkipTimes.fromResults(const [SkipResult(type: 'ed', start: 1300, end: 1390, length: 1420)], 2800);
      expect(t.ed!.start, 1300);
    });

    test('unknown length: first one, picked again later', () {
      final t = EpisodeSkipTimes.fromResults(results, 0);
      expect(t.op!.start, 90);
      final later = t.fittedFor(1440);
      expect(later.op!.start, 95);
      expect(later.ed!.start, 1320);
      expect(identical(later.fittedFor(1440), later), isTrue);
    });
  });
}
