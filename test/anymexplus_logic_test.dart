// AnymeX+ logic checks that run on every build (the same ones as the
// Self Test's "Logic" group). A failing test stops the release.
//
// Run locally with: flutter test

import 'dart:convert';
import 'package:anymex/controllers/service_handler/service_handler.dart'
    show ServicesType;
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/airplay.dart' show plusMimeFromPath, PlusCastSearch;
import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/plus/tv/tv_link.dart' show PlusTvLink;
import 'package:anymex/plus/tv/tv_play.dart' show PlusTvPlay;
import 'package:anymex/plus/tv/tv_sync.dart' show PlusTvSync;
import 'package:anymex/plus/tv/flutter_tv_pair.dart' show PlusFlutterTvPair;
import 'package:anymex/plus/tvui/tv_list_editor.dart' show TvListRules;
import 'package:anymex/plus/tvui/tv_ext.dart' show TvExt, TvExtDevice;
import 'package:anymex/plus/tv/tv_anime.dart' show PlusTvAnime;
import 'package:anymex/plus/tv/tv_proxy.dart';
import 'package:anymex/plus/tv/subtitle_vtt.dart';
import 'package:anymex/plus/episode_hold.dart';
import 'package:anymex/plus/episode_order.dart';
import 'package:anymex/plus/mkv_audio.dart' show MkvTrackPatch;
import 'dart:typed_data' as td;
import 'package:anymex/plus/backup.dart';
import 'package:anymex/plus/card_menu.dart';
import 'package:anymex/plus/error_log.dart';
import 'package:anymex/plus/everything_library.dart';
import 'package:anymex/plus/windows_update.dart';
import 'package:anymex/controllers/services/backup_restore/backup_restore_service.dart'
    show categorizeSettingKey, SettingCategory;
import 'package:anymex/plus/continue_watching_row.dart';
import 'package:anymex/plus/skip_times.dart';
import 'package:anymex/plus/up_next.dart';
import 'package:anymex/plus/desktop_volume.dart' show PlusDesktopVolume, plusAddVolumeButtonIds;
import 'package:anymex/plus/external_player_pc.dart';
import 'package:anymex/plus/pc_video_quality.dart';
import 'package:flutter/painting.dart' show BoxFit, Size;
import 'package:anymex/plus/custom_lists.dart';
import 'package:anymex/plus/for_you/anime_for_you.dart';
import 'package:anymex/plus/for_you/movies_for_you.dart';
import 'package:anymex/plus/stremio/builtin_rows.dart';
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

  group('Built-in Movies & TV rows', () {
    test('row keys are unique and mostly genre rows start hidden', () {
      final keys = PlusBuiltinRows.all.map((r) => r.layoutKey).toList();
      expect(keys.toSet().length, keys.length);
      expect(PlusBuiltinRows.byLayoutKey('tmdb:popular-movies')?.type, 'movie');
      expect(PlusBuiltinRows.byLayoutKey('cat:x'), isNull);
    });
    test('queries', () {
      final netflix = PlusBuiltinRows.byLayoutKey('tmdb:netflix')!;
      final q = PlusBuiltinRows.queryFor(netflix, 'GB');
      expect(q, contains('with_watch_providers=8'));
      expect(q, contains('watch_region=GB'));
      expect(q, contains('sort_by=popularity.desc'));
      final horror = PlusBuiltinRows.byLayoutKey('tmdb:g-horror')!;
      expect(PlusBuiltinRows.queryFor(horror, 'US'),
          allOf(contains('with_genres=27'), contains('vote_count.gte')));
      final pop = PlusBuiltinRows.byLayoutKey('tmdb:popular-movies')!;
      expect(PlusBuiltinRows.queryFor(pop, 'US'), isEmpty);
    });
    test('TMDB result to row item', () {
      final p = PlusBuiltinRows.previewFrom({
        'id': 1,
        'name': 'Show',
        'poster_path': '/p.jpg',
        'backdrop_path': '/b.jpg',
        'first_air_date': '2024-05-01',
        'vote_average': 8.25,
        'vote_count': 300,
        'genre_ids': [18],
      }, 'series', 'tt123')!;
      expect(p.id, 'tt123');
      expect(p.type, 'series');
      expect(p.releaseInfo, '2024');
      expect(p.imdbRating, '8.3');
      expect(p.genres, ['Drama']);
      expect(p.poster, 'https://image.tmdb.org/t/p/w500/p.jpg');
      expect(PlusBuiltinRows.previewFrom({'title': 'X'}, 'movie', 'tt1'),
          isNull); // no poster
      expect(
          PlusBuiltinRows.previewFrom(
              {'title': 'X', 'poster_path': '/a'}, 'movie', '123'),
          isNull); // not an IMDb id
    });
  });

  group('One library', () {
    StremioLibraryItem item(String id, String type, String name,
            {int offset = 0, int flagged = 0, int times = 0, DateTime? when}) =>
        StremioLibraryItem({
          '_id': id,
          'type': type,
          'name': name,
          'removed': false,
          'temp': false,
          '_mtime': (when ?? DateTime(2026)).toUtc().toIso8601String(),
          'state': {
            'timeOffset': offset,
            'flaggedWatched': flagged,
            'timesWatched': times,
            'lastWatched': (when ?? DateTime(2026)).toUtc().toIso8601String(),
          },
        });
    TrackedMedia anime(String id, String title, String status, DateTime when) =>
        TrackedMedia(
          id: id,
          title: title,
          watchingStatus: status,
          updatedAt: when.millisecondsSinceEpoch ~/ 1000,
        );

    test('Movies & TV status from Stremio', () {
      expect(plusStremioStatus(item('a', 'movie', 'A')), PlusLibStatus.planning);
      expect(plusStremioStatus(item('b', 'movie', 'B', offset: 60)),
          PlusLibStatus.watching);
      expect(plusStremioStatus(item('c', 'movie', 'C', times: 1)),
          PlusLibStatus.completed);
      expect(plusStremioStatus(item('d', 'series', 'D', flagged: 1)),
          PlusLibStatus.completed);
    });
    test('anime statuses map to the same filters', () {
      expect(plusAnimeStatus('CURRENT'), PlusLibStatus.watching);
      expect(plusAnimeStatus('REPEATING'), PlusLibStatus.watching);
      expect(plusAnimeStatus('PAUSED'), PlusLibStatus.paused);
      expect(plusAnimeStatus('PLANNING'), PlusLibStatus.planning);
    });
    test('together, newest first, no doubles, filters', () {
      final all = plusMergeLibrary([
        anime('1', 'Frieren', 'CURRENT', DateTime(2026, 1, 1)),
        anime('2', 'Dandadan', 'COMPLETED', DateTime(2026, 3, 1)),
      ], [
        item('tt1', 'movie', 'Dune', offset: 10, when: DateTime(2026, 2, 1)),
        item('tt2', 'series', 'Frieren', when: DateTime(2026, 4, 1)),
        item('kitsu:9', 'series', 'Synced', when: DateTime(2026, 4, 1)),
      ], const {'kitsu:9'});
      expect(all.map((e) => e.title), ['Dandadan', 'Dune', 'Frieren']);
      expect(
          plusFilterLibrary(all, status: PlusLibStatus.watching)
              .map((e) => e.title),
          ['Dune', 'Frieren']);
      expect(plusFilterLibrary(all, kind: PlusLibKind.movie).length, 1);
      expect(plusFilterLibrary(all, query: 'dan').single.title, 'Dandadan');
    });
  });

  group('Windows update', () {
    test('silent switches keep the folder and install mode', () {
      final a = PlusWindowsUpdate.installerArgs(r'C:\Program Files\AnymeXStremio',
          allUsers: true);
      expect(a, containsAll(['/SILENT', '/ALLUSERS', '/NORESTART']));
      expect(a.last, r'/DIR=C:\Program Files\AnymeXStremio');
      expect(
          PlusWindowsUpdate.installerArgs('x', allUsers: false),
          contains('/CURRENTUSER'));
    });
    test('Program Files means all users', () {
      final env = {'ProgramFiles': r'C:\Program Files'};
      expect(PlusWindowsUpdate.isAllUsersPath(
          r'C:\Program Files\AnymeXStremio', env), isTrue);
      expect(PlusWindowsUpdate.isAllUsersPath(
          r'C:\Users\me\AppData\Local\Programs\AnymeXStremio', env), isFalse);
    });
    test('an update that left the version unchanged failed', () {
      expect(PlusWindowsUpdate.updateFailed('v1.1.3-beta+1', 'v1.1.3-beta+1'), isTrue);
      expect(PlusWindowsUpdate.updateFailed('v1.1.3-beta+1', 'v1.1.3-beta+2'), isFalse);
      expect(PlusWindowsUpdate.updateFailed('', ''), isFalse);
    });
  });

  group('Casting', () {
    test('file type from the address', () {
      expect(plusMimeFromPath('https://x.y/Show.S01E01.1080p.MKV?token=1'), 'video/x-matroska');
      expect(plusMimeFromPath('/var/mobile/Downloads/ep1.mp4'), 'video/mp4');
      expect(plusMimeFromPath('https://x.y/stream/abc'), isNull);
    });
    test('IP address check', () {
      expect(PlusCastSearch.isIp('192.168.1.20'), isTrue);
      expect(PlusCastSearch.isIp(' 10.0.0.5 '), isTrue);
      expect(PlusCastSearch.isIp('lg-tv.local'), isFalse);
    });
  });

  group('MKV audio for casting', () {
    // EBML element: 1-byte or 4-byte ID + 1-byte size (data < 127 bytes).
    List<int> el(List<int> id, List<int> data) => [...id, 0x80 | data.length, ...data];
    List<int> entry(int number, int type, {int? flagDefault}) => el([0xAE], [
          ...el([0xD7], [number]),
          ...el([0x83], [type]),
          if (flagDefault != null) ...el([0x88], [flagDefault]),
        ]);
    final video = entry(1, 1);
    final jpn = entry(2, 2, flagDefault: 1);
    final eng = entry(3, 2, flagDefault: 0);
    final tracksData = [...video, ...jpn, ...eng];
    final head = td.Uint8List.fromList([
      ...el([0x1A, 0x45, 0xDF, 0xA3], [0x42, 0x82, 0x84, 0x77, 0x65, 0x62, 0x6D]),
      0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // Segment, unknown size
      ...el([0x15, 0x49, 0xA9, 0x66], [0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40]), // Info
      ...el([0x16, 0x54, 0xAE, 0x6B], tracksData),
      0x1F, 0x43, 0xB6, 0x75, 0x80, // Cluster
    ]);

    test('second audio track goes first and becomes the default', () {
      final patch = MkvTrackPatch.build(head, 1)!;
      final engDefault = entry(3, 2, flagDefault: 1);
      final jpnNot = entry(2, 2, flagDefault: 0);
      expect(patch.bytes, [...video, ...engDefault, ...jpnNot]);
      expect(patch.bytes.length, tracksData.length);
      // Applying it to the file in two chunks gives the same result.
      final split = patch.start + 5;
      final a = patch.apply(head.sublist(0, split), 0);
      final b = patch.apply(head.sublist(split), split);
      final whole = [...a, ...b];
      expect(whole.sublist(patch.start, patch.end), patch.bytes);
      expect(whole.length, head.length);
    });

    test('first audio track already default: nothing to change', () {
      expect(MkvTrackPatch.build(head, 0), isNull);
    });

    test('not an MKV, or no such track', () {
      expect(MkvTrackPatch.build(td.Uint8List.fromList([0, 1, 2, 3]), 1), isNull);
      expect(MkvTrackPatch.build(head, 5), isNull);
    });
  });

  group('TV link', () {
    test('sync is locked the way the TV app opens it (AES-256-GCM)', () {
      // Same answer as Node's crypto, which tv/gcm.js is checked against.
      final (iv, data) = PlusTvSync.seal('07' * 32, utf8.encode('{"hello":"wörld ✓","n":1}'),
          iv: td.Uint8List.fromList(List.generate(12, (i) => i)));
      expect(iv, 'AAECAwQFBgcICQoL');
      expect(data, 'Y6OBFXFltmtNkJJfVCoAnsHeKh06TlVfNPRSxx3hlJ260ydZhBoamybRuWw=');
      expect(() => PlusTvSync.seal('07', const [1]), throwsArgumentError);
    });
    test('sync hash ignores when the bundle was made', () {
      final a = {'v': 1, 'at': 1, 'rows': [1, 2]};
      final b = {'v': 1, 'at': 2, 'rows': [1, 2]};
      expect(PlusTvSync.bundleHash(a), PlusTvSync.bundleHash(b));
      expect(PlusTvSync.bundleHash(a), isNot(PlusTvSync.bundleHash({'v': 1, 'at': 1, 'rows': [2, 1]})));
    });
    test('picks the home network address', () {
      expect(
        PlusTvLink.pickLocalIp([('lo0', '127.0.0.1'), ('utun3', '10.8.0.2'), ('en0', '192.168.1.23')]),
        '192.168.1.23',
      );
      expect(
        PlusTvLink.pickLocalIp([('vEthernet (WSL)', '172.20.0.1'), ('Wi-Fi', '192.168.1.40')]),
        '192.168.1.40',
      );
      expect(PlusTvLink.pickLocalIp([('lo', '127.0.0.1')]), '');
      expect(PlusTvLink.pickLocalIp(const []), '');
    });

    test('TV report lists what the TV said', () {
      final r = PlusTvLink.buildReport(
        {
          'model': 'OLED42C3PUA',
          'sdkVersion': '10.2.0',
          'chrome': '120',
          'canPlay': {'mkv': 'maybe', 'mp4_hevc': 'probably'},
        },
        {
          'screen': 'player',
          'presses': 3,
          'played': {'mkv': 'yes'},
          'player': {'error': '', 'w': 1920},
        },
        '192.168.1.49',
      );
      expect(r, contains('TV address: 192.168.1.49'));
      expect(r, contains('model: OLED42C3PUA'));
      // The browser's guess about MKV is wrong on LG; what played is shown.
      expect(r, isNot(contains('mkv=maybe')));
      expect(r, contains('mp4_hevc=probably'));
      expect(r, contains('played: mkv=yes'));
      expect(r, contains('screen now: player'));
    });

    test('names for the TV: file kind and episode line', () {
      expect(PlusTvPlay.kindOf('video/x-matroska'), 'mkv');
      expect(PlusTvPlay.kindOf('video/mp4'), 'mp4');
      expect(PlusTvPlay.kindOf('video/odd'), 'video/odd');
      expect(PlusTvPlay.episodeLine('3', 'The Promise', 12), 'Episode 3 · The Promise');
      expect(PlusTvPlay.episodeLine('3', 'Episode 3', 12), 'Episode 3');
      expect(PlusTvPlay.episodeLine('3', null, 12), 'Episode 3');
      expect(PlusTvPlay.episodeLine('1', 'Some Movie', 1), '');
    });
  });

  group('Subtitles for the TV', () {
    test('WebVTT is left alone', () {
      const vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi';
      expect(plusSubtitleToVtt('\uFEFF$vtt\n'), vtt);
    });

    test('SRT times get a dot', () {
      final out = plusSubtitleToVtt('1\r\n00:00:01,500 --> 00:00:03,000\r\nHello, there\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nBye');
      expect(out, startsWith('WEBVTT\n\n1\n00:00:01.500 --> 00:00:03.000\nHello, there'));
      expect(out, contains('00:00:04.000 --> 00:00:05.000\nBye'));
    });

    test('ASS lines keep their text and timing, lose their styling', () {
      const ass = '[Script Info]\nTitle: x\n\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: Default,Arial\n\n[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\i1}Second{\\i0}, with a comma\\Nnext line\n'
          'Dialogue: 0,0:00:01.20,0:00:02.00,Default,,0,0,0,,First\n'
          'Dialogue: 0,0:00:08.00,0:00:09.00,Sign,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}\n'
          'Comment: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,ignored\n';
      expect(
        plusSubtitleToVtt(ass),
        'WEBVTT\n\n00:00:01.200 --> 00:00:02.000\nFirst\n\n'
        '00:00:05.000 --> 00:00:07.500\nSecond, with a comma\nnext line',
      );
    });
  });

  group('Long-press on an episode', () {
    test('offers watched-up-to and back-to-before', () {
      expect(PlusEpisodeHold.offers(5, 2), (5, null));
      expect(PlusEpisodeHold.offers(5, 5), (null, 4));
      expect(PlusEpisodeHold.offers(3, 8), (3, 2));
      expect(PlusEpisodeHold.offers(1, 1), (null, 0));
      expect(PlusEpisodeHold.offers(0, 0), (null, null));
    });

    test('status follows the progress', () {
      expect(PlusEpisodeHold.statusFor(progress: 12, totalEpisodes: 12, mediaStatus: 'FINISHED', listStatus: 'CURRENT'), 'COMPLETED');
      expect(PlusEpisodeHold.statusFor(progress: 12, totalEpisodes: 12, mediaStatus: 'RELEASING', listStatus: 'CURRENT'), 'CURRENT');
      expect(PlusEpisodeHold.statusFor(progress: 3, totalEpisodes: 12, mediaStatus: 'FINISHED', listStatus: 'REPEATING'), 'REPEATING');
      expect(PlusEpisodeHold.statusFor(progress: 3, totalEpisodes: null, mediaStatus: 'FINISHED', listStatus: null), 'CURRENT');
    });
  });

  group('Episode order from an extension', () {
    test('a backwards list is spotted', () {
      expect(plusIsBackwards([6, 5, 4, 3, 2, 1]), isTrue);
      expect(plusIsBackwards([12.5, 12, 11]), isTrue);
      expect(plusIsBackwards([1, 2, 3]), isFalse);
      expect(plusIsBackwards([3, 2, 1, 3, 2, 1]), isFalse); // seasons
      expect(plusIsBackwards([3, null, 1]), isFalse);
      expect(plusIsBackwards([1, 1]), isFalse);
      expect(plusIsBackwards([5]), isFalse);
    });

    test('a backwards list is turned oldest first, others are left alone', () {
      List<String> nums(List<Episode> l) => l.map((e) => e.number).toList();
      expect(nums(plusOldestFirst([Episode(number: '3'), Episode(number: '2'), Episode(number: '1')])), ['1', '2', '3']);
      expect(nums(plusOldestFirst([Episode(number: '1'), Episode(number: '2')])), ['1', '2']);
    });
  });

  group('TV app: anime', () {
    test('plays the server saved for the show, else one in the same language', () {
      const names = ['HD-1 Sub', 'HD-2 Sub', 'HD-1 Dub'];
      const urls = ['https://a/1', 'https://a/2', 'https://a/3'];
      expect(PlusTvAnime.pickServer(names, urls, null), 0);
      expect(PlusTvAnime.pickServer(names, urls, 'hd-2 sub'), 1);
      expect(PlusTvAnime.pickServer(names, urls, 'https://a/3'), 2);
      // The saved one is gone: the first dub, not the first server.
      expect(PlusTvAnime.pickServer(names, urls, 'Vid Dub'), 2);
      expect(PlusTvAnime.pickServer(names, urls, 'Vid Sub'), 0);
      // While servers are still coming in, only the saved one counts.
      expect(PlusTvAnime.pickServer(names, urls, 'Vid Dub', exactOnly: true), -1);
      expect(PlusTvAnime.pickServer(names, urls, null, exactOnly: true), -1);
      expect(PlusTvAnime.pickServer(const [], const [], 'x'), -1);
    });
    test('Home rows first, then the Movies & TV rows not shown yet', () {
      final home = [
        {'kind': 'cw', 'title': 'Continue Watching', 'anime': []},
        {'kind': 'anime', 'title': 'Trending Anime', 'cards': []},
        {'kind': 'tmdb', 'title': 'Trending movies', 'path': 'trending/movie/day', 'query': ''},
      ];
      final movies = [
        {'kind': 'cw', 'title': 'Continue Watching'},
        {'kind': 'tmdb', 'title': 'Trending · Movies', 'path': 'trending/movie/day', 'query': ''},
        {'kind': 'cat', 'title': 'Popular', 'base': 'https://x', 'type': 'movie', 'id': 'top'},
      ];
      final rows = PlusTvAnime.mergeRows(home, movies);
      expect(rows.map((r) => r['title']), ['Continue Watching', 'Trending Anime', 'Trending movies', 'Popular']);
      expect(rows.first.containsKey('anime'), isTrue);
    });
    test('cards and the episode list as the TV reads them', () {
      expect(PlusTvAnime.card(id: '1', name: 'A', romaji: 'A', poster: '?', rating: '0'), {'a': '1', 'name': 'A'});
      expect(PlusTvAnime.card(id: '1', name: 'A', romaji: 'B', poster: 'p', sub: '3 | 12', rating: '8.1', at: 5),
          {'a': '1', 'name': 'A', 'romaji': 'B', 'poster': 'p', 'sub': '3 | 12', 'rating': '8.1', 'at': 5});
      final ok = PlusTvAnime.episodesMessage(q: 'a1', id: '9', source: 'Ext', progress: 1, next: '2', episodes: [
        Episode(number: '1', title: 'One', thumbnail: 't', filler: true),
        Episode(number: '2'),
      ]);
      expect(ok['ok'], isTrue);
      expect(ok['eps'], [
        {'n': '1', 'title': 'One', 'thumb': 't', 'filler': true},
        {'n': '2'},
      ]);
      final bad = PlusTvAnime.episodesMessage(
          q: 'a1', id: '9', source: '', progress: 0, next: '', episodes: const [], error: 'No match');
      expect(bad['ok'], isFalse);
      expect(bad['err'], 'No match');
    });
  });

  group('PC volume and brightness', () {
    test('volume stays between 0 and 200%, two decimals', () {
      expect(PlusDesktopVolume.clampVolume(-0.1), 0.0);
      expect(PlusDesktopVolume.clampVolume(2.4), 2.0);
      expect(PlusDesktopVolume.clampVolume(0.30000000000000004), 0.3);
    });
    test('brightness never goes fully dark', () {
      expect(PlusDesktopVolume.clampBrightness(0), 0.2);
      expect(PlusDesktopVolume.clampBrightness(1.5), 1.0);
      expect(PlusDesktopVolume.dimFor(1.0), 0.0);
      expect(PlusDesktopVolume.dimFor(0.2), closeTo(0.72, 1e-9));
      expect(PlusDesktopVolume.dimFor(0.0), closeTo(0.72, 1e-9));
    });
  });

  group('External player on PC', () {
    test('mpv gets the headers, VLC the user agent and referrer', () {
      final h = {'User-Agent': 'UA', 'Referer': 'https://r.example/', 'Origin': 'https://o.example'};
      expect(PlusExternalPlayerPc.argsFor(r'C:\mpv\mpv.exe', 'https://x/v.mkv', h), [
        '--user-agent=UA',
        '--referrer=https://r.example/',
        '--http-header-fields=origin: https://o.example',
        '--force-window=immediate',
        '--',
        'https://x/v.mkv',
      ]);
      expect(PlusExternalPlayerPc.argsFor(r'C:\Program Files\VideoLAN\VLC\vlc.exe', 'u', h),
          ['--http-user-agent=UA', '--http-referrer=https://r.example/', 'u']);
      expect(PlusExternalPlayerPc.argsFor(r'C:\x\PotPlayerMini64.exe', 'u', h), ['u']);
    });
    test('looks in PATH and Program Files', () {
      final c = PlusExternalPlayerPc.candidates({'PATH': r'C:\tools;', 'ProgramFiles': r'C:\Program Files'});
      expect(c.first, r'C:\tools\mpv.exe');
      expect(c, contains(r'C:\Program Files\VideoLAN\VLC\vlc.exe'));
    });
  });

  group('PC video size', () {
    test('window size in real pixels, even numbers, only when the video fits', () {
      expect(PlusPcVideo.outputSize(const Size(1707, 960), 1.5, BoxFit.contain), (w: 2560, h: 1440));
      expect(PlusPcVideo.outputSize(const Size(1001, 501), 1.0, BoxFit.contain), (w: 1000, h: 500));
      expect(PlusPcVideo.outputSize(const Size(1920, 1080), 1.0, BoxFit.cover), isNull);
      expect(PlusPcVideo.outputSize(const Size(40, 30), 1.0, BoxFit.contain), isNull);
      expect(PlusPcVideo.outputSize(const Size(9000, 5000), 1.0, BoxFit.contain), isNull);
    });
    test('mpv quality options', () {
      expect(PlusPcVideo.mpvOptions['deband'], 'yes');
      expect(PlusPcVideo.mpvOptions['deband-grain'], '0');
      expect(PlusPcVideo.mpvOptions['scale'], 'ewa_lanczossharp');
    });
  });

  group('PC volume buttons in the bar layout', () {
    test('added at the start of the right side unless placed or hidden', () {
      final left = <String>['playlist'], right = <String>['shaders', 'tracks'];
      plusAddVolumeButtonIds(left, right, []);
      if (PlusDesktopVolume.supported) {
        expect(right, ['volume', 'brightness', 'shaders', 'tracks']);
      } else {
        expect(right, ['shaders', 'tracks']);
      }
      final r2 = <String>['tracks', 'volume'];
      plusAddVolumeButtonIds(<String>[], r2, ['brightness']);
      expect(r2, PlusDesktopVolume.supported ? ['tracks', 'volume'] : ['tracks']);
    });
  });

  group('TV phase 2: extension video through this device', () {
    String route(String kind, String url) => '<$kind:$url>';

    test('a media playlist given straight away: segments stay segments', () {
      const text = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXT-X-MAP:URI="init.mp4"\n#EXTINF:10,\nseg1.ts\n#EXTINF:10,\nhttps://cdn.example/seg2.jpg\n#EXT-X-ENDLIST\n';
      final out = PlusTvProxy.rewritePlaylist(text, Uri.parse('https://a.example/hls/index.m3u8?t=1'), route);
      expect(out, contains('URI="<key:https://a.example/hls/key.bin>"'));
      expect(out, contains('URI="<segment:https://a.example/hls/init.mp4>"'));
      expect(out, contains('<segment:https://a.example/hls/seg1.ts>'));
      expect(out, contains('<segment:https://cdn.example/seg2.jpg>'));
      expect(out, isNot(contains('<playlist:')));
      expect(out, contains('#EXT-X-ENDLIST'));
    });

    test('a master playlist: variants, audio groups and i-frames are playlists', () {
      const text = '#EXTM3U\r\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Japanese",URI="audio/ja.m3u8"\r\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"\r\n1080/index.m3u8\r\n'
          '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI="iframe.m3u8"\r\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://x"\r\n';
      final out = PlusTvProxy.rewritePlaylist(text, Uri.parse('https://a.example/m/master.m3u8'), route);
      expect(out, contains('URI="<playlist:https://a.example/m/audio/ja.m3u8>"'));
      expect(out, contains('<playlist:https://a.example/m/1080/index.m3u8>'));
      expect(out, contains('URI="<playlist:https://a.example/m/iframe.m3u8>"'));
      expect(out, contains('URI="skd://x"'));
    });

    test('what a link is, from its first bytes', () {
      td.Uint8List b(List<int> x) => td.Uint8List.fromList(x);
      expect(PlusTvProxy.sniff(b([0xEF, 0xBB, 0xBF, ...utf8.encode('\n#EXTM3U\n')]), ''), 'hls');
      expect(PlusTvProxy.sniff(b([0x1A, 0x45, 0xDF, 0xA3, ...utf8.encode('....matroska')]), ''), 'mkv');
      expect(PlusTvProxy.sniff(b([0x1A, 0x45, 0xDF, 0xA3, ...utf8.encode('....webm')]), ''), 'webm');
      expect(PlusTvProxy.sniff(b([0, 0, 0, 0x20, ...utf8.encode('ftypisom')]), ''), 'mp4');
      expect(PlusTvProxy.sniff(b(utf8.encode('<html>')), 'application/x-mpegURL'), 'hls');
      expect(PlusTvProxy.sniff(b(utf8.encode('<html>')), 'text/html'), '');
      expect(PlusTvProxy.guessFromUrl('https://x/a/master.m3u8?x=1'), 'hls');
      expect(PlusTvProxy.guessFromUrl('https://x/a/play?file=1'), '');
    });

    test('TS hidden behind a picture header is found', () {
      final bytes = td.Uint8List(8 + 188 * 4);
      bytes.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      for (var i = 0; i < 4; i++) {
        bytes[8 + i * 188] = 0x47;
      }
      expect(PlusTvProxy.tsStart(bytes), 8);
      expect(PlusTvProxy.sniff(bytes, 'image/png'), 'ts');
      expect(PlusTvProxy.tsStart(td.Uint8List(600)), -1);
    });

    test('links in addresses survive the trip', () {
      const u = 'https://a.example/x?y=1&z=ä/é==';
      expect(PlusTvProxy.dec(PlusTvProxy.enc(u)), u);
      expect(PlusTvProxy.enc(u).contains('='), isFalse);
    });

    test('the same link and headers keep their key', () {
      final p = PlusTvProxy.instance;
      final k1 = p.register('https://v.example/1.m3u8', {'Referer': 'https://site/'});
      expect(p.register('https://v.example/1.m3u8', {'Referer': 'https://site/'}), k1);
      expect(p.register('https://v.example/1.m3u8', {'Referer': 'https://other/'}), isNot(k1));
    });

    test('servers that did not answer are hidden unless none did', () {
      final a = PlusTvAnime.serverEntry(name: 'A', url: 'u1', kind: 'hls');
      final b = PlusTvAnime.serverEntry(name: 'B', url: 'u2', kind: '', dead: true);
      expect(PlusTvAnime.shownServers([a, null, b]).map((e) => e['name']), ['A']);
      expect(PlusTvAnime.shownServers([b]).map((e) => e['name']), ['B']);
      expect(PlusTvAnime.serverEntry(name: '', url: 'u', kind: 'mp4')['name'], 'Server');
    });

    test('episode numbers match however they are written', () {
      expect(PlusTvAnime.sameEpisode('4', '4'), isTrue);
      expect(PlusTvAnime.sameEpisode('04', '4'), isTrue);
      expect(PlusTvAnime.sameEpisode('4.0', '4'), isTrue);
      expect(PlusTvAnime.sameEpisode('4.5', '4'), isFalse);
    });

    test('a PC leaves the sync from your phone alone', () {
      expect(PlusTvSync.keepsOtherSync(isComputer: true, have: 'h', from: 'iPhone', me: 'PC'), isTrue);
      expect(PlusTvSync.keepsOtherSync(isComputer: true, have: '', from: '', me: 'PC'), isFalse);
      expect(PlusTvSync.keepsOtherSync(isComputer: true, have: 'h', from: 'PC', me: 'PC'), isFalse);
      expect(PlusTvSync.keepsOtherSync(isComputer: false, have: 'h', from: 'iPhone', me: 'iPad'), isFalse);
    });
  });

  group('Flutter TV: logins from the phone', () {
    test('both sides get the same lock key, and it opens what was locked', () {
      final (phone, phonePub) = PlusFlutterTvPair.newKeys();
      final (tv, tvPub) = PlusFlutterTvPair.newKeys();
      final salt = PlusFlutterTvPair.newSalt();
      final a = PlusFlutterTvPair.lockKey(phone, tvPub, '123456', salt);
      final b = PlusFlutterTvPair.lockKey(tv, phonePub, '123456', salt);
      expect(a, b);
      expect(a.length, 64);
      final sealed = PlusTvSync.seal(a, utf8.encode('{"anilist":"x"}'));
      expect(utf8.decode(PlusFlutterTvPair.open(b, sealed.$1, sealed.$2)), '{"anilist":"x"}');
    });

    test('a wrong code cannot open it', () {
      final (phone, phonePub) = PlusFlutterTvPair.newKeys();
      final (tv, tvPub) = PlusFlutterTvPair.newKeys();
      final a = PlusFlutterTvPair.lockKey(phone, tvPub, '123456', 's');
      final wrong = PlusFlutterTvPair.lockKey(tv, phonePub, '123457', 's');
      final sealed = PlusTvSync.seal(a, utf8.encode('secret'));
      expect(() => PlusFlutterTvPair.open(wrong, sealed.$1, sealed.$2), throwsA(anything));
    });

    test('codes are 6 digits; saved-key ids show nothing of the key', () {
      expect(RegExp(r'^\d{6}$').hasMatch(PlusFlutterTvPair.newCode()), isTrue);
      final key = 'ab' * 32;
      final id = PlusFlutterTvPair.idFor(key);
      expect(id.length, 16);
      expect(key.contains(id), isFalse);
    });

    test('carried names what was sent', () {
      expect(PlusFlutterTvPair.carried({'anilist': 't', 'simkl': '', 'stremio': 'k'}), ['AniList', 'Stremio']);
    });
  });

  group('Flutter TV: changing your AniList list', () {
    test('episodes stay within 0…total', () {
      expect(TvListRules.step(0, -1, 12), 0);
      expect(TvListRules.step(11, 5, 12), 12);
      expect(TvListRules.step(3, 1, 0), 4); // total unknown
    });

    test('status follows progress', () {
      expect(TvListRules.statusFor('PLANNING', 1, 12), 'CURRENT');
      expect(TvListRules.statusFor('', 1, 12), 'CURRENT');
      expect(TvListRules.statusFor('CURRENT', 12, 12), 'COMPLETED');
      expect(TvListRules.statusFor('COMPLETED', 5, 12), 'CURRENT');
      expect(TvListRules.statusFor('DROPPED', 12, 12), 'DROPPED');
      expect(TvListRules.statusFor('PAUSED', 4, 12), 'PAUSED');
      expect(TvListRules.progressFor('COMPLETED', 3, 12), 12);
      expect(TvListRules.progressFor('COMPLETED', 3, 0), 3);
    });

    test('marking an episode watched / not watched', () {
      expect(TvListRules.markEpisode('CURRENT', 3, 12, 7, true), ('CURRENT', 7));
      expect(TvListRules.markEpisode('CURRENT', 9, 12, 7, true), ('CURRENT', 9));
      expect(TvListRules.markEpisode('CURRENT', 9, 12, 7, false), ('CURRENT', 6));
      expect(TvListRules.markEpisode('CURRENT', 3, 12, 7, false), ('CURRENT', 3));
      expect(TvListRules.markEpisode('', 0, 12, 1, true), ('CURRENT', 1));
      expect(TvListRules.markEpisode('CURRENT', 11, 12, 12, true), ('COMPLETED', 12));
      expect(TvListRules.markEpisode('COMPLETED', 12, 12, 12, false), ('CURRENT', 11));
    });

    test('score steps and labels', () {
      expect(TvListRules.stepScore(0, -1), 0);
      expect(TvListRules.stepScore(70, 1), 75);
      expect(TvListRules.stepScore(100, 1), 100);
      expect(TvListRules.scoreLabel(0), 'No score');
      expect(TvListRules.scoreLabel(70), '7 / 10');
      expect(TvListRules.scoreLabel(75), '7.5 / 10');
    });
  });

  group('Flutter TV: extensions through the phone', () {
    test('a server from the phone becomes a playable stream', () {
      final s = TvExt.toStream({
        'name': 'Vidstreaming 1080p',
        'url': 'http://192.168.1.20:41733/x/abc/v.m3u8',
        'kind': 'm3u8',
        'subs': [
          {'lang': 'English', 'url': 'http://192.168.1.20:41733/x/abc/sub.vtt?u=x'},
          {'lang': 'x', 'url': ''},
        ],
      }, 'HiAnime', 'iPhone');
      expect(s.addonName, 'Extension · HiAnime');
      expect(s.name, 'Vidstreaming 1080p');
      expect(s.title, 'From iPhone');
      expect(s.bingeGroup, 'ext|Vidstreaming 1080p');
      expect(s.filename, 'video.m3u8');
      expect(s.subtitles.length, 1);
      expect(s.url, startsWith('http://'));
      expect(TvExt.toStream({'name': '', 'url': 'http://h/v.mp4', 'dead': true}, '', 'PC').title, 'From PC · may not work');
    });

    test('devices need a host, port and token', () {
      expect(TvExtDevice.fromJson({'host': '192.168.1.20', 'port': 41733, 'token': 't', 'name': 'iPhone'})?.name, 'iPhone');
      expect(TvExtDevice.fromJson({'host': '', 'port': 41733, 'token': 't'}), isNull);
      expect(TvExtDevice.fromJson({'host': 'h', 'port': 0, 'token': 't'}), isNull);
      expect(TvExtDevice.fromJson('nope'), isNull);
      expect(TvExt.extVideoId('21', '5'), 'anilist:21:5');
    });
  });
}
