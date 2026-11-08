// AnymeX+: part of the Self Test. Comments, updates, playback and extension checks.

part of 'self_test.dart';

extension SelfTestOther on SelfTestRunner {
  List<_TestCase> _otherTests() => [
        // ---- Comments ------------------------------------------------------
        _TestCase('Comments', 'Commentum server', () async {
          final base = (dotenv.env['COMMENTS_BASE_URL'] ?? '').trim();
          if (base.isEmpty) return const Outcome.fail('COMMENTS_BASE_URL not set');
          final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
          return SelfTestRunner._reach('Commentum', '$root/health', ok: const [200, 204]);
        }, quick: true),
        _TestCase('Comments', 'Comments for a title', () async {
          if (!Get.isRegistered<CommentumService>()) {
            return const Outcome.skip('comment service not running');
          }
          final page = await Get.find<CommentumService>()
              .fetchCommentsPage('21', page: 1, limit: 5);
          return Outcome.pass('fetched ${page.comments.length} comments for One Piece');
        }),

        // ---- Updates -------------------------------------------------------
        _TestCase('Updates', 'Latest release', () async {
          final beta = AppChannel.isBeta;
          final r = await SelfTestRunner._get(
              beta
                  ? 'https://api.github.com/repos/${UpdateManager.repo}/releases?per_page=30'
                  : 'https://api.github.com/repos/${UpdateManager.repo}/releases/latest',
              headers: const {'Accept': 'application/vnd.github+json'});
          if (r.statusCode != 200) return Outcome.warn('HTTP ${r.statusCode}');
          final body = jsonDecode(r.body);
          String tag = '?';
          if (beta && body is List) {
            tag = AppChannel.newestBeta(body)?['tag_name']?.toString() ?? '?';
          } else if (body is Map) {
            tag = body['tag_name']?.toString() ?? '?';
          }
          final installed = await AppChannel.version();
          final latest = tag.replaceFirst('v', '');
          final channel = beta ? 'latest beta' : 'latest';
          return Outcome(latest == installed ? SelfTestStatus.pass : SelfTestStatus.info,
              'installed $installed · $channel $tag'
              '${latest == installed ? ' (up to date)' : ''}');
        }, quick: true),

        // ---- Playback & extensions ----------------------------------------
        _TestCase('Playback', 'Torrent engine', () async {
          final addon = TorrentService.instance.addon;
          final installed = await addon.isInstalled();
          return Outcome(installed ? SelfTestStatus.pass : SelfTestStatus.info,
              installed
                  ? 'TorrServer available (${addon.isRunning ? 'running now' : 'starts when a torrent plays'})'
                  : 'TorrServer not set up yet (installs on first torrent stream)');
        }),
        _TestCase('Extensions', 'Installed sources', () async {
          if (!Get.isRegistered<SourceController>()) {
            return const Outcome.info('extension system not loaded');
          }
          final s = Get.find<SourceController>();
          return Outcome.info('anime: ${s.installedExtensions.length} · '
              'manga: ${s.installedMangaExtensions.length} · '
              'novel: ${s.installedNovelExtensions.length}');
        }, quick: true),
        _TestCase('Extensions', 'Each anime source: search → episodes → servers',
            () async {
          if (!Get.isRegistered<SourceController>()) {
            return const Outcome.skip('extension system not loaded');
          }
          final sources =
              Get.find<SourceController>().installedExtensions.take(5).toList();
          if (sources.isEmpty) return const Outcome.skip('no anime sources installed');
          const step = Duration(seconds: 25);
          final lines = <String>[];
          var bad = 0;
          for (final src in sources) {
            final sw = Stopwatch()..start();
            final name = src.name ?? 'source';
            try {
              final found = (await src.methods.search('One Piece', 1, []).timeout(step)).list;
              if (found.isEmpty) {
                bad++;
                lines.add('✗ $name: search found nothing');
                continue;
              }
              final detail = await src.methods.getDetail(found.first).timeout(step);
              final eps = detail.episodes ?? const [];
              if (eps.isEmpty) {
                bad++;
                lines.add('✗ $name: ${found.length} results, but no episodes');
                continue;
              }
              final servers = await src.methods.getVideoList(eps.first).timeout(step);
              if (servers.isEmpty) bad++;
              lines.add('${servers.isEmpty ? '✗' : '✓'} $name: ${found.length} results · '
                  '${eps.length} episodes · ${servers.length} servers '
                  '(${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)');
            } catch (e) {
              bad++;
              final msg = e is TimeoutException ? 'timed out' : SelfTestRunner._redact('$e');
              lines.add('✗ $name: ${msg.length > 160 ? msg.substring(0, 160) : msg}');
            }
          }
          return Outcome(
              bad == 0
                  ? SelfTestStatus.pass
                  : (bad == sources.length ? SelfTestStatus.fail : SelfTestStatus.warn),
              lines.join('\n'));
        }, timeout: const Duration(seconds: 400)),
        _TestCase('Extensions', 'Each manga/novel source: search', () async {
          if (!Get.isRegistered<SourceController>()) {
            return const Outcome.skip('extension system not loaded');
          }
          final s = Get.find<SourceController>();
          final sources = [
            ...s.installedMangaExtensions,
            ...s.installedNovelExtensions,
          ].take(6).toList();
          if (sources.isEmpty) return const Outcome.skip('no manga/novel sources installed');
          final lines = <String>[];
          var bad = 0;
          for (final src in sources) {
            try {
              final found = (await src.methods
                      .search('Solo Leveling', 1, [])
                      .timeout(const Duration(seconds: 25)))
                  .list;
              if (found.isEmpty) bad++;
              lines.add('${found.isEmpty ? '✗' : '✓'} ${src.name}: ${found.length} results');
            } catch (e) {
              bad++;
              lines.add('✗ ${src.name}: ${e is TimeoutException ? 'timed out' : 'failed'}');
            }
          }
          return Outcome(bad == 0 ? SelfTestStatus.pass : SelfTestStatus.warn,
              lines.join('\n'));
        }, timeout: const Duration(seconds: 200)),
      ];
}
