import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/airplay.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/services/cast/cast_proxy_server.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:get/get.dart';

/// AnymeX+: play on LG webOS TVs through the TV's own remote-app connection
/// (the one LG's phone app uses: websocket on port 3001/3000). This works
/// when the TV ignores the DLNA search. The TV's media player plays the file
/// itself, MKV included. One-time "Allow" prompt on the TV; the key is kept.
/// Pairing manifest from aiowebostv (home-assistant-libs, Apache-2.0).
class PlusLgTv {
  PlusLgTv._(this.host, this._ws) {
    _sub = _ws.listen(
      (raw) {
        try {
          final m = jsonDecode(raw as String);
          if (m is Map) _messages.add(Map<String, dynamic>.from(m));
        } catch (_) {}
      },
      onDone: () => _messages.close(),
      onError: (_) => _messages.close(),
    );
  }

  final String host;
  final WebSocket _ws;
  late final StreamSubscription _sub;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  int _id = 0;

  bool get isOpen => _ws.closeCode == null;

  static const _kKeys = 'plus_lg_client_keys';

  static Map<String, dynamic> _keys() {
    try {
      return Map<String, dynamic>.from(
          KvHelper.get<Map<String, dynamic>>(_kKeys, defaultVal: const {}));
    } catch (_) {
      return {};
    }
  }

  static void _saveKey(String host, String key) =>
      KvHelper.set(_kKeys, {..._keys(), host: key});

  /// True if [host] has the LG remote-app port open (a quick check).
  static Future<bool> isLgTv(String host) async {
    for (final port in const [3001, 3000]) {
      try {
        final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 900));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Connects (wss first, then ws) and pairs. [onPrompt] is called when the
  /// TV is showing its "Allow" prompt.
  static Future<PlusLgTv> connect(String host, {void Function()? onPrompt}) async {
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    WebSocket? ws;
    Object? lastError;
    for (final uri in ['wss://$host:3001', 'ws://$host:3000']) {
      try {
        ws = await WebSocket.connect(uri, customClient: client)
            .timeout(const Duration(seconds: 5));
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (ws == null) throw Exception("Couldn't reach the TV ($lastError)");
    ws.pingInterval = const Duration(seconds: 20);
    final tv = PlusLgTv._(host, ws);
    try {
      await tv._register(signed: true, onPrompt: onPrompt);
    } on _LgRejected {
      await tv._register(signed: false, onPrompt: onPrompt);
    }
    return tv;
  }

  Future<void> _register({required bool signed, void Function()? onPrompt}) async {
    final id = 'register_${_id++}';
    final payload = _registration(signed);
    final key = _keys()[host];
    if (key is String && key.isNotEmpty) payload['client-key'] = key;
    final done = Completer<void>();
    late final StreamSubscription sub;
    sub = _messages.stream.where((m) => m['id'] == id).listen((m) {
      final type = m['type'];
      final p = m['payload'];
      if (type == 'response' && p is Map && p['pairingType'] == 'PROMPT') {
        onPrompt?.call();
      } else if (type == 'registered') {
        final k = p is Map ? p['client-key'] : null;
        if (k is String && k.isNotEmpty) _saveKey(host, k);
        if (!done.isCompleted) done.complete();
      } else if (type == 'error') {
        if (!done.isCompleted) done.completeError(_LgRejected('${m['error']}'));
      }
    }, onDone: () {
      if (!done.isCompleted) done.completeError(Exception('The TV closed the connection'));
    });
    _ws.add(jsonEncode({'type': 'register', 'id': id, 'payload': payload}));
    try {
      await done.future.timeout(const Duration(seconds: 60),
          onTimeout: () => throw Exception('Nobody accepted the prompt on the TV'));
    } finally {
      await sub.cancel();
    }
  }

  /// Sends an ssap request and returns its payload.
  Future<Map<String, dynamic>> request(String uri, [Map<String, dynamic>? payload]) async {
    final id = 'req_${_id++}';
    final f = _messages.stream
        .firstWhere((m) => m['id'] == id)
        .timeout(const Duration(seconds: 10));
    _ws.add(jsonEncode({'type': 'request', 'id': id, 'uri': 'ssap://$uri', 'payload': payload ?? {}}));
    final m = await f;
    final p = m['payload'];
    final ok = m['type'] == 'response' && (p is! Map || p['returnValue'] != false);
    if (!ok) throw Exception(m['error'] ?? (p is Map ? p['errorText'] : null) ?? 'The TV refused');
    return p is Map ? Map<String, dynamic>.from(p) : {};
  }

  Future<void> openMedia({required String url, required String title, required String mime}) =>
      request('media.viewer/open', {
        'target': url,
        'title': title,
        'description': '',
        'mimeType': mime,
        'iconSrc': '',
        'loop': false,
      });

  Future<void> close() async {
    await _sub.cancel();
    await _messages.close();
    await _ws.close();
  }

  static Map<String, dynamic> _registration(bool signed) {
    const permissions = [
      'LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'TEST_OPEN', 'TEST_PROTECTED',
      'CONTROL_AUDIO', 'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK',
      'CONTROL_INPUT_MEDIA_RECORDING', 'CONTROL_INPUT_MEDIA_PLAYBACK', 'CONTROL_INPUT_TV',
      'CONTROL_POWER', 'CONTROL_TV_SCREEN', 'READ_APP_STATUS', 'READ_CURRENT_CHANNEL',
      'READ_INPUT_DEVICE_LIST', 'READ_NETWORK_STATE', 'READ_RUNNING_APPS',
      'READ_TV_CHANNEL_LIST', 'WRITE_NOTIFICATION_TOAST', 'READ_POWER_STATE',
      'READ_COUNTRY_INFO', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD',
      'READ_INSTALLED_APPS', 'READ_SETTINGS',
    ];
    const signedPermissions = [
      'TEST_SECURE', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD',
      'READ_INSTALLED_APPS', 'READ_LGE_SDX', 'READ_NOTIFICATIONS', 'SEARCH',
      'WRITE_SETTINGS', 'WRITE_NOTIFICATION_ALERT', 'CONTROL_POWER',
      'READ_CURRENT_CHANNEL', 'READ_RUNNING_APPS', 'READ_UPDATE_INFO',
      'UPDATE_FROM_REMOTE_APP', 'READ_LGE_TV_INPUT_EVENTS', 'READ_TV_CURRENT_TIME',
    ];
    const signature = 'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbm'
        'ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR'
        '+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy'
        'aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4'
        'RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n'
        '50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM'
        '2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj'
        'oa7NQnAtw==';
    final manifest = <String, dynamic>{
      'appVersion': '1.1',
      'manifestVersion': 1,
      'permissions': signed
          ? permissions
          : ({...permissions, ...signedPermissions}.toList()..sort()),
      if (signed) 'signatures': [
        {'signature': signature, 'signatureVersion': 1}
      ],
      if (signed)
        'signed': {
          'appId': 'com.lge.test',
          'created': '20140509',
          'localizedAppNames': {'': 'LG Remote App'},
          'localizedVendorNames': {'': 'LG Electronics'},
          'permissions': signedPermissions,
          'serial': '2f930e2d2cfe083771f68e4fe7bb07',
          'vendorId': 'com.lge',
        },
    };
    return {'forcePairing': false, 'pairingType': 'PROMPT', 'manifest': manifest};
  }
}

class _LgRejected implements Exception {
  final String message;
  _LgRejected(this.message);
  @override
  String toString() => message;
}

/// An LG TV that can be played to.
class PlusLgDevice {
  final String host;
  final String name;
  const PlusLgDevice(this.host, this.name);
}

/// LG TVs and the current LG session (remote buttons).
class PlusLgRemote {
  PlusLgRemote._();
  static final instance = PlusLgRemote._();

  final tvs = <PlusLgDevice>[].obs;
  final active = Rxn<PlusLgDevice>();
  final connecting = ''.obs;
  final playing = false.obs;
  PlusLgTv? _tv;
  bool _proxied = false;

  /// LG TVs among AirPlay TVs (iPhone) and TVs added by IP.
  Future<void> search() async {
    final named = <String, String>{};
    for (final d in await PlusAirPlay.findAirPlayDevices()) {
      named[d.$1] = d.$2;
    }
    for (final ip in PlusCastSearch.savedHosts()) {
      named.putIfAbsent(ip, () => 'LG TV ($ip)');
    }
    final found = <PlusLgDevice>[];
    await Future.wait(named.entries.map((e) async {
      if (await PlusLgTv.isLgTv(e.key)) found.add(PlusLgDevice(e.key, e.value));
    }));
    found.sort((a, b) => a.name.compareTo(b.name));
    tvs.assignAll(found);
  }

  Future<void> play(PlusLgDevice tv, PlayerController c) async {
    final video = c.selectedVideo.value;
    final url = video?.url ?? c.offlineVideoPath;
    if (url == null || url.isEmpty || connecting.value.isNotEmpty) return;
    final wasPlaying = c.isPlaying.value;
    connecting.value = tv.host;
    c.pause();
    try {
      await stop(quiet: true);
      final headers = video?.headers;
      final isHls = url.contains('.m3u8');
      final isLocal = url.startsWith('/') || url.startsWith('file:');
      // The TV fetches the video itself: local files and streams that need
      // headers go through the phone's cast proxy.
      var target = url;
      _proxied = false;
      if (isLocal || (headers != null && headers.isNotEmpty)) {
        final p = await CastProxyServer.startProxy(originalUrl: url, headers: headers);
        if (p != null && p != url) {
          target = p;
          _proxied = true;
        }
      }
      final mime = isHls ? 'application/x-mpegURL' : await plusDetectMime(url, headers);
      final title = c.anilistData.title.isNotEmpty
          ? c.anilistData.title
          : (c.currentEpisode.value.title ?? 'AnymeX+');
      final lg = await PlusLgTv.connect(tv.host, onPrompt: () {
        snackBar('Choose "Allow" on your TV', duration: 6000);
      });
      _tv = lg;
      await lg.openMedia(url: target, title: title, mime: mime);
      PlusCastSearch.saveHost(tv.host);
      active.value = tv;
      playing.value = true;
      final at = c.currentPosition.value;
      if (at.inSeconds > 30) {
        snackBar("The TV starts from the beginning: skip ahead with the TV remote (you were at ${_fmt(at)})",
            duration: 6000, maxLines: 3);
      }
    } catch (e) {
      await stop(quiet: true);
      if (wasPlaying) c.play();
      snackBar("Couldn't play on ${tv.name}: $e", duration: 5000, maxLines: 3);
    } finally {
      connecting.value = '';
    }
  }

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  Future<void> _control(String uri) async {
    try {
      await _tv?.request(uri);
    } catch (e) {
      snackBar('The TV said: $e');
    }
  }

  Future<void> togglePlay() async {
    await _control(playing.value ? 'media.controls/pause' : 'media.controls/play');
    playing.toggle();
  }

  Future<void> rewind() => _control('media.controls/rewind');
  Future<void> fastForward() => _control('media.controls/fastForward');

  Future<void> stop({bool quiet = false}) async {
    final tv = _tv;
    _tv = null;
    if (tv != null) {
      try {
        await tv.request('media.controls/stop');
      } catch (_) {}
      try {
        await tv.request('media.viewer/close');
      } catch (_) {}
      await tv.close();
    }
    if (_proxied) await CastProxyServer.stopProxy();
    _proxied = false;
    active.value = null;
    playing.value = false;
  }
}
