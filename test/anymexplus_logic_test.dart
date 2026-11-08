// AnymeX+ logic checks that run on every build (the same ones as the
// Self Test's "Logic" group). A failing test stops the release.
//
// Run locally with: flutter test

import 'package:anymex/controllers/service_handler/service_handler.dart'
    show ServicesType;
import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/plus/continue_watching_row.dart';
import 'package:anymex/plus/custom_lists.dart';
import 'package:anymex/plus/list_card_badge.dart';
import 'package:anymex/plus/rate_prompt.dart';
import 'package:anymex/plus/missed_sequels.dart';
import 'package:anymex/plus/stremio/stremio_disk_cache.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart'
    show landscapeForTilt;
import 'package:anymex/plus/movie_watch_card.dart';
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
}
