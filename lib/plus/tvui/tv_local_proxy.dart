import 'dart:async';
import 'dart:io';

import 'package:anymex/plus/tv/tv_proxy.dart';
import 'package:anymex/utils/logger.dart';

/// AnymeX+ TV: the TV's own link proxy, on 127.0.0.1.
///
/// LG's video player can't send headers (Referer, User-Agent…), and only
/// treats a link as HLS when "m3u8" is in it. Links like that go through
/// [PlusTvProxy] (the same code the phone uses for "Play on TV"), served
/// here on the TV itself, so nothing else has to be on.
class TvLocalProxy {
  TvLocalProxy._();
  static final instance = TvLocalProxy._();

  HttpServer? _server;
  Future<void>? _starting;

  Future<void> _start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.autoCompress = false;
    _server = s;
    PlusTvProxy.instance.base = () => 'http://127.0.0.1:${s.port}';
    s.listen((req) async {
      try {
        if (!await PlusTvProxy.instance.handle(req)) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
    Logger.i('TV proxy on 127.0.0.1:${s.port}');
  }

  Future<void> ready() async {
    if (_server != null) return;
    _starting ??= _start();
    try {
      await _starting;
    } catch (e) {
      _starting = null;
      rethrow;
    }
  }

  /// What the TV's player opens for [url]: the link itself when it can,
  /// else the proxy's address. [kind] is hls, mp4, mkv… or '' if unknown.
  Future<({String url, String kind})> route(String url, Map<String, String> headers) async {
    var kind = PlusTvProxy.guessFromUrl(url);
    final needsHeaders = headers.isNotEmpty;
    if (kind.isEmpty && url.startsWith('http')) {
      kind = (await PlusTvProxy.instance.probe(url, headers)).kind;
    }
    final hlsHidden = kind == 'hls' && !url.contains('m3u8');
    if (!needsHeaders && !hlsHidden) return (url: url, kind: kind);
    try {
      await ready();
    } catch (e) {
      Logger.i('TV proxy failed to start: $e');
      return (url: url, kind: kind);
    }
    final key = PlusTvProxy.instance.register(url, headers);
    return (url: PlusTvProxy.instance.videoUrl(key, kind), kind: kind);
  }
}
