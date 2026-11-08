// AnymeX+ logic checks that run on every build (the same ones as the
// Self Test's "Logic" group). A failing test stops the release.
//
// Run locally with: flutter test

import 'package:anymex/controllers/service_handler/service_handler.dart'
    show ServicesType;
import 'package:anymex/plus/app_channel.dart';
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
}
