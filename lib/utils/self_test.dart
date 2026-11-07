// AnymeX+ self test: checks the app, its services and integrations, and
// writes a report file. "Quick" runs the essential checks (~10-20 s);
// "Full" also runs every network/addon/mapping/performance check.
//
// Tests never change your accounts: Stremio/AniList checks are read-only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anymex/controllers/discord/discord_rpc.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/screens/stremio/stremio_info_tab.dart';
import 'package:anymex/controllers/services/stremio/watched_bitfield.dart';
import 'package:anymex/controllers/services/torrent/torrent_service.dart';
import 'package:anymex/controllers/source/source_controller.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/services/commentum_service.dart';
import 'package:anymex/utils/color_extractor.dart';
import 'package:anymex/utils/updater.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

enum SelfTestStatus { pass, warn, fail, skip, info }

class SelfTestResult {
  final String group;
  final String name;
  final SelfTestStatus status;
  final String detail;
  final Duration duration;
  final String? error;

  SelfTestResult({
    required this.group,
    required this.name,
    required this.status,
    required this.detail,
    required this.duration,
    this.error,
  });

  String get symbol => switch (status) {
        SelfTestStatus.pass => 'PASS',
        SelfTestStatus.warn => 'WARN',
        SelfTestStatus.fail => 'FAIL',
        SelfTestStatus.skip => 'SKIP',
        SelfTestStatus.info => 'INFO',
      };
}

/// What a test returns: a status and a human-readable detail line.
class Outcome {
  final SelfTestStatus status;
  final String detail;
  const Outcome(this.status, this.detail);
  const Outcome.pass(this.detail) : status = SelfTestStatus.pass;
  const Outcome.warn(this.detail) : status = SelfTestStatus.warn;
  const Outcome.fail(this.detail) : status = SelfTestStatus.fail;
  const Outcome.skip(this.detail) : status = SelfTestStatus.skip;
  const Outcome.info(this.detail) : status = SelfTestStatus.info;
}

class _TestCase {
  final String group;
  final String name;
  final bool quick;
  final Duration timeout;
  final Future<Outcome> Function() run;

  _TestCase(this.group, this.name, this.run,
      {this.quick = false, this.timeout = const Duration(seconds: 25)});
}

class SelfTestRunner extends GetxController {
  final RxList<SelfTestResult> results = <SelfTestResult>[].obs;
  final RxBool running = false.obs;
  final RxString current = ''.obs;
  final RxInt total = 0.obs;
  final RxString reportPath = ''.obs;
  bool _cancel = false;
  DateTime? _started;
  bool _comprehensive = false;

  void cancel() => _cancel = true;

  int count(SelfTestStatus s) => results.where((r) => r.status == s).length;

  Future<String?> run({required bool comprehensive}) async {
    if (running.value) return null;
    _cancel = false;
    _comprehensive = comprehensive;
    running.value = true;
    results.clear();
    reportPath.value = '';
    _started = DateTime.now();
    final tests = _tests().where((t) => comprehensive || t.quick).toList();
    total.value = tests.length;
    for (final t in tests) {
      if (_cancel) break;
      current.value = '${t.group} › ${t.name}';
      final sw = Stopwatch()..start();
      SelfTestResult r;
      try {
        final o = await t.run().timeout(t.timeout);
        r = SelfTestResult(
          group: t.group,
          name: t.name,
          status: o.status,
          detail: o.detail,
          duration: sw.elapsed,
        );
      } on TimeoutException {
        r = SelfTestResult(
          group: t.group,
          name: t.name,
          status: SelfTestStatus.fail,
          detail: 'Timed out after ${t.timeout.inSeconds}s',
          duration: sw.elapsed,
        );
      } catch (e, st) {
        r = SelfTestResult(
          group: t.group,
          name: t.name,
          status: SelfTestStatus.fail,
          detail: e.toString(),
          duration: sw.elapsed,
          error: st.toString().split('\n').take(8).join('\n'),
        );
      }
      results.add(r);
    }
    current.value = '';
    final path = await _writeReport();
    reportPath.value = path ?? '';
    running.value = false;
    return path;
  }

  // ---------------------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------------------

  Future<Directory> reportDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}AnymeX+ Self Tests');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> buildReport() async {
    final b = StringBuffer();
    final info = await PackageInfo.fromPlatform();
    final now = DateTime.now();
    b.writeln('AnymeX+ self test report');
    b.writeln('=' * 60);
    b.writeln('Mode:      ${_comprehensive ? 'Full (comprehensive)' : 'Quick'}');
    b.writeln('Date:      ${now.toIso8601String()}');
    b.writeln('Duration:  ${_started == null ? '-' : now.difference(_started!).inMilliseconds / 1000}s');
    b.writeln('App:       ${info.appName} ${info.version} (build ${info.buildNumber})');
    b.writeln('Package:   ${info.packageName}');
    b.writeln('Platform:  ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    b.writeln('Locale:    ${Platform.localeName}');
    b.writeln('Dart:      ${Platform.version.split(' ').first}');
    b.writeln('Mode:      ${kReleaseMode ? 'release' : 'debug'}');
    b.writeln();
    b.writeln('Summary:   ${count(SelfTestStatus.pass)} passed, '
        '${count(SelfTestStatus.warn)} warnings, '
        '${count(SelfTestStatus.fail)} failed, '
        '${count(SelfTestStatus.skip)} skipped, '
        '${count(SelfTestStatus.info)} info '
        '(${results.length}/${total.value} run${_cancel ? ', cancelled' : ''})');
    b.writeln();

    final failures = results
        .where((r) =>
            r.status == SelfTestStatus.fail || r.status == SelfTestStatus.warn)
        .toList();
    if (failures.isNotEmpty) {
      b.writeln('Problems');
      b.writeln('-' * 60);
      for (final r in failures) {
        b.writeln('[${r.symbol}] ${r.group} › ${r.name}: ${r.detail}');
      }
      b.writeln();
    }

    String? group;
    for (final r in results) {
      if (r.group != group) {
        group = r.group;
        b.writeln();
        b.writeln('## $group');
      }
      final ms = r.duration.inMilliseconds.toString().padLeft(6);
      b.writeln('[${r.symbol}] ${ms}ms  ${r.name}');
      for (final line in r.detail.split('\n')) {
        if (line.trim().isNotEmpty) b.writeln('                $line');
      }
      if (r.error != null) {
        for (final line in r.error!.split('\n')) {
          b.writeln('                  $line');
        }
      }
    }
    b.writeln();
    b.writeln('(No passwords, tokens or API keys are included in this report.)');
    return b.toString();
  }

  Future<String?> _writeReport() async {
    try {
      final dir = await reportDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(
          '${dir.path}${Platform.pathSeparator}selftest-${_comprehensive ? 'full' : 'quick'}-$stamp.txt');
      await file.writeAsString(await buildReport(), flush: true);
      return file.path;
    } catch (e) {
      debugPrint('Self test: could not write report: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Future<http.Response> _get(String url,
          {Map<String, String>? headers,
          Duration timeout = const Duration(seconds: 15)}) =>
      http.get(Uri.parse(url), headers: headers).timeout(timeout);

  static Future<Outcome> _reach(String label, String url,
      {Map<String, String>? headers, List<int> ok = const [200]}) async {
    final sw = Stopwatch()..start();
    final resp = await _get(url, headers: headers);
    final ms = sw.elapsedMilliseconds;
    if (ok.contains(resp.statusCode)) {
      return Outcome(ms > 4000 ? SelfTestStatus.warn : SelfTestStatus.pass,
          '$label reachable (HTTP ${resp.statusCode}, ${ms}ms${ms > 4000 ? ', slow' : ''})');
    }
    return Outcome.fail('$label returned HTTP ${resp.statusCode} (${ms}ms)');
  }

  static String _httpHint(int code) => switch (code) {
        402 => ', host unpaid',
        404 => ', not found',
        410 => ', removed',
        >= 500 => ', server error',
        _ => '',
      };

  StremioService get _stremio => StremioService.to;
  ServiceHandler? get _handler =>
      Get.isRegistered<ServiceHandler>() ? Get.find<ServiceHandler>() : null;

  Future<Outcome> _needStremio(Future<Outcome> Function() body) async {
    if (!_stremio.isLoggedIn.value) {
      return const Outcome.skip('Not logged in to Stremio');
    }
    return body();
  }

  /// Small valid PNG (16x16, purple) for the image-decoding checks.
  /// A 48x48 PNG drawn in-app (teal with an orange square), so the check
  /// exercises the same decode path posters use.
  static Future<String> _makeTestPng() async {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 48, 48),
        ui.Paint()..color = const ui.Color(0xFF1E8C7E));
    canvas.drawRect(const ui.Rect.fromLTWH(12, 12, 16, 16),
        ui.Paint()..color = const ui.Color(0xFFE07A1F));
    canvas.drawCircle(const ui.Offset(36, 36), 6,
        ui.Paint()..color = const ui.Color(0xFF3050C0));
    final img = await rec.endRecording().toImage(48, 48);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return base64Encode(data!.buffer.asUint8List());
  }

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------

  List<_TestCase> _tests() => [
        // ---- App & device --------------------------------------------------
        _TestCase('App', 'Version & build', () async {
          final i = await PackageInfo.fromPlatform();
          return Outcome.info(
              '${i.appName} ${i.version} (build ${i.buildNumber}), ${i.packageName}');
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
          final png = await _makeTestPng();
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

        // ---- Network -------------------------------------------------------
        _TestCase('Network', 'Internet connection',
            () => _reach('github.com', 'https://api.github.com/zen',
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
            () => _reach('api.strem.io', 'https://api.strem.io/api/',
                ok: const [200, 400, 404, 405]),
            quick: true),
        _TestCase('Network', 'Cinemeta (Stremio metadata)',
            () => _reach('Cinemeta', StremioService.cinemetaUrl)),
        _TestCase('Network', 'ani.zip (anime id mapping)',
            () => _reach('api.ani.zip', 'https://api.ani.zip/mappings?anilist_id=21')),
        _TestCase('Network', 'ARM (Kitsu/IMDb → AniList mapping)',
            () => _reach('arm.haglund.dev',
                'https://arm.haglund.dev/api/v2/ids?source=anilist&id=21')),
        _TestCase('Network', 'Kitsu API',
            () => _reach('kitsu.io', 'https://kitsu.io/api/edge/anime/1')),
        _TestCase('Network', 'TVmaze (show info)',
            () => _reach('api.tvmaze.com',
                'https://api.tvmaze.com/lookup/shows?imdb=tt0903747')),
        _TestCase('Network', 'GitHub releases (updates)',
            () => _reach('GitHub', 'https://api.github.com/repos/${UpdateManager.repo}/releases/latest',
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
          return Outcome(d.isConnected ? SelfTestStatus.pass : SelfTestStatus.warn,
              d.isConnected ? 'connected, status updates active' : 'logged in but gateway not connected');
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

        // ---- Stremio -------------------------------------------------------
        _TestCase('Stremio', 'Account', () => _needStremio(() async {
              final user = await _stremio.api.getUser(_stremio.authKey!);
              return Outcome.pass('session valid (${user['email'] ?? 'account'})');
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
        _TestCase('Stremio', 'Every addon manifest reachable', () async {
          await _stremio.ensureAddons();
          final bad = <String>[];
          final local = <String>[];
          for (final a in _stremio.addons) {
            final host = Uri.tryParse(a.transportUrl)?.host ?? '';
            final isLocal = host == '127.0.0.1' || host == 'localhost';
            try {
              final r = await _get(a.transportUrl, timeout: const Duration(seconds: 12));
              if (r.statusCode != 200) {
                bad.add('${a.name} (HTTP ${r.statusCode}${_httpHint(r.statusCode)})');
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
          for (final a in _stremio.addons) {
            for (final c in a.catalogs.where((c) => c.isBoardCatalog)) {
              try {
                final items = await _stremio.api.catalog(a, c);
                items.isEmpty ? empty.add('${a.name}/${c.name} (${c.type})') : ok++;
              } catch (e) {
                failed.add('${a.name}/${c.name} (${c.type})');
              }
            }
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
              'Movies & TV → AniList: ${_stremio.syncToAnilist.value ? 'on' : 'off'}');
        }, quick: true),

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
            final ep = (int.tryParse(m.episodeCount ?? '') ?? 0) + 1;
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
            final extra = info.source == StremioInfoSource.stremio
                ? ' (${info.facts.length} facts, ${info.cast.length} cast)'
                : '';
            lines.add('✓ $label: ${info.sourceLabel}$extra');
            if (id == 'tt0213338' && info.source != StremioInfoSource.anilist) {
              bad++;
            }
          }
          return Outcome(bad == 0 ? SelfTestStatus.pass : SelfTestStatus.warn,
              lines.join('\n'));
        }, timeout: const Duration(seconds: 90)),
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

        // ---- Comments ------------------------------------------------------
        _TestCase('Comments', 'Commentum server', () async {
          final base = (dotenv.env['COMMENTS_BASE_URL'] ?? '').trim();
          if (base.isEmpty) return const Outcome.fail('COMMENTS_BASE_URL not set');
          final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
          return _reach('Commentum', '$root/health', ok: const [200, 204]);
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
          final r = await _get(
              'https://api.github.com/repos/${UpdateManager.repo}/releases/latest',
              headers: const {'Accept': 'application/vnd.github+json'});
          if (r.statusCode != 200) return Outcome.warn('HTTP ${r.statusCode}');
          final tag = jsonDecode(r.body)['tag_name']?.toString() ?? '?';
          final info = await PackageInfo.fromPlatform();
          final latest = tag.replaceFirst('v', '');
          return Outcome(latest == info.version ? SelfTestStatus.pass : SelfTestStatus.info,
              'installed ${info.version} · latest $tag'
              '${latest == info.version ? ' (up to date)' : ''}');
        }, quick: true),

        // ---- Playback & extensions ----------------------------------------
        _TestCase('Playback', 'Torrent engine', () async {
          final installed = await TorrentService.instance.addon.isInstalled();
          return Outcome(installed ? SelfTestStatus.pass : SelfTestStatus.info,
              installed
                  ? 'TorrServer available'
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
      ];
}

