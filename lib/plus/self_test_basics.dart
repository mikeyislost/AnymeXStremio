// AnymeX+: part of the Self Test. App, device, logic, network and account checks.

part of 'self_test.dart';

extension SelfTestBasics on SelfTestRunner {
  List<_TestCase> _basicTests() => [
        // ---- App & device --------------------------------------------------
        _TestCase('App', 'Launch time', () async {
          final first = LaunchTimer.firstFrame;
          final home = LaunchTimer.home;
          if (first == null) return Outcome.info('Not measured yet');
          final parts = ['first screen in ${first.inMilliseconds} ms'];
          if (home != null) {
            parts.add('Home in ${(home.inMilliseconds / 1000).toStringAsFixed(1)} s'
                ' (includes the splash screen)');
          }
          return Outcome.info(parts.join(' · '));
        }, quick: true),
        _TestCase('App', 'Version & build', () async {
          final i = await PackageInfo.fromPlatform();
          return Outcome.info(
              '${AppChannel.appName} ${await AppChannel.version()} (build ${i.buildNumber}), ${i.packageName}');
        }, quick: true),
        _TestCase('App', 'Device', () async {
          final d = DeviceInfoPlugin();
          if (Platform.isIOS) {
            final i = await d.iosInfo;
            return Outcome.info(
                '${i.utsname.machine} · ${i.systemName} ${i.systemVersion} · '
                '${i.isPhysicalDevice ? 'physical' : 'simulator'}');
          }
          if (Platform.isWindows) {
            final w = await d.windowsInfo;
            return Outcome.info(
                '${w.productName} (build ${w.buildNumber}) · ${w.numberOfCores} cores · '
                '${(w.systemMemoryInMegabytes / 1024).toStringAsFixed(1)} GB RAM');
          }
          if (Platform.isAndroid) {
            final a = await d.androidInfo;
            return Outcome.info('${a.manufacturer} ${a.model} · Android ${a.version.release}');
          }
          return Outcome.info(Platform.operatingSystemVersion);
        }, quick: true),
        _TestCase('App', 'Build configuration (.env keys)', () async {
          const keys = {
            'AL_CLIENT_ID': 'AniList login',
            'AL_CLIENT_SECRET': 'AniList login',
            'COMMENTS_BASE_URL': 'Comments',
            'MAL_CLIENT_ID': 'MyAnimeList login (optional)',
            'SIMKL_CLIENT_ID': 'Simkl login (optional)',
            'TMDB_API_KEY': 'TMDB metadata (optional)',
          };
          final missing = <String>[];
          final present = <String>[];
          keys.forEach((k, why) {
            final v = (dotenv.env[k] ?? '').trim();
            (v.isEmpty ? missing : present).add('$k ($why)');
          });
          final requiredMissing =
              missing.where((m) => !m.contains('optional')).toList();
          final detail = 'present: ${present.map((e) => e.split(' ').first).join(', ')}'
              '${missing.isEmpty ? '' : '\nmissing: ${missing.join(', ')}'}';
          return requiredMissing.isEmpty
              ? Outcome.pass(detail)
              : Outcome.warn(detail);
        }, quick: true),
        _TestCase('App', 'Settings storage (write/read/delete)', () async {
          const key = 'anymexplus_selftest_probe';
          final value = 'probe-${DateTime.now().millisecondsSinceEpoch}';
          KvHelper.set(key, value);
          final read = KvHelper.get<String?>(key);
          KvHelper.remove(key);
          if (read != value) return Outcome.fail('read back "$read"');
          return const Outcome.pass('database round-trip ok');
        }, quick: true),
        _TestCase('App', 'File system (app folders)', () async {
          final docs = await getApplicationDocumentsDirectory();
          final support = await getApplicationSupportDirectory();
          final tmp = await getTemporaryDirectory();
          final f = File('${tmp.path}${Platform.pathSeparator}anymexplus_probe.txt');
          await f.writeAsString('ok', flush: true);
          final back = await f.readAsString();
          await f.delete();
          if (back != 'ok') return const Outcome.fail('temp file round-trip failed');
          return Outcome.pass('documents: ${docs.path}\nsupport: ${support.path}');
        }, quick: true),
        _TestCase('App', 'Image decoding (poster color extractor)', () async {
          // Regression check for the iOS crash fixed in this build.
          final png = await SelfTestRunner._makeTestPng();
          ImageColorExtractor.clearCachedColor(png);
          final c = await ImageColorExtractor.extractColor(png, isBase64: true);
          return c == null
              ? const Outcome.warn('test image decoded but no color came back')
              : Outcome.pass('decoded test image, color #${c.toARGB32().toRadixString(16).substring(2)}');
        }, quick: true),
        _TestCase('App', 'Settings storage speed', () async {
          const key = 'anymexplus_selftest_speed';
          final sw = Stopwatch()..start();
          for (var i = 0; i < 200; i++) {
            KvHelper.set(key, i);
            KvHelper.get<int>(key);
          }
          KvHelper.remove(key);
          final ms = sw.elapsedMilliseconds;
          return Outcome(ms > 3000 ? SelfTestStatus.warn : SelfTestStatus.pass,
              '200 write+read pairs in ${ms}ms');
        }),
        _TestCase('App', 'Device clock', () async {
          final r = await SelfTestRunner._get('https://api.github.com/zen');
          final date = r.headers['date'];
          if (date == null) return const Outcome.skip('server sent no time');
          final skew =
              DateTime.now().toUtc().difference(HttpDate.parse(date)).inSeconds;
          if (skew.abs() > 120) {
            return Outcome.warn('your clock is ${skew.abs()}s '
                '${skew > 0 ? 'ahead' : 'behind'}; logins and debrid links can fail');
          }
          return Outcome.pass('within ${skew.abs()}s of internet time');
        }, quick: true),
        _TestCase('App', 'Storage used by the app', () async {
          final docs = await getApplicationDocumentsDirectory();
          final support = await getApplicationSupportDirectory();
          final tmp = await getTemporaryDirectory();
          final lines = <String>[];
          var cacheBytes = 0;
          for (final (label, dir) in [
            ('documents', docs),
            ('app data', support),
            ('cache', tmp),
          ]) {
            final (bytes, files) = await SelfTestRunner._dirSize(dir);
            if (label == 'cache') cacheBytes = bytes;
            lines.add('$label: ${SelfTestRunner._mb(bytes)} in $files files');
          }
          return Outcome(
              cacheBytes > 3 * 1024 * 1024 * 1024
                  ? SelfTestStatus.warn
                  : SelfTestStatus.pass,
              '${lines.join(' · ')}'
              '${cacheBytes > 3 * 1024 * 1024 * 1024 ? '\ncache is large; clearing it in Settings frees space' : ''}');
        }, timeout: const Duration(seconds: 60)),
        _TestCase('App', 'Watch history database', () async {
          if (!Get.isRegistered<OfflineStorageController>()) {
            return const Outcome.skip('history not loaded');
          }
          final c = Get.find<OfflineStorageController>();
          final anime = c.getAnimeLibrarySync();
          final manga = c.getMangaLibrarySync();
          final novels = c.getNovelLibrarySync();
          final stremio =
              anime.where((m) => (m.mediaId ?? '').startsWith('stremio|')).length;
          final fromAddons =
              anime.where((m) => m.currentEpisode?.source == 'Stremio').length;
          return Outcome.pass('anime: ${anime.length} (Movies & TV: $stremio, '
              'played from Stremio addons: $fromAddons) · manga: ${manga.length} · '
              'novels: ${novels.length}');
        }, quick: true),
        _TestCase('App', 'Settings snapshot', () async {
          final ps = Get.find<Settings>().playerSettings.value;
          return Outcome.info(
              'player: ${ps.defaultPortraitMode ? 'portrait' : ps.defaultOrientation} · '
              'decoder ${ps.hardwareDecoder} · marked watched at ${ps.markAsCompleted}% · '
              'auto-skip OP ${ps.autoSkipOP ? 'on' : 'off'} / ED ${ps.autoSkipED ? 'on' : 'off'}\n'
              'anime streams from: ${_stremio.animeStreamSource.value} · '
              'episode cards: ${EpisodeStyleRegistry.currentStyleId.value}');
        }, quick: true),
        _TestCase('App', 'Recent errors in the app log', () async {
          final logs = await Logger.getLogs();
          if (logs.trim().isEmpty) {
            return const Outcome.info('log is empty (file logging may be off)');
          }
          final lines = logs.split('\n');
          final recent =
              lines.length > 800 ? lines.sublist(lines.length - 800) : lines;
          // Skip AnymeX's routine "Key … not found" lookups and empty
          // stack lines; group repeats of the same message.
          final noise = RegExp(r'\] Key .+ not found$|\[ERROR\] STACK:\s*$');
          final errors = recent
              .where((l) =>
                  (l.contains('[ERROR]') ||
                      l.contains('[WARNING]') ||
                      l.contains('Exception')) &&
                  !noise.hasMatch(l.trim()))
              .toList();
          if (errors.isEmpty) {
            return Outcome.pass(
                'no real errors in the last ${recent.length} log lines');
          }
          final counts = <String, int>{};
          final lastTime = <String, String>{};
          for (final l in errors) {
            final m = RegExp(r'^\[(\d\d:\d\d:\d\d)\](.*)$').firstMatch(l);
            final msg = SelfTestRunner._redact((m?.group(2) ?? l).trim());
            counts[msg] = (counts[msg] ?? 0) + 1;
            lastTime[msg] = m?.group(1) ?? '';
          }
          final newest = counts.keys.toList().reversed.take(10).map((msg) {
            final short = msg.length > 220 ? '${msg.substring(0, 220)}…' : msg;
            final n = counts[msg]!;
            return '[${lastTime[msg]}] $short${n > 1 ? '  (×$n)' : ''}';
          });
          return Outcome.info(
              '${errors.length} error lines (${counts.length} different) in the last '
              '${recent.length}; newest:\n${newest.join('\n')}');
        }, quick: true),

        // ---- Logic (offline checks of AnymeX+ code) ----------------------
        _TestCase('Logic', 'Episode labels', () async => SelfTestRunner._expect({
              'tt0903747:1:2 → S1 E2': () =>
                  stremioEpisodeLabel('tt0903747:1:2') == 'S1 E2',
              'kitsu:49803:1 → E1': () =>
                  stremioEpisodeLabel('kitsu:49803:1') == 'E1',
              'movie ids have no label': () =>
                  stremioEpisodeLabel('tt0111161') == null &&
                  stremioEpisodeLabel('kitsu:7311') == null,
            }), quick: true),
        _TestCase('Logic', 'Stremio ids', () async => SelfTestRunner._expect({
              'media id round-trip': () =>
                  StremioIds.parse(StremioIds.mediaId('series', 'tt0903747',
                      season: 2)) ==
                  ('series', 'tt0903747'),
              'AniList ids are not Stremio ids': () =>
                  !StremioIds.isStremioMediaId('21'),
              'kitsu:1:5 is a series episode': () =>
                  StremioIds.typeForVideoId('kitsu:1:5') == 'series',
              'kitsu:1 is a movie': () =>
                  StremioIds.typeForVideoId('kitsu:1') == 'movie',
              'tt1:1:2 is a series episode': () =>
                  StremioIds.typeForVideoId('tt1:1:2') == 'series',
            }), quick: true),
        _TestCase('Logic', 'Movie detection & runtimes', () async {
          final one = [Episode(number: '1')];
          return SelfTestRunner._expect({
            'AniList MOVIE with 1 entry is a movie': () => isMovieMedia(
                Media(format: 'MOVIE', serviceType: ServicesType.anilist), one),
            'TV is not a movie': () => !isMovieMedia(
                Media(format: 'TV', serviceType: ServicesType.anilist), one),
            'movie split in 2 parts shows episodes': () => !isMovieMedia(
                Media(format: 'MOVIE', serviceType: ServicesType.anilist),
                [Episode(number: '1'), Episode(number: '2')]),
            '"46 mins" → 46m': () => formatMovieRuntime('46 mins') == '46m',
            '"106 min" → 1h 46m': () => formatMovieRuntime('106 min') == '1h 46m',
            '"1 hr 46 min" → 1h 46m': () =>
                formatMovieRuntime('1 hr 46 min') == '1h 46m',
            '"?" → empty': () => formatMovieRuntime('?') == '',
          });
        }, quick: true),
        _TestCase('Logic', 'Torrent file index', () async {
          final (url, idx) = StremioPlayerBridge.splitTorrentFileIndex(
              'magnet:?xt=urn:btih:abc&anymex_fidx=2');
          final (_, none) =
              StremioPlayerBridge.splitTorrentFileIndex('magnet:?xt=urn:btih:abc');
          return SelfTestRunner._expect({
            'marker removed': () => url == 'magnet:?xt=urn:btih:abc',
            'Stremio file 2 → TorrServer file 3': () => idx == 3,
            'no marker → no file': () => none == null,
          });
        }, quick: true),
        _TestCase('Logic', 'Player rotation sides', () async => SelfTestRunner._expect({
              'iPhone turned left → landscapeRight': () =>
                  landscapeForTilt(true, ios: true) ==
                  DeviceOrientation.landscapeRight,
              'iPhone turned right → landscapeLeft': () =>
                  landscapeForTilt(false, ios: true) ==
                  DeviceOrientation.landscapeLeft,
              'Android unchanged': () =>
                  landscapeForTilt(true, ios: false) ==
                  DeviceOrientation.landscapeLeft,
            }), quick: true),

        // ---- Network -------------------------------------------------------
        _TestCase('Network', 'Internet connection',
            () => SelfTestRunner._reach('github.com', 'https://api.github.com/zen',
                ok: const [200, 403, 429]),
            quick: true),
        _TestCase('Network', 'AniList API',
            () async {
              final sw = Stopwatch()..start();
              final r = await http
                  .post(Uri.parse('https://graphql.anilist.co'),
                      headers: const {
                        'Content-Type': 'application/json',
                        'Accept': 'application/json'
                      },
                      body: jsonEncode({'query': '{ Media(id: 1) { id } }'}))
                  .timeout(const Duration(seconds: 15));
              final ms = sw.elapsedMilliseconds;
              if (r.statusCode == 200) {
                return Outcome.pass('graphql.anilist.co reachable (${ms}ms)');
              }
              if (r.statusCode == 429) {
                return Outcome.warn('AniList is rate-limiting right now (HTTP 429)');
              }
              return Outcome.fail('graphql.anilist.co returned HTTP ${r.statusCode} (${ms}ms)');
            },
            quick: true),
        _TestCase('Network', 'Stremio API',
            () => SelfTestRunner._reach('api.strem.io', 'https://api.strem.io/api/',
                ok: const [200, 400, 404, 405]),
            quick: true),
        _TestCase('Network', 'Cinemeta (Stremio metadata)',
            () => SelfTestRunner._reach('Cinemeta', StremioService.cinemetaUrl)),
        _TestCase('Network', 'ani.zip (anime id mapping)',
            () => SelfTestRunner._reach('api.ani.zip', 'https://api.ani.zip/mappings?anilist_id=21')),
        _TestCase('Network', 'ARM (Kitsu/IMDb → AniList mapping)',
            () => SelfTestRunner._reach('arm.haglund.dev',
                'https://arm.haglund.dev/api/v2/ids?source=anilist&id=21')),
        _TestCase('Network', 'Kitsu API',
            () => SelfTestRunner._reach('kitsu.io', 'https://kitsu.io/api/edge/anime/1')),
        _TestCase('Network', 'TVmaze (show info)',
            () => SelfTestRunner._reach('api.tvmaze.com',
                'https://api.tvmaze.com/lookup/shows?imdb=tt0903747'),
            optional: true),
        _TestCase('Network', 'TMDB API (your key)', () async {
          final key = (dotenv.env['TMDB_API_KEY'] ?? '').trim();
          if (key.isEmpty) return const Outcome.skip('TMDB_API_KEY not set');
          final r = await SelfTestRunner._get(
              'https://api.themoviedb.org/3/configuration?api_key=$key');
          if (r.statusCode == 200) return const Outcome.pass('key accepted');
          if (r.statusCode == 401) {
            return Outcome.fail('TMDB rejected the key (HTTP 401). Use the '
                'short "API Key", not the long "API Read Access Token"'
                '${key.length > 40 ? '; yours looks like the access token' : ''}.');
          }
          return Outcome.warn('HTTP ${r.statusCode}');
        }, quick: true),
        _TestCase('Network', 'Simkl API (your key)', () async {
          if (SimklAuthV2.clientId == null) {
            return const Outcome.skip('SIMKL_CLIENT_ID not set');
          }
          final found = await StremioInfoLoader.simklIdForImdb('tt0903747');
          if (found == null) {
            return const Outcome.fail(
                'Simkl did not resolve IMDb tt0903747; check SIMKL_CLIENT_ID');
          }
          final r = await http
              .get(
                  SimklAuthV2.withAppParams(
                      Uri.parse('https://api.simkl.com/tv/${found.$2}')),
                  headers: SimklAuthV2.baseHeaders)
              .timeout(const Duration(seconds: 15));
          if (r.statusCode == 200) {
            return Outcome.pass('client id accepted (Breaking Bad → Simkl ${found.$2})');
          }
          if (r.statusCode == 401 || r.statusCode == 412) {
            return Outcome.fail(
                'Simkl rejected SIMKL_CLIENT_ID (HTTP ${r.statusCode})');
          }
          return Outcome.warn('HTTP ${r.statusCode}');
        }, quick: true),
        _TestCase('Network', 'AniSkip (skip intro/outro)',
            () => SelfTestRunner._reach('api.aniskip.com',
                'https://api.aniskip.com/v2/skip-times/1/1?types[]=op&types[]=ed&episodeLength=0',
                ok: const [200, 404]),
            optional: true),
        _TestCase('Network', 'AnimeThemes (openings/endings)',
            () => SelfTestRunner._reach('api.animethemes.moe',
                'https://api.animethemes.moe/anime?page[size]=1'),
            optional: true),
        _TestCase('Network', 'Jikan (MyAnimeList data)',
            () => SelfTestRunner._reach('api.jikan.moe', 'https://api.jikan.moe/v4/anime/1',
                ok: const [200, 429]),
            optional: true),
        _TestCase('Network', 'DNS lookups', () async {
          const hosts = [
            'graphql.anilist.co',
            'api.strem.io',
            'v3-cinemeta.strem.io',
            'api.ani.zip',
            'api.github.com',
            'api.themoviedb.org',
            'api.simkl.com',
          ];
          final lines = <String>[];
          var failed = 0;
          var slow = 0;
          for (final h in hosts) {
            final sw = Stopwatch()..start();
            try {
              await InternetAddress.lookup(h).timeout(const Duration(seconds: 8));
              final ms = sw.elapsedMilliseconds;
              if (ms > 1500) slow++;
              lines.add('$h ${ms}ms');
            } catch (_) {
              failed++;
              lines.add('$h FAILED');
            }
          }
          return Outcome(
              failed > 0
                  ? SelfTestStatus.fail
                  : (slow > 0 ? SelfTestStatus.warn : SelfTestStatus.pass),
              lines.join(' · '));
        }),
        _TestCase('Network', 'GitHub releases (updates)',
            () => SelfTestRunner._reach('GitHub', 'https://api.github.com/repos/${UpdateManager.repo}/releases/latest',
                headers: const {'Accept': 'application/vnd.github+json'})),

        // ---- Accounts ------------------------------------------------------
        _TestCase('Accounts', 'AniList', () async {
          final h = _handler;
          if (h == null) return const Outcome.fail('service handler missing');
          final a = h.anilistService;
          if (!a.isLoggedIn.value) return const Outcome.warn('not logged in');
          final name = a.profileData.value.name ?? '?';
          return Outcome.pass('logged in as $name · ${a.animeList.length} anime in list');
        }, quick: true),
        _TestCase('Accounts', 'MyAnimeList / Simkl', () async {
          final h = _handler;
          if (h == null) return const Outcome.fail('service handler missing');
          return Outcome.info(
              'MyAnimeList: ${h.malService.isLoggedIn.value ? 'logged in' : 'not logged in'} · '
              'Simkl: ${h.simklService.isLoggedIn.value ? 'logged in' : 'not logged in'} · '
              'active service: ${h.serviceType.value.name}');
        }, quick: true),
        _TestCase('Accounts', 'Discord status', () async {
          if (!Get.isRegistered<DiscordRPCController>()) {
            return const Outcome.skip('Discord not initialised');
          }
          final d = DiscordRPCController.instance;
          if (!d.isLoggedIn) return const Outcome.info('not connected (optional)');
          if (d.isConnected) {
            return const Outcome.pass('connected, status updates active');
          }
          final code = d.lastCloseCode;
          return Outcome.warn('logged in but not connected right now'
              '${code != null ? ' (Discord closed the connection, code $code)' : ''}; '
              'it reconnects by itself, and when something plays');
        }, quick: true),
        _TestCase('Accounts', 'AniList login still valid', () async {
          final token = AuthKeys.authToken.get<String?>();
          if (token == null || token.isEmpty) {
            return const Outcome.skip('not logged in to AniList');
          }
          final r = await http
              .post(Uri.parse('https://graphql.anilist.co'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    'Authorization': 'Bearer $token',
                  },
                  body: jsonEncode({'query': '{ Viewer { name } }'}))
              .timeout(const Duration(seconds: 15));
          if (r.statusCode == 200) {
            final name = jsonDecode(r.body)['data']?['Viewer']?['name'];
            return Outcome.pass('token works (signed in as $name)');
          }
          if (r.statusCode == 400 || r.statusCode == 401) {
            return const Outcome.fail(
                'AniList refused the saved login; log out and back in');
          }
          return Outcome.warn('HTTP ${r.statusCode}');
        }, quick: true),
        _TestCase('Accounts', 'Simkl login still valid', () async {
          final token = AuthKeys.simklAuthToken.get<String?>();
          if (token == null || token.isEmpty) {
            return const Outcome.skip('not logged in to Simkl');
          }
          final client = SimklHttpClient(http.Client());
          try {
            final r = await client
                .post(Uri.parse('https://api.simkl.com/users/settings'),
                    headers: {
                      'Content-Type': 'application/json',
                      'Authorization': 'Bearer $token',
                    })
                .timeout(const Duration(seconds: 15));
            if (r.statusCode != 200) {
              return Outcome.fail('Simkl refused the saved login (HTTP '
                  '${r.statusCode}); log out and back in');
            }
            final name = jsonDecode(r.body)['user']?['name'];
            final exp = SimklAuthV2.expiresAt;
            return Outcome.pass('signed in as $name'
                '${exp == null ? '' : ' · renews automatically (current token until ${exp.toLocal().toString().split('.').first})'}');
          } finally {
            client.close();
          }
        }, quick: true),
        _TestCase('Accounts', 'AniList API query', () async {
          final resp = await http
              .post(Uri.parse('https://graphql.anilist.co'),
                  headers: const {'Content-Type': 'application/json'},
                  body: jsonEncode({'query': '{ Media(id: 21) { id title { romaji } } }'}))
              .timeout(const Duration(seconds: 15));
          if (resp.statusCode != 200) {
            return Outcome.fail('HTTP ${resp.statusCode}');
          }
          final t = jsonDecode(resp.body)['data']?['Media']?['title']?['romaji'];
          return Outcome.pass('query ok ("$t")');
        }),

      ];
}
