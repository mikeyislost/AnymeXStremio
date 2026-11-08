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
import 'package:anymex/plus/error_log.dart';
import 'package:anymex/plus/launch_timer.dart';
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

part 'self_test_basics.dart';
part 'self_test_stremio.dart';
part 'self_test_other.dart';

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
    await PlusErrorLog.ensureLoaded();
    if (PlusErrorLog.entries.isNotEmpty) {
      b.writeln();
      b.writeln(PlusErrorLog.report());
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
        ..._basicTests(),
        ..._stremioTests(),
        ..._otherTests(),
      ];
}

