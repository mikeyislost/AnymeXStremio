import 'dart:async';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/services/cast/cast_proxy_server.dart';
import 'package:anymex/services/cast/cast_service.dart';
import 'package:anymex/plus/tv/tv_play.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// AnymeX+: casting extras.
/// - AirPlay on iPhone (Apple TV and AirPlay 2 TVs such as LG): a hidden
///   Apple player (ios/Runner/AppDelegate.swift, `PlusAirPlay`) sends the
///   video to the TV and the cast sheet shows our own remote. mpv draws the
///   video itself, so AirPlay can't come from it.
/// - Finding TVs on iPhone: iOS blocks the network-wide search for
///   sideloaded apps, so Chromecasts and AirPlay TVs are found with Bonjour
///   and each TV is then asked directly for DLNA (that's allowed). DLNA lets
///   an LG play MKV files itself.
/// - "Add a TV by IP address" for TVs that still don't show up.
class PlusAirPlay {
  static const _channel = MethodChannel('anymexplus/airplay');

  static Future<List<Map>> _bonjour(String method) async {
    if (!Platform.isIOS) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>(method);
      return [for (final d in raw ?? const []) if (d is Map && d['host'] is String) d];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<CastDevice>> findChromecasts() async {
    // A TV can answer on two addresses (e.g. wired and Wi-Fi): keep one per name.
    final seen = <String>{};
    return [
        for (final d in await _bonjour('findChromecasts'))
          if (seen.add((d['name'] as String?) ?? d['host'] as String))
          CastDevice(
            id: 'chromecast-${d['host']}-8009',
            name: (d['name'] as String?) ?? 'Chromecast (${d['host']})',
            host: d['host'] as String,
            port: (d['port'] as num?)?.toInt() ?? 8009,
            protocol: CastProtocol.chromecast,
          ),
      ];
  }

  /// AirPlay TVs as (host, name).
  static Future<List<(String, String)>> findAirPlayDevices() async => [
        for (final d in await _bonjour('findAirPlay'))
          (d['host'] as String, (d['name'] as String?) ?? 'TV (${d['host']})'),
      ];

  static Future<List<String>> findAirPlayHosts() async =>
      [for (final d in await findAirPlayDevices()) d.$1];

  /// Loads the video in Apple's (hidden) player and opens the AirPlay list.
  /// Throws a [PlatformException] when it can't play (e.g. MKV).
  static Future<void> start({
    required String url,
    Map<String, String>? headers,
    String? title,
    Duration start = Duration.zero,
  }) =>
      _channel.invokeMethod('start', {
        'url': url,
        if (headers != null && headers.isNotEmpty) 'headers': headers,
        'title': title,
        'positionMs': start.inMilliseconds,
      });

  static Future<Map> status() async =>
      (await _channel.invokeMapMethod<String, dynamic>('status')) ?? const {};
  static Future<void> play() => _channel.invokeMethod('play');
  static Future<void> pause() => _channel.invokeMethod('pause');
  static Future<void> seek(Duration d) =>
      _channel.invokeMethod('seek', {'positionMs': d.inMilliseconds});
  static Future<void> pickRoute() => _channel.invokeMethod('pickRoute');
  static Future<Duration> stop() async =>
      Duration(milliseconds: (await _channel.invokeMethod<int>('stop')) ?? 0);
}

/// TVs asked directly for DLNA instead of searching the whole network.
class PlusCastSearch {
  static const _kHosts = 'plus_cast_tv_ips';

  static List<String> savedHosts() {
    try {
      return List<String>.from(KvHelper.get<List<String>>(_kHosts, defaultVal: const []));
    } catch (_) {
      return const [];
    }
  }

  static void saveHost(String ip) {
    final list = savedHosts()..remove(ip);
    KvHelper.set(_kHosts, [ip, ...list].take(5).toList());
  }

  static void removeHost(String ip) => KvHelper.set(_kHosts, savedHosts()..remove(ip));

  static bool isIp(String s) => RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s.trim());

  /// (host, description URL) for DLNA renderers on AirPlay TVs (iPhone)
  /// and on TVs added by IP address.
  static Future<List<(String, String)>> dlnaLocations() async {
    final hosts = {...savedHosts(), ...await PlusAirPlay.findAirPlayHosts()};
    if (hosts.isEmpty) return const [];
    return askDirectly(hosts);
  }

  /// SSDP search sent straight to each address (no multicast needed).
  static Future<List<(String, String)>> askDirectly(Iterable<String> hosts) async {
    final found = <String, String>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = socket?.receive();
        if (d == null) return;
        final text = String.fromCharCodes(d.data);
        final loc = RegExp(r'LOCATION:\s*(http://[^\r\n]+)', caseSensitive: false)
            .firstMatch(text)
            ?.group(1)
            ?.trim();
        if (loc != null) found.putIfAbsent(d.address.address, () => loc);
      });
      for (var round = 0; round < 2; round++) {
        for (final h in hosts) {
          final ip = InternetAddress.tryParse(h);
          if (ip == null) continue;
          for (final st in const [
            'urn:schemas-upnp-org:device:MediaRenderer:1',
            'urn:schemas-upnp-org:service:AVTransport:1',
          ]) {
            final q = 'M-SEARCH * HTTP/1.1\r\nHOST: $h:1900\r\n'
                'MAN: "ssdp:discover"\r\nMX: 1\r\nST: $st\r\n\r\n';
            socket.send(q.codeUnits, ip, 1900);
          }
        }
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    } catch (_) {
    } finally {
      socket?.close();
    }
    return [for (final e in found.entries) (e.key, e.value)];
  }
}

/// Waits until a Google Cast device reports the default media receiver
/// running (TVs take a few seconds to open it), up to 20 s.
Future<void> plusWaitForCastReceiver(Stream<Map<String, dynamic>> messages) async {
  try {
    await messages.firstWhere((m) {
      if (m['type'] != 'RECEIVER_STATUS') return false;
      final status = m['status'];
      final apps = status is Map ? status['applications'] : null;
      return apps is List &&
          apps.any((a) => a is Map && a['appId'] == 'CC1AD845' && a['transportId'] != null);
    }).timeout(const Duration(seconds: 20));
    // Give the receiver a moment after the connection is set up.
    await Future.delayed(const Duration(milliseconds: 400));
  } catch (_) {}
}

/// The TV refused the video (Google Cast LOAD_FAILED).
void plusCastLoadFailed(String device) => snackBar(
      "$device couldn't play this video. Try another stream, or AirPlay if it isn't an MKV.",
      duration: 5000,
      maxLines: 3,
    );

/// File type from the address (".mkv" → Matroska), for DLNA TVs.
String? plusMimeFromPath(String url) {
  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  const types = {
    '.mkv': 'video/x-matroska',
    '.webm': 'video/webm',
    '.avi': 'video/x-msvideo',
    '.mp4': 'video/mp4',
    '.m4v': 'video/mp4',
    '.mov': 'video/quicktime',
    '.ts': 'video/mp2t',
  };
  for (final e in types.entries) {
    if (path.endsWith(e.key)) return e.value;
  }
  return null;
}

/// File type of a stream: from its address, else from what the server says.
Future<String> plusDetectMime(String url, Map<String, String>? headers) async {
  final byPath = plusMimeFromPath(url);
  if (byPath != null || url.startsWith('/') || url.startsWith('file:')) {
    return byPath ?? 'video/mp4';
  }
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url))
      ..headers.addAll(headers ?? const {})
      ..headers['range'] = 'bytes=0-0';
    final resp = await client.send(req).timeout(const Duration(seconds: 4));
    final type = (resp.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    final disp = resp.headers['content-disposition'] ?? '';
    unawaited(resp.stream.listen((_) {}).cancel());
    final name = RegExp(r'filename\*?=(?:UTF-8'')?"?([^";]+)', caseSensitive: false)
        .firstMatch(disp)
        ?.group(1);
    final byName = name == null ? null : plusMimeFromPath(name);
    if (byName != null) return byName;
    if (type.startsWith('video/') && type != 'video/octet-stream') return type;
    if (type.contains('matroska')) return 'video/x-matroska';
  } catch (_) {
  } finally {
    client.close();
  }
  return 'video/mp4';
}

/// The AirPlay session and the remote's state.
class PlusAirPlayRemote {
  PlusAirPlayRemote._();
  static final instance = PlusAirPlayRemote._();

  final active = false.obs;
  final external = false.obs;
  final playing = false.obs;
  final route = ''.obs;
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;
  final loading = false.obs;

  PlayerController? _controller;
  bool _proxied = false;
  Timer? _poll;

  Future<void> start(PlayerController c) async {
    final video = c.selectedVideo.value;
    final url = video?.url ?? c.offlineVideoPath;
    if (url == null || url.isEmpty || loading.value) return;
    if (active.value) await stop();

    final wasPlaying = c.isPlaying.value;
    final title = c.anilistData.title.isNotEmpty
        ? c.anilistData.title
        : (c.currentEpisode.value.title ?? 'AnymeX+');
    final headers = video?.headers;
    final isLocal = url.startsWith('/') || url.startsWith('file:');

    loading.value = true;
    c.pause();
    // The TV fetches the video itself and can't send the source's headers,
    // so streams that need them go through the phone's cast proxy.
    var playUrl = url;
    _proxied = false;
    if (!isLocal && headers != null && headers.isNotEmpty) {
      final p = await CastProxyServer.startProxy(originalUrl: url, headers: headers);
      if (p != null && p != url) {
        playUrl = p;
        _proxied = true;
      }
    }
    try {
      await PlusAirPlay.start(
        url: playUrl,
        headers: _proxied ? null : headers,
        title: title,
        start: c.currentPosition.value,
      );
      _controller = c;
      position.value = c.currentPosition.value;
      duration.value = c.episodeDuration.value;
      active.value = true;
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    } on PlatformException catch (e) {
      if (_proxied) await CastProxyServer.stopProxy();
      _proxied = false;
      if (wasPlaying) c.play();
      snackBar(
        e.code == 'unsupported'
            ? "AirPlay can't play this file type (often MKV). Pick your TV's Google Cast or DLNA entry instead."
            : (e.message ?? "AirPlay didn't start"),
        duration: 4000,
        maxLines: 3,
      );
    } finally {
      loading.value = false;
    }
  }

  Future<void> _refresh() async {
    try {
      final s = await PlusAirPlay.status();
      if (s['active'] != true) {
        await _ended(Duration.zero);
        return;
      }
      external.value = s['external'] == true;
      playing.value = s['playing'] == true;
      route.value = (s['route'] as String?) ?? '';
      position.value = Duration(milliseconds: (s['positionMs'] as num?)?.toInt() ?? 0);
      final d = (s['durationMs'] as num?)?.toInt() ?? 0;
      if (d > 0) duration.value = Duration(milliseconds: d);
    } catch (_) {}
  }

  Future<void> togglePlay() async {
    playing.value ? await PlusAirPlay.pause() : await PlusAirPlay.play();
    playing.toggle();
  }

  Future<void> seek(Duration d) async {
    position.value = d;
    await PlusAirPlay.seek(d);
  }

  Future<void> skip(int seconds) {
    final max = duration.value > Duration.zero ? duration.value : const Duration(days: 1);
    final next = position.value + Duration(seconds: seconds);
    return seek(next < Duration.zero ? Duration.zero : (next > max ? max : next));
  }

  /// Stops AirPlay; the app's player picks up where the TV stopped.
  Future<void> stop() async {
    Duration at = Duration.zero;
    try {
      at = await PlusAirPlay.stop();
    } catch (_) {}
    await _ended(at);
  }

  Future<void> _ended(Duration at) async {
    _poll?.cancel();
    _poll = null;
    if (!active.value) return;
    active.value = false;
    external.value = false;
    playing.value = false;
    if (_proxied) await CastProxyServer.stopProxy();
    _proxied = false;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed && at > Duration.zero) c.seekTo(at);
  }
}

/// AirPlay row / remote and "Add a TV by IP address", at the top of
/// the Cast to Device sheet.
class PlusCastExtras extends StatefulWidget {
  final PlayerController controller;
  const PlusCastExtras({super.key, required this.controller});

  @override
  State<PlusCastExtras> createState() => _PlusCastExtrasState();
}

class _PlusCastExtrasState extends State<PlusCastExtras> {
  PlayerController get controller => widget.controller;

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  Future<void> _addTv(BuildContext context) async {
    final text = TextEditingController(text: PlusCastSearch.savedHosts().firstOrNull ?? '');
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a TV by IP address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "On an LG TV: Settings → All Settings → General → Network → "
              "your Wi-Fi → the IP address (like 192.168.1.20).",
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(hintText: '192.168.1.20'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, text.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    if (!PlusCastSearch.isIp(ip)) {
      snackBar("That doesn't look like an IP address");
      return;
    }
    final found = await PlusCastSearch.askDirectly([ip]);
    if (found.isEmpty) {
      snackBar(
        "The TV at $ip didn't answer. Check the TV is on and on the same Wi-Fi.",
        duration: 4000,
        maxLines: 3,
      );
      return;
    }
    PlusCastSearch.saveHost(ip);
    await CastService.instance.startDiscovery();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remote = PlusAirPlayRemote.instance;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlusTvPlayRow(controller: controller), // the AnymeX+ TV app (LG)
        if (Platform.isIOS)
          Obx(() => remote.active.value
              ? _remoteCard(theme, remote)
              : _airPlayRow(theme, remote)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _addTv(context),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text("Can't see your TV? Add it by IP address"),
          ),
        ),
      ],
    );
  }

  Widget _airPlayRow(ThemeData theme, PlusAirPlayRemote remote) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.opaque(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.airplay_rounded, color: theme.colorScheme.primary, size: 22),
      ),
      title: AnymeXText(
        'AirPlay',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
      ),
      subtitle: AnymeXText(
        'Apple TV and AirPlay TVs. For MKV files, pick your TV under Google Cast or DLNA below.',
        size: 12,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      trailing: remote.loading.value
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right_rounded),
      onTap: () => remote.start(controller),
    );
  }

  Widget _remoteCard(ThemeData theme, PlusAirPlayRemote remote) {
    final dur = remote.duration.value;
    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final pos = remote.position.value.inMilliseconds.toDouble().clamp(0.0, maxMs).toDouble();
    final where = remote.external.value
        ? (remote.route.value.isNotEmpty ? remote.route.value : 'your TV')
        : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.opaque(0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.primary.opaque(0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.airplay_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: AnymeXText(
                  where != null ? 'AirPlay · $where' : 'AirPlay · pick your TV',
                  variant: TextVariant.bold,
                  size: 14,
                ),
              ),
              TextButton(
                onPressed: PlusAirPlay.pickRoute,
                child: Text(where != null ? 'Change TV' : 'Pick TV'),
              ),
            ],
          ),
          Slider(
            value: pos,
            max: maxMs,
            onChanged: (v) => remote.position.value = Duration(milliseconds: v.toInt()),
            onChangeEnd: (v) => remote.seek(Duration(milliseconds: v.toInt())),
          ),
          Row(
            children: [
              AnymeXText(_fmt(remote.position.value), size: 12),
              const Spacer(),
              IconButton(
                onPressed: () => remote.skip(-10),
                icon: const Icon(Icons.replay_10_rounded),
              ),
              IconButton.filled(
                onPressed: remote.togglePlay,
                icon: Icon(remote.playing.value ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              IconButton(
                onPressed: () => remote.skip(10),
                icon: const Icon(Icons.forward_10_rounded),
              ),
              IconButton(
                tooltip: 'Stop AirPlay',
                onPressed: remote.stop,
                icon: const Icon(Icons.stop_rounded),
              ),
              const Spacer(),
              AnymeXText(_fmt(dur), size: 12),
            ],
          ),
        ],
      ),
    );
  }
}
