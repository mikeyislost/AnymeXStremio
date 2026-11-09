import 'dart:io';

import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/services/cast/cast_proxy_server.dart';
import 'package:anymex/services/cast/cast_service.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AnymeX+: AirPlay on iPhone (Apple TV and AirPlay 2 TVs such as LG).
/// mpv draws the video itself, so AirPlay hands the stream to Apple's
/// player (ios/Runner/AppDelegate.swift, `PlusAirPlay`) and the AnymeX
/// player picks up where it left off when that closes.
class PlusAirPlay {
  static const _channel = MethodChannel('anymexplus/airplay');

  /// Chromecasts found with Bonjour. iOS blocks the raw multicast search
  /// AnymeX uses elsewhere for sideloaded apps, Bonjour isn't blocked.
  static Future<List<CastDevice>> findChromecasts() async {
    if (!Platform.isIOS) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('findChromecasts');
      return [
        for (final d in raw ?? const [])
          if (d is Map && d['host'] is String)
            CastDevice(
              id: 'chromecast-${d['host']}-${d['port'] ?? 8009}',
              name: (d['name'] as String?) ?? 'Chromecast (${d['host']})',
              host: d['host'] as String,
              port: (d['port'] as num?)?.toInt() ?? 8009,
              protocol: CastProtocol.chromecast,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Plays [url] with Apple's player and opens the AirPlay list.
  /// Returns where playback stopped, or throws a [PlatformException].
  static Future<Duration> play({
    required String url,
    Map<String, String>? headers,
    String? title,
    Duration start = Duration.zero,
  }) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('play', {
      'url': url,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
      'title': title,
      'positionMs': start.inMilliseconds,
    });
    return Duration(milliseconds: (res?['positionMs'] as num?)?.toInt() ?? 0);
  }
}

/// "AirPlay" row at the top of the Cast to Device sheet (iPhone only).
class PlusAirPlayTile extends StatefulWidget {
  final PlayerController controller;
  const PlusAirPlayTile({super.key, required this.controller});

  @override
  State<PlusAirPlayTile> createState() => _PlusAirPlayTileState();
}

class _PlusAirPlayTileState extends State<PlusAirPlayTile> {
  bool _loading = false;

  Future<void> _start() async {
    final c = widget.controller;
    final video = c.selectedVideo.value;
    final url = video?.url ?? c.offlineVideoPath;
    if (url == null || url.isEmpty || _loading) return;

    final wasPlaying = c.isPlaying.value;
    final title = c.anilistData.title.isNotEmpty
        ? c.anilistData.title
        : (c.currentEpisode.value.title ?? 'AnymeX+');
    final headers = video?.headers;
    final isLocal = url.startsWith('/') || url.startsWith('file:');

    // The TV fetches the video itself and can't send the source's headers,
    // so streams that need them go through the phone's cast proxy.
    var playUrl = url;
    var proxied = false;
    if (!isLocal && headers != null && headers.isNotEmpty) {
      final p = await CastProxyServer.startProxy(originalUrl: url, headers: headers);
      if (p != null && p != url) {
        playUrl = p;
        proxied = true;
      }
    }

    setState(() => _loading = true);
    c.pause();
    try {
      final stoppedAt = await PlusAirPlay.play(
        url: playUrl,
        headers: proxied ? null : headers,
        title: title,
        start: c.currentPosition.value,
      );
      if (stoppedAt > Duration.zero) c.seekTo(stoppedAt);
      if (mounted) Navigator.of(context).maybePop();
    } on PlatformException catch (e) {
      if (wasPlaying) c.play();
      snackBar(
        e.code == 'unsupported'
            ? "AirPlay can't play this video's format (often MKV). Try another stream, or use Screen Mirroring."
            : (e.message ?? "AirPlay didn't start"),
        duration: 4000,
        maxLines: 3,
      );
    } finally {
      if (proxied) await CastProxyServer.stopProxy();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
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
          'Apple TV and AirPlay TVs (LG, Samsung, Sony…)',
          size: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        trailing: _loading
            ? const SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right_rounded),
        onTap: _start,
      ),
    );
  }
}
