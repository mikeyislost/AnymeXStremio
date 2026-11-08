// AnymeX+: part of the Self Test. Stremio and sync checks.

part of 'self_test.dart';

extension SelfTestStremio on SelfTestRunner {
  List<_TestCase> _stremioTests() => [
        // ---- Stremio -------------------------------------------------------
        _TestCase('Stremio', 'Account', () => _needStremio(() async {
              final user = await _stremio.api.getUser(_stremio.authKey!);
              return Outcome.pass('session valid (${user['email'] ?? 'account'})');
            }), quick: true),
        _TestCase('Stremio', 'Updates waiting to send', () => _needStremio(() async {
              final n = await _stremio.pendingCount();
              if (n == 0) return const Outcome.pass('none (everything reached Stremio)');
              await _stremio.flushPending();
              final left = await _stremio.pendingCount();
              return Outcome(left == 0 ? SelfTestStatus.pass : SelfTestStatus.warn,
                  left == 0
                      ? '$n update(s) made offline were sent now'
                      : '$left update(s) still waiting; they are sent when Stremio can be reached');
            }), quick: true),
        _TestCase('Stremio', 'Installed addons', () async {
          await _stremio.ensureAddons();
          final addons = _stremio.addons;
          if (addons.isEmpty) return const Outcome.fail('no addons loaded');
          final streams = addons.where((a) => a.hasResource('stream')).length;
          final metas = addons.where((a) => a.hasResource('meta')).length;
          final catalogs = addons.fold<int>(0, (n, a) => n + a.catalogs.length);
          return Outcome(
              streams == 0 ? SelfTestStatus.warn : SelfTestStatus.pass,
              '${addons.length} addons · $metas with metadata · $streams with streams · '
              '$catalogs catalogs\n${addons.map((a) => a.name).join(', ')}'
              '${streams == 0 ? '\nno stream addons: nothing will play' : ''}');
        }, quick: true),
        _TestCase('Stremio', 'Addons the app is skipping', () async {
          await _stremio.ensureAddons();
          await _stremio.checkAddonHealth();
          final skipped = _stremio.addons
              .where((a) => !_stremio.isAddonUsable(a))
              .map((a) =>
                  '${a.name}: ${_stremio.unreachableAddons[a.transportUrl]}')
              .toList();
          return skipped.isEmpty
              ? const Outcome.pass('none; every addon is in use')
              : Outcome.info('not used for streams/details until they work again:\n'
                  '${skipped.join('\n')}');
        }, quick: true),
        _TestCase('Stremio', 'Every addon manifest reachable', () async {
          await _stremio.ensureAddons();
          final bad = <String>[];
          final local = <String>[];
          final times = <String>[];
          final slow = <String>[];
          for (final a in _stremio.addons) {
            final host = Uri.tryParse(a.transportUrl)?.host ?? '';
            final isLocal = host == '127.0.0.1' || host == 'localhost';
            final sw = Stopwatch()..start();
            try {
              final r = await SelfTestRunner._get(a.transportUrl, timeout: const Duration(seconds: 12));
              if (r.statusCode != 200) {
                bad.add('${a.name} (HTTP ${r.statusCode}${SelfTestRunner._httpHint(r.statusCode)})');
              } else {
                times.add('${a.name} ${sw.elapsedMilliseconds}ms');
                if (sw.elapsedMilliseconds > 3000) slow.add(a.name);
              }
            } catch (e) {
              (isLocal ? local : bad).add(isLocal ? a.name : '${a.name} (no response)');
            }
          }
          final ok = _stremio.addons.length - bad.length - local.length;
          final lines = [
            '$ok of ${_stremio.addons.length} manifests ok',
            if (bad.isNotEmpty)
              'not working: ${bad.join(', ')}. These addons are down on their '
                  'end; you can remove them in Settings → Accounts → Stremio.',
            if (local.isNotEmpty)
              'only works with the Stremio desktop app running on the same '
                  'device (expected on a phone): ${local.join(', ')}',
            if (slow.isNotEmpty) 'slow (over 3s): ${slow.join(', ')}',
            if (times.isNotEmpty) 'response times: ${times.join(' · ')}',
          ];
          return Outcome(
              bad.isNotEmpty ? SelfTestStatus.warn : SelfTestStatus.pass,
              lines.join('\n'));
        }, timeout: const Duration(seconds: 120)),
        _TestCase('Stremio', 'Catalog (first board catalog)', () async {
          await _stremio.ensureAddons();
          for (final a in _stremio.addons) {
            for (final c in a.catalogs) {
              if (!c.isBoardCatalog) continue;
              final items = await _stremio.api.catalog(a, c);
              return Outcome(items.isEmpty ? SelfTestStatus.warn : SelfTestStatus.pass,
                  '${a.name} "${c.name}" (${c.type}): ${items.length} items');
            }
          }
          return const Outcome.warn('no catalogs to test');
        }, quick: true),
        _TestCase('Stremio', 'Every board catalog', () async {
          await _stremio.ensureAddons();
          var ok = 0;
          final empty = <String>[];
          final failed = <String>[];
          final jobs = [
            for (final a in _stremio.addons)
              for (final c in a.catalogs.where((c) => c.isBoardCatalog)) (a, c)
          ];
          // Six at a time, like the Movies & TV home loads them.
          for (var i = 0; i < jobs.length; i += 6) {
            await Future.wait(jobs.skip(i).take(6).map((job) async {
              final (a, c) = job;
              try {
                final items = await _stremio.api
                    .catalog(a, c)
                    .timeout(const Duration(seconds: 20));
                items.isEmpty ? empty.add('${a.name}/${c.name} (${c.type})') : ok++;
              } catch (e) {
                failed.add('${a.name}/${c.name} (${c.type})');
              }
            }));
          }
          final status = failed.isNotEmpty
              ? SelfTestStatus.warn
              : SelfTestStatus.pass;
          return Outcome(status,
              '$ok catalogs returned items'
              '${empty.isEmpty ? '' : '\nempty: ${empty.join(', ')}'}'
              '${failed.isEmpty ? '' : '\nfailed: ${failed.join(', ')}'}');
        }, timeout: const Duration(seconds: 180)),
        _TestCase('Stremio', 'Search', () async {
          await _stremio.ensureAddons();
          for (final a in _stremio.addons) {
            for (final c in a.catalogs.where((c) => c.supportsSearch)) {
              final items = await _stremio.api.catalog(a, c, extra: {'search': 'Breaking Bad'});
              return Outcome(items.isEmpty ? SelfTestStatus.warn : SelfTestStatus.pass,
                  '${a.name}: ${items.length} results for "Breaking Bad"');
            }
          }
          return const Outcome.warn('no addon supports search');
        }),
        _TestCase('Stremio', 'Metadata (series)', () async {
          final meta = await _stremio.fetchMeta('series', 'tt0903747');
          if (meta == null) return const Outcome.fail('no addon returned metadata for Breaking Bad');
          return Outcome.pass('"${meta.name}": ${meta.seasons.length} seasons, ${meta.videos.length} episodes');
        }, quick: true),
        _TestCase('Stremio', 'Metadata (movie)', () async {
          final meta = await _stremio.fetchMeta('movie', 'tt0111161');
          if (meta == null) return const Outcome.fail('no metadata for The Shawshank Redemption');
          return Outcome.pass('"${meta.name}" (${meta.releaseInfo ?? '?'})');
        }),
        _TestCase('Stremio', 'Streams (per addon)', () async {
          final perAddon = <String, int>{};
          final failed = <String>[];
          await _stremio.ensureAddons();
          await _stremio.fetchStreams('series', 'tt0903747:1:1',
              onAddonResult: (a, s) => perAddon[a.name] = s.length);
          for (final a in _stremio.addons
              .where((a) => a.supports('stream', 'series', 'tt0903747:1:1'))) {
            if (!perAddon.containsKey(a.name)) failed.add(a.name);
          }
          final total = perAddon.values.fold<int>(0, (a, b) => a + b);
          if (perAddon.isEmpty) return const Outcome.warn('no stream addons for this title');
          return Outcome(total == 0 ? SelfTestStatus.warn : SelfTestStatus.pass,
              'Breaking Bad S1E1: $total streams\n'
              '${perAddon.entries.map((e) => '${e.key}: ${e.value}').join(', ')}');
        }, timeout: const Duration(seconds: 90)),
        _TestCase('Stremio', 'Library & Continue Watching',
            () => _needStremio(() async {
                  await _stremio.refreshLibrary();
                  return Outcome.pass(
                      '${_stremio.library.length} in library · '
                      '${_stremio.continueWatching.length} in Continue Watching');
                }), quick: true),
        _TestCase('Stremio', 'Watched-episodes encoding', () async {
          // Fixture from stremio-core's own tests.
          final ids = List.generate(9, (i) => 'tt2934286:1:${i + 1}');
          const field = 'tt2934286:1:5:5:eJyTZwAAAEAAIA==';
          final wb = WatchedBitField.construct(field, ids);
          if (!wb.getVideo('tt2934286:1:5') || wb.getVideo('tt2934286:1:6')) {
            return const Outcome.fail('decoded bits are wrong');
          }
          final again = WatchedBitField.construct(wb.serialize(), ids);
          if (!again.getVideo('tt2934286:1:5')) {
            return const Outcome.fail('round-trip lost data');
          }
          return const Outcome.pass('matches Stremio\'s format');
        }, quick: true),
        _TestCase('Stremio', 'Sync settings', () async {
          return Outcome.info(
              'progress → Stremio: ${_stremio.syncEnabled.value ? 'on' : 'off'} · '
              'AniList/MAL anime → Stremio: ${_stremio.syncAnime.value ? 'on' : 'off'} · '
              'Movies & TV → AniList: ${_stremio.syncToAnilist.value ? 'on' : 'off'} · '
              'Movies & TV → Simkl: ${_stremio.syncToSimkl.value ? 'on' : 'off'}');
        }, quick: true),
        _TestCase('Stremio', 'Subtitles', () async {
          await _stremio.ensureAddons();
          final subAddons =
              _stremio.addons.where((a) => a.hasResource('subtitles')).toList();
          if (subAddons.isEmpty) {
            return const Outcome.info(
                'no subtitle addons (subtitles inside the video still work)');
          }
          final lines = <String>[];
          var total = 0;
          var failed = 0;
          for (final a in subAddons) {
            try {
              final subs = await _stremio.api
                  .subtitles(a, 'series', 'tt0903747:1:1')
                  .timeout(const Duration(seconds: 20));
              total += subs.length;
              final langs = subs.map((e) => e['lang']).toSet().length;
              lines.add('${a.name}: ${subs.length} ($langs languages)');
            } catch (e) {
              failed++;
              lines.add('${a.name}: failed');
            }
          }
          return Outcome(
              failed == subAddons.length || total == 0
                  ? SelfTestStatus.warn
                  : SelfTestStatus.pass,
              'Breaking Bad S1E1: ${lines.join(', ')}');
        }, timeout: const Duration(seconds: 60)),
        _TestCase('Stremio', 'Continue Watching items open',
            () => _needStremio(() async {
                  await _stremio.refreshContinueWatching();
                  final items = _stremio.continueWatching.take(25).toList();
                  if (items.isEmpty) return const Outcome.skip('nothing in Continue Watching');
                  final broken = <String>[];
                  final odd = <String>[];
                  for (final item in items) {
                    StremioMeta? meta;
                    try {
                      meta = await _stremio.fetchMeta(item.type, item.id);
                    } catch (_) {}
                    if (meta == null) {
                      broken.add('${item.name} (${item.id})');
                    } else if (!meta.isSingleVideo &&
                        item.videoId != null &&
                        !meta.videos.any((v) => v.id == item.videoId)) {
                      odd.add('${item.name} (${item.videoId})');
                    }
                  }
                  return Outcome(
                      broken.isEmpty && odd.isEmpty
                          ? SelfTestStatus.pass
                          : SelfTestStatus.warn,
                      '${items.length - broken.length}/${items.length} open with details'
                      '${broken.isEmpty ? '' : '\nno details from your addons: ${broken.join(', ')}'}'
                      '${odd.isEmpty ? '' : '\nepisode not in its episode list: ${odd.join(', ')}'}');
                }), timeout: const Duration(seconds: 120)),
        _TestCase('Stremio', 'Library health', () => _needStremio(() async {
              await _stremio.refreshLibrary();
              final all = {
                for (final i in [..._stremio.library, ..._stremio.continueWatching])
                  i.id: i
              }.values.toList();
              final badField = <String>[];
              for (final i in all) {
                final f = i.watchedField;
                if (f != null && f.isNotEmpty && !SelfTestRunner._watchedFieldDecodes(f)) {
                  badField.add(i.name);
                }
              }
              // Same anime saved twice (Kitsu id and IMDb id)?
              final ids = {for (final i in all) i.id: i};
              final dupes = <String>[];
              for (final k in all.where((i) => i.id.startsWith('kitsu:')).take(15)) {
                try {
                  final r = await SelfTestRunner._get(
                      'https://api.ani.zip/mappings?kitsu_id=${k.id.split(':')[1]}');
                  if (r.statusCode != 200) continue;
                  final imdb = jsonDecode(r.body)['mappings']?['imdb_id']?.toString();
                  final other = imdb == null ? null : ids[imdb];
                  if (other != null) dupes.add('"${k.name}" (Kitsu) and "${other.name}" (IMDb)');
                } catch (_) {}
              }
              return Outcome(
                  badField.isEmpty && dupes.isEmpty
                      ? SelfTestStatus.pass
                      : SelfTestStatus.warn,
                  '${all.length} items checked'
                  '${badField.isEmpty ? '' : '\nwatched marks unreadable: ${badField.join(', ')}'}'
                  '${dupes.isEmpty ? '' : '\nsaved twice: ${dupes.join('; ')}. Remove one from Continue Watching / Library.'}');
            }), timeout: const Duration(seconds: 120)),

        // ---- Sync & mapping ------------------------------------------------
        _TestCase('Sync', 'AniList → Stremio mapping (Frieren)', () async {
          final d = await _stremio.describeAnimeMapping(ServicesType.anilist, '154587', 3);
          return Outcome.pass('AniList 154587 ep 3 → $d');
        }),
        _TestCase('Sync', 'AniList → Stremio mapping (your current anime)', () async {
          final h = _handler;
          if (h == null || !h.anilistService.isLoggedIn.value) {
            return const Outcome.skip('AniList not logged in');
          }
          final watching = h.anilistService.animeList
              .where((m) => (m.watchingStatus ?? '').toUpperCase() == 'CURRENT')
              .take(5)
              .toList();
          if (watching.isEmpty) return const Outcome.skip('nothing in Watching');
          final lines = <String>[];
          var mapped = 0;
          for (final m in watching) {
            var ep = (int.tryParse(m.episodeCount ?? '') ?? 0) + 1;
            final total = int.tryParse(m.totalEpisodes ?? '') ?? 0;
            if (total > 0 && ep > total) ep = total;
            try {
              final d = await _stremio.describeAnimeMapping(
                  ServicesType.anilist, m.id ?? '', ep);
              lines.add('✓ ${m.title}: $d');
              mapped++;
            } catch (e) {
              lines.add('✗ ${m.title}: $e');
            }
          }
          return Outcome(
              mapped == watching.length
                  ? SelfTestStatus.pass
                  : (mapped == 0 ? SelfTestStatus.fail : SelfTestStatus.warn),
              '$mapped/${watching.length} would sync to Stremio\n${lines.join('\n')}');
        }, timeout: const Duration(seconds: 90)),
        _TestCase('Sync', 'Anime → Stremio addon streams (your current anime)',
            () async {
          final h = _handler;
          if (h == null || !h.anilistService.isLoggedIn.value) {
            return const Outcome.skip('AniList not logged in');
          }
          await _stremio.ensureAddons();
          if (!_stremio.hasStreamAddons) {
            return const Outcome.skip('no Stremio stream addons installed');
          }
          final watching = h.anilistService.animeList
              .where((m) => (m.watchingStatus ?? '').toUpperCase() == 'CURRENT')
              .take(4)
              .toList();
          if (watching.isEmpty) return const Outcome.skip('nothing in Watching');
          final lines = <String>[];
          var ok = 0;
          for (final m in watching) {
            final media = await h.anilistService
                .fetchDetails(FetchDetailsParams(id: m.id ?? ''));
            final t = await _stremio.animeTarget(media);
            if (t == null) {
              lines.add('✗ ${m.title}: no Kitsu/IMDb id your stream addons accept');
              continue;
            }
            ok++;
            final ep = (int.tryParse(m.episodeCount ?? '') ?? 0) + 1;
            final next = t.episodes.length >= ep ? t.episodes[ep - 1].link : null;
            lines.add('✓ ${m.title}: ${t.libraryId} (${t.isMovie ? 'movie' : '${t.episodes.length} eps'})'
                '${next != null ? ', next ep → $next' : ''} via ${t.addonNames.join(', ')}');
          }
          return Outcome(
              ok == watching.length
                  ? SelfTestStatus.pass
                  : SelfTestStatus.warn,
              '$ok/${watching.length} can play from Stremio addons\n${lines.join('\n')}');
        }, timeout: const Duration(seconds: 120)),
        _TestCase('Stremio', 'Info tab sources', () async {
          final lines = <String>[];
          var bad = 0;
          for (final (type, id, label) in const [
            ('series', 'tt0903747', 'Breaking Bad'),
            ('movie', 'tt0111161', 'The Shawshank Redemption'),
            ('series', 'tt0213338', 'Cowboy Bebop (anime)'),
          ]) {
            final meta = await _stremio.fetchMeta(type, id);
            if (meta == null) {
              bad++;
              lines.add('✗ $label: no metadata');
              continue;
            }
            final info = await StremioInfoLoader.load(meta);
            final extra = ' (${info.castCount} cast'
                '${info.castCount > 0 && !info.castHasPhotos ? ', no photos' : ''}'
                '${info.source == StremioInfoSource.stremio ? ', ${info.facts.length} facts' : ''})';
            lines.add('✓ $label: ${info.sourceLabel}$extra');
            if (id == 'tt0213338' && info.source != StremioInfoSource.anilist) {
              bad++;
            }
          }
          return Outcome(bad == 0 ? SelfTestStatus.pass : SelfTestStatus.warn,
              lines.join('\n'));
        }, timeout: const Duration(seconds: 90)),
        _TestCase('Sync', 'Movie matching (The Garden of Words)', () async {
          final h = _handler;
          if (h == null) return const Outcome.skip('services not loaded');
          await _stremio.ensureAddons();
          final media = await h.anilistService
              .fetchDetails(FetchDetailsParams(id: '16782'));
          final sync =
              await _stremio.describeAnimeMapping(ServicesType.anilist, '16782', 1);
          if (!_stremio.hasStreamAddons) {
            return Outcome.pass('sync → $sync (no stream addons to check)');
          }
          final t = await _stremio.animeTarget(media);
          if (t == null) {
            return Outcome.warn('sync → $sync\nno stream addon accepts its ids');
          }
          final link = t.episodes.isEmpty ? '' : t.episodes.first.link ?? '';
          final ok = t.isMovie &&
              t.episodes.length == 1 &&
              StremioIds.typeForVideoId(link) == 'movie';
          return Outcome(ok ? SelfTestStatus.pass : SelfTestStatus.fail,
              'streams → ${t.isMovie ? 'movie' : 'series'} $link via ${t.addonNames.join(', ')}\n'
              'sync → $sync');
        }, timeout: const Duration(seconds: 60)),
        _TestCase('Sync', 'Kitsu → AniList mapping', () async {
          final id = await _stremio.debugAnilistFromKitsu('1');
          return id == null
              ? const Outcome.fail('Kitsu 1 (Cowboy Bebop) did not resolve')
              : Outcome.pass('Kitsu 1 → AniList $id');
        }),
        _TestCase('Sync', 'IMDb → AniList mapping', () async {
          final ids = await _stremio.debugAnilistFromImdb('tt0213338');
          return ids.isEmpty
              ? const Outcome.fail('IMDb tt0213338 (Cowboy Bebop) did not resolve')
              : Outcome.pass('IMDb tt0213338 → AniList ${ids.join(', ')}');
        }),

      ];
}
