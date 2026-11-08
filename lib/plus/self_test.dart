// AnymeX+ self test: checks the app, its services and integrations, and
// writes a report file. "Quick" runs the essential checks (~10-20 s);
// "Full" also runs every network/addon/mapping/performance check.
//
// Tests never change your accounts: Stremio/AniList checks are read-only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/controllers/discord/discord_rpc.dart';
import 'package:anymex/controllers/offline/offline_storage_controller.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/database/isar_models/episode.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart'
    show landscapeForTilt;
import 'package:anymex/screens/anime/widgets/episode/episode_style_registry.dart';
import 'package:anymex/plus/movie_watch_card.dart';
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart'
    show stremioEpisodeLabel;
import 'package:anymex/utils/logger.dart';
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/service_handler/params.dart';
import 'package:anymex/plus/simkl_auth_v2.dart';
import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/stremio/ui/stremio_info_tab.dart';
import 'package:anymex/plus/stremio/watched_bitfield.dart';
import 'package:anymex/controllers/services/torrent/torrent_service.dart';
import 'package:anymex/controllers/source/source_controller.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/services/commentum_service.dart';
import 'package:anymex/utils/color_extractor.dart';
import 'package:anymex/utils/updater.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
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

  /// A third-party service only one feature needs; problems are warnings.
  final bool optional;

  _TestCase(this.group, this.name, this.run,
      {this.quick = false,
      this.timeout = const Duration(seconds: 25),
      this.optional = false});
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
    final picked = _tests().where((t) => comprehensive || t.quick).toList();
    // Keep each group together (report sections aren't split).
    final groups = <String>[];
    for (final t in picked) {
      if (!groups.contains(t.group)) groups.add(t.group);
    }
    final tests = [
      for (final g in groups) ...picked.where((t) => t.group == g),
    ];
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
          detail: 'No response within ${sw.elapsed.inSeconds}s',
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
      if (t.optional && r.status == SelfTestStatus.fail) {
        r = SelfTestResult(
          group: r.group,
          name: r.name,
          status: SelfTestStatus.warn,
          detail: '${r.detail}\n(a third-party service down on its end; '
              'only that one feature is affected)',
          duration: r.duration,
          error: r.error,
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
    b.writeln('App:       ${AppChannel.appName} ${await AppChannel.version()} (build ${info.buildNumber})');
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

  /// Removes keys/tokens from log lines before they go in the report.
  static String _redact(String line) => line
      .replaceAllMapped(
          RegExp(
              r'''((?:client_id|client_secret|api_key|apikey|access_token|refresh_token|authkey|token|secret|password|key)["']?\s*[:=]\s*["']?)([^&\s"',}]+)''',
              caseSensitive: false),
          (m) => '${m[1]}***')
      .replaceAllMapped(
          RegExp(r'(bearer\s+)\S+', caseSensitive: false), (m) => '${m[1]}***');

  /// Total size of a folder (stops after [maxFiles] files).
  static Future<(int, int)> _dirSize(Directory dir, {int maxFiles = 60000}) async {
    var bytes = 0;
    var files = 0;
    if (!await dir.exists()) return (0, 0);
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          bytes += await e.length();
        } catch (_) {}
        if (++files >= maxFiles) break;
      }
    }
    return (bytes, files);
  }

  static String _mb(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  /// Whether a Stremio watched field (`anchor:len:base64(zlib)`) decodes.
  static bool _watchedFieldDecodes(String field) {
    try {
      final parts = field.split(':');
      if (parts.length < 3) return false;
      int.parse(parts[parts.length - 2]);
      ZLibCodec().decode(base64.decode(parts.last));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Runs [checks] (description → passed?) and reports the failures.
  static Outcome _expect(Map<String, bool Function()> checks) {
    final failed = <String>[];
    checks.forEach((what, ok) {
      bool passed;
      try {
        passed = ok();
      } catch (e) {
        passed = false;
      }
      if (!passed) failed.add(what);
    });
    return failed.isEmpty
        ? Outcome.pass('${checks.length} checks ok')
        : Outcome.fail('failed: ${failed.join('; ')}');
  }

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
        _TestCase('App', 'Device clock', () async {
          final r = await _get('https://api.github.com/zen');
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
            final (bytes, files) = await _dirSize(dir);
            if (label == 'cache') cacheBytes = bytes;
            lines.add('$label: ${_mb(bytes)} in $files files');
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
            final msg = _redact((m?.group(2) ?? l).trim());
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
        _TestCase('Logic', 'Episode labels', () async => _expect({
              'tt0903747:1:2 → S1 E2': () =>
                  stremioEpisodeLabel('tt0903747:1:2') == 'S1 E2',
              'kitsu:49803:1 → E1': () =>
                  stremioEpisodeLabel('kitsu:49803:1') == 'E1',
              'movie ids have no label': () =>
                  stremioEpisodeLabel('tt0111161') == null &&
                  stremioEpisodeLabel('kitsu:7311') == null,
            }), quick: true),
        _TestCase('Logic', 'Stremio ids', () async => _expect({
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
          return _expect({
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
          return _expect({
            'marker removed': () => url == 'magnet:?xt=urn:btih:abc',
            'Stremio file 2 → TorrServer file 3': () => idx == 3,
            'no marker → no file': () => none == null,
          });
        }, quick: true),
        _TestCase('Logic', 'Player rotation sides', () async => _expect({
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
                'https://api.tvmaze.com/lookup/shows?imdb=tt0903747'),
            optional: true),
        _TestCase('Network', 'TMDB API (your key)', () async {
          final key = (dotenv.env['TMDB_API_KEY'] ?? '').trim();
          if (key.isEmpty) return const Outcome.skip('TMDB_API_KEY not set');
          final r = await _get(
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
            () => _reach('api.aniskip.com',
                'https://api.aniskip.com/v2/skip-times/1/1?types[]=op&types[]=ed&episodeLength=0',
                ok: const [200, 404]),
            optional: true),
        _TestCase('Network', 'AnimeThemes (openings/endings)',
            () => _reach('api.animethemes.moe',
                'https://api.animethemes.moe/anime?page[size]=1'),
            optional: true),
        _TestCase('Network', 'Jikan (MyAnimeList data)',
            () => _reach('api.jikan.moe', 'https://api.jikan.moe/v4/anime/1',
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
              final r = await _get(a.transportUrl, timeout: const Duration(seconds: 12));
              if (r.statusCode != 200) {
                bad.add('${a.name} (HTTP ${r.statusCode}${_httpHint(r.statusCode)})');
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
              'Movies & TV → AniList: ${_stremio.syncToAnilist.value ? 'on' : 'off'}');
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
                if (f != null && f.isNotEmpty && !_watchedFieldDecodes(f)) {
                  badField.add(i.name);
                }
              }
              // Same anime saved twice (Kitsu id and IMDb id)?
              final ids = {for (final i in all) i.id: i};
              final dupes = <String>[];
              for (final k in all.where((i) => i.id.startsWith('kitsu:')).take(15)) {
                try {
                  final r = await _get(
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
          final beta = AppChannel.isBeta;
          final r = await _get(
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
              final msg = e is TimeoutException ? 'timed out' : _redact('$e');
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

