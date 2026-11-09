// AnymeX+ logic checks that run on every build (the same ones as the
// Self Test's "Logic" group). A failing test stops the release.
//
// Run locally with: flutter test

import 'package:anymex/controllers/service_handler/service_handler.dart'
    show ServicesType;
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/plus/backup.dart';
import 'package:anymex/plus/card_menu.dart';
import 'package:anymex/plus/error_log.dart';
import 'package:anymex/controllers/services/backup_restore/backup_restore_service.dart'
    show categorizeSettingKey, SettingCategory;
import 'package:anymex/plus/continue_watching_row.dart';
import 'package:anymex/plus/skip_times.dart';
import 'package:anymex/plus/up_next.dart';
import 'package:anymex/plus/custom_lists.dart';
import 'package:anymex/plus/for_you/anime_for_you.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/for_you/ranking.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/for_you/taste_buttons.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:anymex/plus/layout/page_rows.dart' show PlusFilterRow;
import 'package:anymex/plus/list_card_badge.dart';
import 'package:anymex/plus/simkl_send_all.dart';
import 'package:anymex/plus/rate_prompt.dart';
import 'package:anymex/plus/row_perf.dart';
import 'package:anymex/plus/missed_sequels.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart'
    show landscapeForTilt;
import 'package:anymex/plus/movie_watch_card.dart';
import 'package:anymex/plus/stremio/ui/stremio_details_page.dart'
    show stremioTrailerIds;
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart'
    show stremioEpisodeLabel;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Episode labels', () {
    test('IMDb episodes show season and episode', () {
      expect(stremioEpisodeLabel('tt0903747:1:2'), 'S1 E2');
    });
    test('Kitsu episodes show only the episode', () {
      expect(stremioEpisodeLabel('kitsu:49803:1'), 'E1');
    });
    test('movie ids have no label', () {
      expect(stremioEpisodeLabel('tt0111161'), isNull);
      expect(stremioEpisodeLabel('kitsu:7311'), isNull);
    });
  });

  group('Stremio ids', () {
    test('media id round-trip', () {
      final id = StremioIds.mediaId('series', 'tt0903747', season: 2);
      expect(StremioIds.parse(id), ('series', 'tt0903747'));
    });
    test('AniList ids are not Stremio ids', () {
      expect(StremioIds.isStremioMediaId('21'), isFalse);
    });
    test('video id types', () {
      expect(StremioIds.typeForVideoId('kitsu:1:5'), 'series');
      expect(StremioIds.typeForVideoId('kitsu:1'), 'movie');
      expect(StremioIds.typeForVideoId('tt1:1:2'), 'series');
      expect(StremioIds.typeForVideoId('tt0111161'), 'movie');
    });
  });

  group('Movie detection and runtimes', () {
    final one = [Episode(number: '1')];
    test('AniList MOVIE with one entry is a movie', () {
      expect(
          isMovieMedia(
              Media(format: 'MOVIE', serviceType: ServicesType.anilist), one),
          isTrue);
    });
    test('TV is not a movie', () {
      expect(
          isMovieMedia(
              Media(format: 'TV', serviceType: ServicesType.anilist), one),
          isFalse);
    });
    test('a movie split in two parts shows episodes', () {
      expect(
          isMovieMedia(Media(format: 'MOVIE', serviceType: ServicesType.anilist),
              [Episode(number: '1'), Episode(number: '2')]),
          isFalse);
    });
    test('runtimes', () {
      expect(formatMovieRuntime('46 mins'), '46m');
      expect(formatMovieRuntime('106 min'), '1h 46m');
      expect(formatMovieRuntime('1 hr 46 min'), '1h 46m');
      expect(formatMovieRuntime('?'), '');
    });
  });

  group('Torrent file index', () {
    test('marker is removed and converted to TorrServer numbering', () {
      final (url, idx) = StremioPlayerBridge.splitTorrentFileIndex(
          'magnet:?xt=urn:btih:abc&anymex_fidx=2');
      expect(url, 'magnet:?xt=urn:btih:abc');
      expect(idx, 3);
    });
    test('no marker means no file index', () {
      final (_, idx) =
          StremioPlayerBridge.splitTorrentFileIndex('magnet:?xt=urn:btih:abc');
      expect(idx, isNull);
    });
  });

  group('Player rotation sides', () {
    test('iPhone turned left → landscapeRight', () {
      expect(landscapeForTilt(true, ios: true), DeviceOrientation.landscapeRight);
    });
    test('iPhone turned right → landscapeLeft', () {
      expect(landscapeForTilt(false, ios: true), DeviceOrientation.landscapeLeft);
    });
    test('Android unchanged', () {
      expect(
          landscapeForTilt(true, ios: false), DeviceOrientation.landscapeLeft);
      expect(
          landscapeForTilt(false, ios: false), DeviceOrientation.landscapeRight);
    });
  });

  group('Device cache', () {
    test('file names are stable and distinct', () {
      final a = StremioDiskCache.fileNameFor('meta|series|tt0903747');
      expect(a, StremioDiskCache.fileNameFor('meta|series|tt0903747'));
      expect(a, isNot(StremioDiskCache.fileNameFor('meta|movie|tt0903747')));
      expect(a, matches(RegExp(r'^[0-9a-f]{16}\.json$')));
    });
    test('home row previews survive a save and load', () {
      const preview = StremioMetaPreview(
        id: 'tt0903747',
        type: 'series',
        name: 'Breaking Bad',
        poster: 'https://example.com/p.jpg',
        releaseInfo: '2008–2013',
        genres: ['Drama', 'Crime'],
      );
      final back = StremioMetaPreview.fromJson(preview.toJson());
      expect(back.id, preview.id);
      expect(back.type, preview.type);
      expect(back.name, preview.name);
      expect(back.poster, preview.poster);
      expect(back.releaseInfo, preview.releaseInfo);
      expect(back.genres, preview.genres);
    });
  });

  group('Beta updates', () {
    test('newest beta is picked by date, not list order', () {
      // GitHub's own order (by tag name).
      final list = [
        {'tag_name': 'v1.1.1-beta', 'prerelease': true, 'published_at': '2026-11-07T19:46:30Z'},
        {'tag_name': 'v1.1.1+1-beta', 'prerelease': true, 'published_at': '2026-11-07T23:22:00Z'},
        {'tag_name': 'v1.0.10', 'prerelease': false, 'published_at': '2026-11-07T17:59:17Z'},
      ];
      expect(AppChannel.newestBeta(list)?['tag_name'], 'v1.1.1+1-beta');
    });
    test('vX.Y.Z-beta+N tags count as betas', () {
      final list = [
        {'tag_name': 'v1.1.1+1-beta', 'prerelease': true, 'published_at': '2026-11-07T23:22:00Z'},
        {'tag_name': 'v1.1.1-beta+3', 'prerelease': true, 'published_at': '2026-11-08T01:00:00Z'},
      ];
      expect(AppChannel.newestBeta(list)?['tag_name'], 'v1.1.1-beta+3');
    });
    test('no betas → null', () {
      expect(AppChannel.newestBeta([
        {'tag_name': 'v1.0.10', 'prerelease': false, 'published_at': '2026-11-07T17:59:17Z'},
      ]), isNull);
    });
  });

  group('Stream filters', () {
    test('quality from stream text', () {
      expect(streamQualityOf('Torrentio\n4k HDR'), '4K');
      expect(streamQualityOf('Show.S01E02.2160p.WEB-DL'), '4K');
      expect(streamQualityOf('[RD+] Torrentio 1080p'), '1080p');
      expect(streamQualityOf('720p WEBRip'), '720p');
      expect(streamQualityOf('480p'), 'SD');
      expect(streamQualityOf('Direct link'), '');
    });
    test('size from stream text', () {
      expect(streamSizeGbOf('👤 12 💾 2.3 GB ⚙️ ThePirateBay'), closeTo(2.3, 0.001));
      expect(streamSizeGbOf('💾 700 MB'), closeTo(700 / 1024, 0.001));
      expect(streamSizeGbOf('1,5 GiB'), closeTo(1.5, 0.001));
      expect(streamSizeGbOf('no size here'), isNull);
    });
    test('remembered choice is per show, not per episode', () {
      expect(StremioService.streamTitleKey(null, 'tt0903747:1:2'), 'tt0903747');
      expect(StremioService.streamTitleKey(null, 'kitsu:7442:5'), 'kitsu:7442');
      expect(StremioService.streamTitleKey('tt0111161', 'tt0111161'), 'tt0111161');
    });
  });

  group('Continue Watching row', () {
    StremioLibraryItem item(String id, String name, DateTime when) =>
        StremioLibraryItem({
          '_id': id,
          'name': name,
          'type': 'series',
          '_mtime': when.toUtc().toIso8601String(),
          'state': {'lastWatched': when.toUtc().toIso8601String()},
        });
    TrackedMedia anime(String id, String title, DateTime when) => TrackedMedia(
          id: id,
          title: title,
          watchingStatus: 'CURRENT',
          updatedAt: when.millisecondsSinceEpoch ~/ 1000,
        );

    test('newest first, anime and Movies & TV together', () {
      final rows = mergeContinueWatching([
        anime('1', 'Old Anime', DateTime(2026, 1, 1)),
        anime('2', 'New Anime', DateTime(2026, 3, 1)),
      ], [
        item('tt1', 'Some Movie', DateTime(2026, 2, 1)),
      ], const {});
      expect(rows.map((r) => r.name), ['New Anime', 'Some Movie', 'Old Anime']);
    });
    test('an anime synced to Stremio shows once', () {
      final rows = mergeContinueWatching([
        anime('154587', "Frieren: Beyond Journey\u2019s End", DateTime(2026, 1, 1)),
        anime('2', 'Other', DateTime(2026, 1, 2)),
      ], [
        item('tt22248376', "Frieren: Beyond Journey's End", DateTime(2026, 3, 1)),
        item('kitsu:1', 'Matched By Id', DateTime(2026, 3, 1)),
      ], const {'kitsu:1'});
      expect(rows.length, 2);
      expect(rows.first.mediaId, '2');
    });
    test('titles match across sites', () {
      expect(normalizeTitle('Frieren: Beyond Journey\u2019s End'),
          normalizeTitle("Frieren: Beyond Journey's End"));
    });
  });

  group('Missed sequels', () {
    test('only anime sequels from AniList relations', () {
      final found = MissedSequels.sequelsIn({
        'edges': [
          {'relationType': 'SEQUEL', 'node': {'id': 10, 'type': 'ANIME', 'status': 'FINISHED', 'format': 'TV', 'title': {'userPreferred': 'S2'}, 'coverImage': {'large': 'p'}}},
          {'relationType': 'PREQUEL', 'node': {'id': 11, 'type': 'ANIME', 'status': 'FINISHED', 'format': 'TV', 'title': {'userPreferred': 'S0'}, 'coverImage': {'large': 'p'}}},
          {'relationType': 'SEQUEL', 'node': {'id': 12, 'type': 'MANGA', 'status': 'FINISHED', 'format': 'MANGA', 'title': {'userPreferred': 'M'}, 'coverImage': {'large': 'p'}}},
        ]
      });
      expect(found.map((c) => c.id), [10]);
    });
    test('hides what is on your list, unreleased and music', () {
      const all = [
        SequelCandidate(id: 1, title: 'a', poster: '', status: 'FINISHED', format: 'TV'),
        SequelCandidate(id: 2, title: 'b', poster: '', status: 'NOT_YET_RELEASED', format: 'TV'),
        SequelCandidate(id: 3, title: 'c', poster: '', status: 'RELEASING', format: 'MUSIC'),
        SequelCandidate(id: 4, title: 'd', poster: '', status: 'RELEASING', format: 'TV'),
      ];
      expect(MissedSequels.visible(all, {'1'}).map((c) => c.id), [4]);
    });
    test('completed anime, most recently finished first', () {
      final list = [
        TrackedMedia(id: '1', watchingStatus: 'COMPLETED', completedAt: DateTime(2025)),
        TrackedMedia(id: '2', watchingStatus: 'CURRENT'),
        TrackedMedia(id: '3', watchingStatus: 'COMPLETED', completedAt: DateTime(2026)),
      ];
      expect(MissedSequels.completedOf(list).map((m) => m.id), ['3', '1']);
    });
  });

  group('Stremio sync entry', () {
    test('labels', () {
      expect(StremioSyncEntry.label('tt0903747'), 'IMDb');
      expect(StremioSyncEntry.label('kitsu:7442'), 'Kitsu');
    });
  });

  group('Library cards, custom lists, rating', () {
    test('score shows next to progress only when scored', () {
      final scored = TrackedMedia(
          id: '1', episodeCount: '3', totalEpisodes: '12', score: '8',
          servicesType: ServicesType.mal);
      final unscored = TrackedMedia(
          id: '2', episodeCount: '3', totalEpisodes: '12', score: '0',
          servicesType: ServicesType.mal);
      expect(listCardBadge(scored), endsWith(' · ★8'));
      expect(listCardBadge(unscored), isNot(contains('★')));
    });
    test('custom lists are picked out, newest first', () {
      final lists = PlusCustomLists.customListsIn([
        {'name': 'Watching', 'isCustomList': false, 'entries': [{'media': {'id': 1}}]},
        {'name': 'Comfy', 'isCustomList': true, 'entries': [
          {'media': {'id': 10, 'title': {'english': 'Old'}, 'coverImage': {'large': 'p'}}},
          {'media': {'id': 11, 'title': {'english': 'New'}, 'coverImage': {'large': 'p'}}},
        ]},
        {'name': 'Empty', 'isCustomList': true, 'entries': []},
      ]);
      expect(lists.length, 1);
      expect(lists.first.$1, 'Comfy');
      expect(lists.first.$2.map((m) => m.id), ['11', '10']);
    });
    test('unscored means no score yet', () {
      expect(RatePrompt.isUnscored(null), isTrue);
      expect(RatePrompt.isUnscored('0'), isTrue);
      expect(RatePrompt.isUnscored('85'), isFalse);
    });
  });

  group('For you', () {
    ForYouCandidate cand(String key, Map<String, double> votes,
        {List<String> genres = const [], double quality = 0}) {
      final c = ForYouCandidate(
          key: key, id: key, kind: 'anime', title: key, poster: '',
          genres: genres, quality: quality);
      c.votes.addAll(votes);
      return c;
    }

    test('genre taste is scaled to -1..1 and dropped shows count against', () {
      final g = genreProfile([
        (['Action', 'Drama'], 2.0),
        (['Action'], 2.0),
        (['Horror'], -1.0),
      ]);
      expect(g['Action'], 1.0);
      expect(g['Drama'], 0.5);
      expect(g['Horror'], -0.25);
      expect(genreProfile(const []), isEmpty);
    });

    test('recommendation strength falls with rank and is capped', () {
      expect(recommendationStrength(rank: 0), 1.0);
      expect(recommendationStrength(rank: 5),
          lessThan(recommendationStrength(rank: 1)));
      expect(recommendationStrength(rank: 0, votes: 100000), 1.5);
      expect(recommendationStrength(rank: 0, votes: 200),
          greaterThan(recommendationStrength(rank: 0, votes: 2)));
    });

    test('picks skip excluded titles and keep the strongest reason', () {
      const loved = ForYouSeed(key: 'a', title: 'Frieren', weight: 3, loved: true);
      const watched = ForYouSeed(key: 'b', title: 'Naruto', weight: 1);
      final picks = rankPicks(
        seeds: [loved, watched],
        candidates: [
          cand('x', {'a': 1.0, 'b': 1.0}),
          cand('y', {'b': 1.0}),
          cand('z', {'a': 1.0}),
        ],
        exclude: {'z'},
      );
      expect(picks.map((p) => p.key), ['x', 'y']);
      expect(picks.first.reason, 'Because you loved Frieren');
      expect(picks.last.reason, 'Because you watched Naruto');
    });

    test('one seed brings in at most maxPerSeed picks', () {
      const s = ForYouSeed(key: 'a', title: 'A', weight: 1);
      final picks = rankPicks(
        seeds: [s],
        candidates: [for (var i = 0; i < 10; i++) cand('c$i', {'a': 1.0})],
        maxPerSeed: 3,
      );
      expect(picks.length, 3);
    });

    test('"Not interested" genres push picks down', () {
      const s = ForYouSeed(key: 'a', title: 'A', weight: 1);
      final picks = rankPicks(
        seeds: [s],
        candidates: [
          cand('mecha', {'a': 1.0}, genres: ['Mecha']),
          cand('slice', {'a': 0.9}, genres: ['Slice of Life']),
        ],
        lessGenres: {'Mecha': 3},
      );
      expect(picks.first.key, 'slice');
    });

    test('anime seeds: favourites are loved, dropped shows are not seeds', () {
      final list = [
        TrackedMedia(id: '1', title: 'Great', score: '95', watchingStatus: 'COMPLETED', genres: ['Drama']),
        TrackedMedia(id: '2', title: 'Fine', score: '70', watchingStatus: 'COMPLETED'),
        TrackedMedia(id: '3', title: 'Meh', score: '50', watchingStatus: 'COMPLETED'),
        TrackedMedia(id: '4', title: 'Nope', watchingStatus: 'DROPPED', genres: ['Horror']),
      ];
      final r = AnimeForYou.seedsFrom(list, [
        (id: '2', title: 'Fine', genres: const <String>[]),
        (id: '9', title: 'Fav only', genres: const <String>[]),
      ]);
      final byKey = {for (final s in r.seeds) s.key: s};
      expect(byKey['1']!.liked, isTrue);
      expect(byKey['2']!.loved, isTrue);
      expect(byKey['9']!.loved, isTrue);
      expect(byKey.containsKey('4'), isFalse);
      expect(r.genres['Horror'], lessThan(0));
      expect(r.genres['Drama'], greaterThan(0));
    });

    test('Movies & TV seed weights', () {
      final now = DateTime(2026, 6, 1);
      MovieSeedInput input({bool watched = true, int ms = 0,
              TasteMark mark = TasteMark.none, DateTime? last}) =>
          (id: 'tt1', type: 'movie', title: 'X', watched: watched,
           watchedMs: ms, inLibrary: false, lastWatched: last ?? now, mark: mark);
      expect(MoviesForYou.seedWeight(input(), now: now), closeTo(1.0, 0.001));
      expect(MoviesForYou.seedWeight(input(mark: TasteMark.love), now: now),
          closeTo(3.0, 0.001));
      expect(
          MoviesForYou.seedWeight(
              input(last: now.subtract(const Duration(days: 365))), now: now),
          lessThan(0.6));
      expect(MoviesForYou.seedWeight(input(watched: false), now: now), 0);
      // Liked but never opened in Stremio still counts.
      expect(MoviesForYou.seedWeight(
              input(watched: false, mark: TasteMark.like), now: now),
          1.0);
      expect(MoviesForYou.seedWeight(input(mark: TasteMark.dislike), now: now),
          -1.5);
    });

    test('TMDB genres and results', () {
      expect(MoviesForYou.tmdbGenres([10759, 18]),
          ['Action', 'Adventure', 'Drama']);
      final show = MoviesForYou.candidateFromTmdb({
        'id': 1399, 'name': 'Show', 'poster_path': '/p.jpg',
        'media_type': 'tv', 'vote_average': 8.4, 'vote_count': 900,
        'genre_ids': [18],
      }, 'movie')!;
      expect(show.kind, 'series');
      expect(show.key, 'tmdb:tv:1399');
      expect(show.rating, '8.4');
      expect(MoviesForYou.candidateFromTmdb(
          {'id': 2, 'title': 'No poster'}, 'movie'), isNull);
    });

    test('Disliked seeds count against and never give a reason', () {
      const liked = ForYouSeed(key: 'a', title: 'A', weight: 1);
      const disliked = ForYouSeed(key: 'd', title: 'D', weight: -1.5);
      final picks = rankPicks(
        seeds: [liked, disliked],
        candidates: [
          cand('both', {'a': 1.0, 'd': 1.0}),
          cand('liked', {'a': 0.8}),
          cand('onlyBad', {'d': 1.0}),
        ],
      );
      expect(picks.map((p) => p.key), ['liked', 'both']);
      expect(picks.last.reason, 'Because you watched A');
    });

    test('anime marks: like, love and dislike', () {
      final list = [
        TrackedMedia(id: '1', title: 'Liked', watchingStatus: 'COMPLETED'),
        TrackedMedia(id: '2', title: 'Hated', score: '90', watchingStatus: 'COMPLETED', genres: ['Mecha']),
      ];
      final r = AnimeForYou.seedsFrom(list, const [], marks: {
        'al:1': TasteMark.like,
        'al:2': TasteMark.dislike,
        'al:7': TasteMark.love,
      }, notes: {
        'al:7': (title: 'Off list', genres: ['Drama']),
      });
      final byKey = {for (final s in r.seeds) s.key: s};
      expect(byKey['1']!.liked, isTrue);
      expect(byKey['2']!.weight, lessThan(0));
      expect(byKey['7']!.loved, isTrue);
      expect(byKey['7']!.title, 'Off list');
      expect(r.genres['Mecha'], lessThan(0));
    });

    test('Like and Love become Simkl ratings', () {
      expect(PlusTasteButtons.simklRatingFor(TasteMark.dislike), 4);
      expect(PlusTasteButtons.simklRatingFor(TasteMark.like), 8);
      expect(PlusTasteButtons.simklRatingFor(TasteMark.love), 10);
      expect(PlusTasteButtons.simklRatingFor(TasteMark.none), isNull);
    });
  });
  group('Skip times and Up next', () {
    test('Stremio playbacks map to IMDb + episode', () {
      final ep = PlusSkipTimes.targetFor('stremio|series|tt0903747|s2', 'tt0903747:2:5')!;
      expect(ep.imdb, 'tt0903747');
      expect(ep.season, 2);
      expect(ep.episode, 5);
      final movie = PlusSkipTimes.targetFor('stremio|movie|tt1375666', 'tt1375666')!;
      expect(movie.season, isNull);
      expect(PlusSkipTimes.targetFor('stremio|series|kitsu:1', 'kitsu:1:3'), isNull);
      expect(PlusSkipTimes.targetFor('21', null), isNull);
    });

    test('TheIntroDB answers become skip times', () {
      final t = PlusSkipTimes.fromIntroDbJson({
        'intro': [
          {'start_ms': null, 'end_ms': 62500}
        ],
        'recap': [],
        'credits': [
          {'start_ms': 2500000, 'end_ms': null}
        ],
      }, 2600)!;
      expect(t.op!.start, 0);
      expect(t.op!.end, 63);
      expect(t.recap, isNull);
      expect(t.ed!.start, 2500);
      expect(t.ed!.end, 2600);
      expect(PlusSkipTimes.fromIntroDbJson({'intro': []}, 100), isNull);
    });

    test('chapter names become skip times', () {
      expect(PlusSkipTimes.chapterKind('Opening Credits'), 'intro');
      expect(PlusSkipTimes.chapterKind('Previously On'), 'recap');
      expect(PlusSkipTimes.chapterKind('End Credits'), 'credits');
      expect(PlusSkipTimes.chapterKind('Episode'), isNull);
      expect(PlusSkipTimes.chapterKind('Edward'), isNull);
      final t = PlusSkipTimes.fromChapters([
        (title: 'Intro', start: 0),
        (title: 'Episode', start: 45.2),
        (title: 'Credits', start: 1300),
      ], 1400)!;
      expect(t.op!.end, 46);
      expect(t.ed!.start, 1300);
      expect(t.ed!.end, 1400);
    });

    test('Up next: credits countdown, else button then end countdown', () {
      var s = PlusUpNext.stateAt(
          position: 1305, duration: 1400, creditsStart: 1300, watchedPoint: 0.8);
      expect(s.show, isTrue);
      expect(s.countdown, 5);
      expect(s.playNow, isFalse);
      s = PlusUpNext.stateAt(
          position: 1311, duration: 1400, creditsStart: 1300, watchedPoint: 0.8);
      expect(s.playNow, isTrue);
      s = PlusUpNext.stateAt(position: 1000, duration: 1400, watchedPoint: 0.8);
      expect(s.show, isFalse);
      s = PlusUpNext.stateAt(position: 1200, duration: 1400, watchedPoint: 0.8);
      expect(s.show, isTrue);
      expect(s.countdown, isNull);
      s = PlusUpNext.stateAt(position: 1394, duration: 1400, watchedPoint: 0.8);
      expect(s.countdown, 6);
      expect(s.playNow, isFalse);
    });
  });
  group('Error log and backup', () {
    test('errors are kept (50 max), stacks joined, secrets blanked', () {
      PlusErrorLog.entries.clear();
      final t = DateTime(2026, 11, 8, 12);
      for (var i = 0; i < 55; i++) {
        PlusErrorLog.add('e$i', now: t.add(Duration(minutes: i)));
      }
      expect(PlusErrorLog.entries.length, 50);
      expect(PlusErrorLog.entries.first.message, 'e5');
      PlusErrorLog.add('STACK: at foo', now: t.add(const Duration(minutes: 54)));
      expect(PlusErrorLog.entries.length, 50);
      expect(PlusErrorLog.entries.last.message, contains('STACK: at foo'));
      PlusErrorLog.add('GET https://x.org/a?api_key=abc123&b=1 Bearer eyJhbGc.x.y '
          'https://torrentio.strem.fun/realdebrid=ABCDEFGHIJKLMNOPQRSTUVWXYZ123/stream');
      final m = PlusErrorLog.entries.last.message;
      expect(m, isNot(contains('abc123')));
      expect(m, isNot(contains('eyJhbGc')));
      expect(m, isNot(contains('ABCDEFGHIJKLMNOP')));
      expect(PlusErrorLog.report(), startsWith('AnymeX+ recent errors (50)'));
      PlusErrorLog.entries.clear();
    });

    test('AnymeX+ settings go into the backup', () {
      for (final k in ['anymexplus_stremio_rows', 'anymexplus_stream_prefs',
          'stremio_sync_enabled', 'anymexplus_stremio_sync_routes',
          'anymexplus_taste_marks', 'anymexplus_foryou_hidden']) {
        expect(categorizeSettingKey(k), SettingCategory.general, reason: k);
      }
      expect(categorizeSettingKey('stremio_auth_key'), SettingCategory.authTokens);
      expect(PlusBackup.isPlusKey('anymexplus_taste_marks'), isTrue);
    });
  });
  group('Card menu', () {
    test('Play picks the right episode', () {
      const ids = ['e1', 'e2', 'e3'];
      expect(PlusCardMenu.nextIndex(ids, null), 0);
      expect(PlusCardMenu.nextIndex(ids, 'e1'), 1);
      expect(PlusCardMenu.nextIndex(ids, 'e2', partway: true), 1);
      expect(PlusCardMenu.nextIndex(ids, 'e3'), 2);
      expect(PlusCardMenu.nextIndex(ids, 'gone'), 0);
      expect(PlusCardMenu.nextIndex(const [], 'e1'), -1);
    });
  });
  group('Row scrolling', () {
    test('cards animate only when a row first shows', () {
      var t = DateTime(2026, 11, 8, 12);
      PlusRowPerf.now = () => t;
      PlusRowPerf.reset();
      expect(PlusRowPerf.shouldAnimate('carousel-Trending'), isTrue);
      t = t.add(const Duration(milliseconds: 500));
      expect(PlusRowPerf.shouldAnimate('carousel-Trending'), isTrue);
      t = t.add(const Duration(seconds: 5));
      expect(PlusRowPerf.shouldAnimate('carousel-Trending'), isFalse);
      expect(PlusRowPerf.shouldAnimate('carousel-Popular'), isTrue);
      PlusRowPerf.now = DateTime.now;
      PlusRowPerf.reset();
    });

    test('rows use small posters', () {
      expect(PlusRowPerf.smallPoster('https://image.tmdb.org/t/p/original/a.jpg'),
          'https://image.tmdb.org/t/p/w342/a.jpg');
      expect(PlusRowPerf.smallPoster('https://image.tmdb.org/t/p/w500/a.jpg'),
          'https://image.tmdb.org/t/p/w342/a.jpg');
      expect(PlusRowPerf.smallPoster('https://image.tmdb.org/t/p/w185/a.jpg'),
          'https://image.tmdb.org/t/p/w185/a.jpg');
      expect(
          PlusRowPerf.smallPoster(
              'https://images.metahub.space/poster/large/tt0111161/img'),
          'https://images.metahub.space/poster/medium/tt0111161/img');
      expect(PlusRowPerf.smallPoster('https://example.com/p.jpg'),
          'https://example.com/p.jpg');
      expect(PlusRowPerf.smallPoster(''), '');
    });
  });
  group('Edit layout', () {
    const specs = [
      PlusRowSpec('a', 'A'),
      PlusRowSpec('b', 'B', shownByDefault: false),
      PlusRowSpec('c', 'C'),
    ];

    test('no saved layout = default order and on/off', () {
      final rows = PlusLayout.arrange(specs, const []);
      expect(rows.map((r) => r.key), ['a', 'b', 'c']);
      expect(rows.map((r) => r.config.hidden), [false, true, false]);
    });

    test('your order wins; new rows go after their neighbour', () {
      final rows = PlusLayout.arrange(specs, const [
        PlusRowConfig(key: 'c'),
        PlusRowConfig(key: 'a', name: 'Mine', hidden: true),
      ]);
      expect(rows.map((r) => r.key), ['c', 'a', 'b']);
      expect(rows[1].title, 'Mine');
      expect(rows[1].config.hidden, isTrue);
    });

    test('rows that are gone are skipped but kept when saving', () {
      const saved = [
        PlusRowConfig(key: 'gone'),
        PlusRowConfig(key: 'a'),
        PlusRowConfig(key: 'x', added: true, params: {'title': 'Romance'}),
      ];
      final rows = PlusLayout.arrange(specs, saved);
      expect(rows.map((r) => r.key), ['a', 'b', 'c', 'x']);
      expect(rows.firstWhere((r) => r.key == 'x').title, 'Romance');
      final out = PlusLayout.toSave(rows, saved);
      expect(out.map((c) => c.key), containsAll(['a', 'x', 'gone']));
    });

    test('row style saves and loads', () {
      const st = PlusRowStyle(
          cardStyle: 2,
          size: 1.2,
          view: PlusRowView.grid,
          count: 20,
          sort: PlusRowSort.score);
      final back = PlusRowStyle.fromJson(st.toJson());
      expect(back.cardStyle, 2);
      expect(back.size, 1.2);
      expect(back.view, PlusRowView.grid);
      expect(back.count, 20);
      expect(back.sort, PlusRowSort.score);
      expect(PlusRowStyle.plain.toJson(), isEmpty);
      expect(PlusRowStyle.fromJson(null).isPlain, isTrue);
      final c = PlusRowConfig.fromJson(
          const PlusRowConfig(key: 'k', name: 'N', style: st).toJson())!;
      expect(c.name, 'N');
      expect(c.style.count, 20);
    });

    test('sorting', () {
      final titles = ['b', 'A', 'c'];
      final scores = [7.0, null, 9.0];
      expect(
          PlusLayout.sortedIndices(3, PlusRowSort.title,
              title: (i) => titles[i]),
          [1, 0, 2]);
      expect(
          PlusLayout.sortedIndices(3, PlusRowSort.score,
              score: (i) => scores[i]),
          [2, 0, 1]);
      expect(PlusLayout.sortedIndices(3, PlusRowSort.normal), [0, 1, 2]);
      expect(PlusLayout.scoreOf('84'), 8.4);
      expect(PlusLayout.scoreOf('8.4'), 8.4);
      expect(PlusLayout.scoreOf('?'), isNull);
    });

    test('filtered row query', () {
      final v = PlusFilterRow.variablesFor(const {
        'type': 'MANGA',
        'genres': ['Romance'],
        'year': 2024,
        'minScore': 70,
        'sort': 'SCORE_DESC',
      });
      expect(v['type'], 'MANGA');
      expect(v['genres'], ['Romance']);
      expect(v['from'], 20240000);
      expect(v['to'], 20250000);
      expect(v['minScore'], 69);
      expect(v['sort'], ['SCORE_DESC']);
      final d = PlusFilterRow.variablesFor(const {});
      expect(d['type'], 'ANIME');
      expect(d.containsKey('genres'), isFalse);
      expect(d['sort'], ['POPULARITY_DESC']);
    });
  });

  group('Send everything to Simkl', () {
    test('statuses and scores', () {
      expect(PlusSimklSendAll.simklStatus('CURRENT'), 'watching');
      expect(PlusSimklSendAll.simklStatus('REPEATING'), 'watching');
      expect(PlusSimklSendAll.simklStatus('PAUSED'), 'hold');
      expect(PlusSimklSendAll.simklStatus('PLANNING'), 'plantowatch');
      expect(PlusSimklSendAll.simklStatus('COMPLETED'), 'completed');
      expect(PlusSimklSendAll.simklStatus(null), isNull);
      expect(PlusSimklSendAll.simklRating('85'), 9);
      expect(PlusSimklSendAll.simklRating('7.5'), 8);
      expect(PlusSimklSendAll.simklRating('0'), isNull);
      expect(PlusSimklSendAll.simklRating(null), isNull);
    });

    test('episodes and seasons', () {
      expect(PlusSimklSendAll.seasonEpisode('tt1:2:5'), (2, 5));
      expect(PlusSimklSendAll.seasonEpisode('tt1'), isNull);
      expect(PlusSimklSendAll.episodesUpTo(3).length, 3);
      final s = PlusSimklSendAll.seasonsFor([(2, 1), (1, 3), (1, 1)]);
      expect(s.map((e) => e['number']), [1, 2]);
      expect((s.first['episodes'] as List).map((e) => e['number']), [1, 3]);
    });
  });

  group('Trailers', () {
    test('from Cinemeta trailers, else trailerStreams', () {
      expect(
          stremioTrailerIds({
            'trailers': [
              {'source': 'abc', 'type': 'Trailer'},
              {'source': 'abc', 'type': 'Trailer'},
            ]
          }),
          [('Trailer', 'abc')]);
      expect(
          stremioTrailerIds({
            'trailerStreams': [
              {'ytId': 'xyz', 'title': 'Teaser'}
            ]
          }),
          [('Teaser', 'xyz')]);
      expect(stremioTrailerIds({}), isEmpty);
    });
  });
}
