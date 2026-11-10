import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/utils/function.dart';

/// AnymeX+: AnymeX expects an extension to list episodes newest first and
/// turns the list round. An extension that lists them oldest first then
/// comes out backwards (6, 5, 4…), and AnymeX's numbering and episode
/// titles, which go by position, end up on the wrong episodes: the card for
/// episode 2 played episode 5. This puts such a list back oldest first.
bool plusIsBackwards(List<double?> numbers) {
  if (numbers.length < 2) return false;
  for (var i = 0; i < numbers.length; i++) {
    final n = numbers[i];
    if (n == null) return false;
    if (i > 0 && n > numbers[i - 1]!) return false;
  }
  return numbers.first! > numbers.last!;
}

List<Episode> plusOldestFirst(List<Episode> episodes) {
  final numbers = [
    for (final e in episodes) double.tryParse(parseEpisodeInfo(e.number, e.title).number),
  ];
  return plusIsBackwards(numbers) ? episodes.reversed.toList() : episodes;
}
