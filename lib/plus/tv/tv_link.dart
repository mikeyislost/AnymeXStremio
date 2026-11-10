import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/airplay.dart';
import 'package:anymex/plus/tv/lg_link.dart';
import 'package:get/get.dart';

/// AnymeX+: the link between this app and the AnymeX+ TV app (LG webOS).
///
/// Once the TV Remote page or "Play on TV" has been used, the app runs a
/// small server on the home network. The TV app connects to it; from then on this app sends remote
/// presses and "play this" requests, and the TV reports what it is doing.
/// The TV learns this device's address either from LG's phone link (the app
/// opens the TV app and passes the address along) or by typing it on the TV.
enum PlusTvStatus { off, waiting, connected }

/// A TV found on the network.
class PlusTvDevice {
  final String host;
  final String name;
  const PlusTvDevice(this.host, this.name);
}

class PlusTvLink {
  PlusTvLink._();
  static final instance = PlusTvLink._();

  /// The TV app's id (tv/appinfo.json).
  static const appId = 'com.mikeyislost.anymexplus.tv';
  static const defaultPort = 41733;
  static const _kToken = 'plus_tv_link_token';

  final status = PlusTvStatus.off.obs;
  final localIp = ''.obs;
  final port = 0.obs;

  /// What the TV told us about itself when it connected.
  final tvInfo = <String, dynamic>{}.obs;

  /// The TV's latest report (screen, highlighted item, player).
  final tvState = <String, dynamic>{}.obs;
  final tvAddress = ''.obs;

  /// Asked when a TV connects without the shared key (typed address).
  Future<bool> Function(String tvIp)? askAllow;

  /// Gives the TV a subtitle file as WebVTT text (`/sub/<name>.vtt`); set
  /// by Play on TV. Null result = not found.
  Future<String?> Function(String name)? subtitleProvider;

  HttpServer? _server;
  WebSocket? _tv;

  bool get isConnected => status.value == PlusTvStatus.connected;

  /// A key the TV has to show to connect without a question. It is made
  /// once and handed to the TV when the app opens it.
  static String get token {
    var t = '';
    try {
      t = KvHelper.get<String>(_kToken, defaultVal: '');
    } catch (_) {}
    if (t.isEmpty) {
      final r = Random.secure();
      t = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      KvHelper.set(_kToken, t);
    }
    return t;
  }

  /// This device's address on the home network, from a list of
  /// (interface name, address). Wi-Fi and wired names win over others
  /// (VPNs, virtual adapters), private addresses over public ones.
  static String pickLocalIp(List<(String, String)> addresses) {
    var best = '';
    var bestScore = -1;
    for (final (name, ip) in addresses) {
      if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
      var score = 0;
      final n = name.toLowerCase();
      if (n == 'en0' || n.contains('wi-fi') || n.contains('wifi') || n.contains('wlan')) {
        score += 4;
      } else if (n.contains('ethernet') || n.startsWith('eth') || n.startsWith('en')) {
        score += 3;
      }
      if (ip.startsWith('192.168.')) {
        score += 3;
      } else if (ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
        score += 2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = ip;
      }
    }
    return best;
  }

  static Future<String> _findLocalIp() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      return pickLocalIp([
        for (final i in list)
          for (final a in i.addresses) (i.name, a.address),
      ]);
    } catch (_) {
      return '';
    }
  }

  /// Starts listening for the TV app. Safe to call again.
  Future<void> start() async {
    localIp.value = await _findLocalIp();
    if (_server != null) return;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, defaultPort, shared: true);
    } catch (_) {
      // Something else has the usual port: any free one works for TVs the
      // app opens itself (typing the address on the TV needs the usual one).
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    port.value = server.port;
    if (status.value == PlusTvStatus.off) status.value = PlusTvStatus.waiting;
    server.listen((req) async {
      try {
        if (req.uri.path == '/tv' && WebSocketTransformer.isUpgradeRequest(req)) {
          final ip = req.connectionInfo?.remoteAddress.address ?? '';
          final ws = await WebSocketTransformer.upgrade(req);
          unawaited(_onSocket(ws, ip));
        } else if (req.uri.pathSegments.length == 2 && req.uri.pathSegments.first == 'sub') {
          // The TV app is a web page: it may only read this with these headers.
          req.response.headers.set('Access-Control-Allow-Origin', '*');
          final name = req.uri.pathSegments[1].replaceAll('.vtt', '');
          final vtt = await subtitleProvider?.call(name);
          if (vtt == null) {
            req.response.statusCode = HttpStatus.notFound;
          } else {
            req.response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
            req.response.write(vtt);
          }
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      } catch (_) {}
    }, onError: (_) {});
  }

  /// Stops listening and drops the TV.
  Future<void> stop() async {
    final tv = _tv;
    _tv = null;
    try {
      await tv?.close();
    } catch (_) {}
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    port.value = 0;
    status.value = PlusTvStatus.off;
    tvState.clear();
  }

  Future<void> _onSocket(WebSocket ws, String ip) async {
    ws.pingInterval = const Duration(seconds: 15);
    var accepted = false;
    ws.listen((raw) async {
      Map<String, dynamic> m;
      try {
        final d = jsonDecode(raw as String);
        if (d is! Map) return;
        m = Map<String, dynamic>.from(d);
      } catch (_) {
        return;
      }
      final type = m['t'];
      if (!accepted) {
        if (type != 'hello' || m['app'] != 'anymexplus-tv') return;
        var ok = m['token'] is String && m['token'] == token;
        if (!ok && askAllow != null) {
          try {
            ok = await askAllow!(ip);
          } catch (_) {
            ok = false;
          }
        }
        if (!ok) {
          _sendTo(ws, {'t': 'denied'});
          await ws.close();
          return;
        }
        accepted = true;
        final old = _tv;
        _tv = ws;
        try {
          await old?.close();
        } catch (_) {}
        final info = m['info'];
        tvInfo.assignAll(info is Map ? Map<String, dynamic>.from(info) : {});
        tvAddress.value = ip;
        tvState.clear();
        status.value = PlusTvStatus.connected;
        if (PlusCastSearch.isIp(ip)) PlusCastSearch.saveHost(ip);
        _sendTo(ws, {'t': 'welcome', 'name': deviceName, 'token': token});
        return;
      }
      if (type == 'state') tvState.assignAll(m);
    }, onDone: () {
      if (identical(_tv, ws)) {
        _tv = null;
        tvState.clear();
        status.value = _server == null ? PlusTvStatus.off : PlusTvStatus.waiting;
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  static String get deviceName {
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isAndroid) return 'phone';
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'computer';
    }
  }

  void _sendTo(WebSocket ws, Map<String, dynamic> msg) {
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  void _send(Map<String, dynamic> msg) {
    final ws = _tv;
    if (ws != null) _sendTo(ws, msg);
  }

  /// A remote press: up, down, left, right, ok, back.
  void key(String k) => _send({'t': 'key', 'k': k});

  /// Plays [url] in the TV's own player. [subtitle] is a second line under
  /// the title, [start] where to begin, [kind] the file type (mkv, mp4,
  /// hls…) and [id] comes back in the TV's reports about this video.
  void play(String url, {String title = '', String subtitle = '', Duration start = Duration.zero, String kind = '', int id = 0}) =>
      _send({
        't': 'play',
        'url': url,
        'title': title,
        'sub': subtitle,
        'start': start.inMilliseconds / 1000.0,
        'kind': kind,
        'id': id,
      });

  /// toggle, play, pause, seekBy ([by] seconds), seekTo ([to] seconds),
  /// audio ([index] of the track), sub ([url] of a subtitle file with its
  /// [label], or [index] of one inside the video, or neither for off).
  void player(String cmd, {num? by, num? to, int? index, String? url, String? label}) => _send({
        't': 'player',
        'cmd': cmd,
        if (by != null) 'by': by,
        if (to != null) 'to': to,
        if (index != null) 'i': index,
        if (url != null) 'url': url,
        if (label != null) 'label': label,
      });

  /// Where the TV can fetch the subtitle called [name] from this device.
  String subtitleUrl(String name) => 'http://${localIp.value}:${port.value}/sub/$name.vtt';

  /// Listens again after the app was in the background long enough for the
  /// system to close the server. The TV app keeps retrying the same address.
  Future<void> restart() async {
    if (_server == null) return start();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    await start();
  }

  void stopVideo() => _send({'t': 'stop'});

  void disconnect() {
    final ws = _tv;
    _tv = null;
    tvState.clear();
    if (status.value == PlusTvStatus.connected) status.value = PlusTvStatus.waiting;
    try {
      ws?.close();
    } catch (_) {}
  }

  /// LG TVs on the network: AirPlay TVs (found on iPhone) and TVs added by
  /// IP address, kept when they answer on LG's phone-link port.
  Future<List<PlusTvDevice>> findTvs() async {
    final named = <String, String>{};
    try {
      for (final d in await PlusAirPlay.findAirPlayDevices()) {
        named[d.$1] = d.$2;
      }
    } catch (_) {}
    for (final ip in PlusCastSearch.savedHosts()) {
      named.putIfAbsent(ip, () => 'LG TV ($ip)');
    }
    final found = <PlusTvDevice>[];
    await Future.wait(named.entries.map((e) async {
      if (await PlusLgTv.isLgTv(e.key)) found.add(PlusTvDevice(e.key, e.value));
    }));
    found.sort((a, b) => a.name.compareTo(b.name));
    return found;
  }

  /// Opens the AnymeX+ TV app on the TV at [host] and tells it where this
  /// device is. The first time, the TV asks to allow this device
  /// ([onPrompt] is called then).
  Future<void> openOnTv(String host, {void Function()? onPrompt}) async {
    await start();
    if (localIp.value.isEmpty) {
      throw Exception("This device isn't on a home network");
    }
    final lg = await PlusLgTv.connect(host, onPrompt: onPrompt);
    try {
      await lg.request('system.launcher/launch', {
        'id': appId,
        'params': {'host': localIp.value, 'port': port.value, 'token': token},
      });
      PlusCastSearch.saveHost(host);
    } finally {
      await lg.close();
    }
  }

  /// The TV's details and latest report as text, for sending along.
  String report() => buildReport(tvInfo, tvState, tvAddress.value);

  static String buildReport(Map<String, dynamic> info, Map<String, dynamic> state, String address) {
    final b = StringBuffer('AnymeX+ TV report\n');
    b.writeln('TV address: $address');
    for (final k in const [
      'app', 'model', 'sdkVersion', 'platformVersion', 'firmware', 'chrome', 'screen', 'window',
      'network', 'ip', 'uhd', 'audioTracksApi', 'systemInfoError',
    ]) {
      if (info[k] != null) b.writeln('$k: ${info[k]}');
    }
    final can = info['canPlay'];
    if (can is Map) {
      // The browser's own guess; "played" below is what really worked.
      b.writeln('canPlay: ${can.entries.where((e) => e.key != 'mkv').map((e) => '${e.key}=${e.value}').join(', ')}');
    }
    final played = state['played'] ?? info['played'];
    if (played is Map && played.isNotEmpty) {
      b.writeln('played: ${played.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
    }
    if (info['userAgent'] != null) b.writeln('userAgent: ${info['userAgent']}');
    if (state.isNotEmpty) {
      b.writeln('screen now: ${state['screen']} · presses: ${state['presses']}');
      final p = state['player'];
      if (p is Map) {
        b.writeln('player: ${jsonEncode(p)}');
      }
    }
    return b.toString();
  }
}
