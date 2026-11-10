import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/airplay.dart';
import 'package:anymex/plus/mkv_audio.dart';
import 'package:anymex/plus/tv/subtitle_vtt.dart';
import 'package:anymex/plus/tv/tv_anime.dart';
import 'package:anymex/plus/tv/tv_link.dart';
import 'package:anymex/screens/anime/watch/controller/player_controller.dart';
import 'package:anymex/services/cast/cast_proxy_server.dart';
import 'package:anymex/services/cast/cast_service.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// AnymeX+: "Play on TV". The video the player has open is handed to the
/// AnymeX+ TV app (LG webOS), which plays it with the TV's own player.
///
/// While that runs, the app's player is the remote: its play/pause, seek
/// bar, skip buttons, audio and subtitle pickers and next episode all act on
/// the TV, and the TV's position drives the usual progress tracking
/// (AniList, Simkl, Stremio, resume point). The hooks are in
/// `player_controller.dart` (`PlusTvPlay.instance.takes(this)`).
class PlusTvPlay with WidgetsBindingObserver {
  PlusTvPlay._();
  static final instance = PlusTvPlay._();
  static const _kLastHost = 'plus_tv_last_host';

  final link = PlusTvLink.instance;

  final active = false.obs;
  final loading = false.obs;
  final playing = false.obs;
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;

  /// Something the TV couldn't do (play the file, switch audio…).
  final problem = ''.obs;

  PlayerController? _c;
  int _id = 0;
  bool _seen = false;
  bool _endedHandled = false;
  bool _proxied = false;
  String _shownError = '';
  String _lastSub = '';
  Duration _startAt = Duration.zero;
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _workers = <Worker>[];
  final _subFiles = <String, String>{};
  final _subCache = <String, String>{};
  Map<String, String>? _headers;
  int _subCount = 0;

  // An episode the TV app asked for (plus/tv/tv_anime.dart): the player
  // that opens for it goes straight to the TV, and closes again when the
  // TV leaves its player.
  String? _autoFor;
  DateTime _autoAt = DateTime.fromMillisecondsSinceEpoch(0);
  void Function(String why)? _autoFailed;
  Route<dynamic>? _tvRoute;

  /// True while [c]'s video is on the TV: its controls then go to the TV.
  bool takes(PlayerController c) => active.value && identical(_c, c);

  // ------------------------------------------------------------- starting

  /// The TV app asked for an episode of [mediaId]; [route] is the player
  /// being opened for it. [onFailed] tells the TV why it didn't start.
  void expectFromTv(String mediaId, Route<dynamic> route, {void Function(String why)? onFailed}) {
    _autoFor = mediaId;
    _autoAt = DateTime.now();
    _autoFailed = onFailed;
    _tvRoute = route;
  }

  /// Called by the player once its video is open. When the TV app asked for
  /// this video, it goes to the TV right away.
  Future<void> playerReady(PlayerController c) async {
    final want = _autoFor;
    if (want == null || want != c.anilistData.id) return;
    final failed = _autoFailed;
    _autoFor = null;
    _autoFailed = null;
    if (DateTime.now().difference(_autoAt) > const Duration(seconds: 90)) return;
    c.plusPauseLocal();
    // Give the player a moment to land on your resume point: the TV starts
    // from where this player is.
    var saved = 0;
    try {
      saved = c.savedEpisode?.timeStampInMilliseconds ?? 0;
    } catch (_) {}
    for (var i = 0; saved > 0 && i < 15 && c.currentPosition.value == Duration.zero && !c.isClosed; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    final context = Get.context;
    if (c.isClosed || context == null) return;
    await start(c, context, fromTv: true);
    if (!takes(c)) {
      failed?.call("Your phone couldn't send the video to the TV.");
      _closeTvRoute();
    }
  }

  void _closeTvRoute() {
    final r = _tvRoute;
    _tvRoute = null;
    try {
      if (r != null && r.isActive) r.navigator?.removeRoute(r);
    } catch (_) {}
  }

  /// Closes the player this device opened for the TV. False when the open
  /// player is one you opened yourself (it is left alone).
  Future<bool> closeTvPlayer() async {
    final r = _tvRoute;
    if (r == null || !r.isActive) return !Get.isRegistered<PlayerController>();
    if (active.value) link.stopVideo();
    await _finish(Duration.zero);
    _closeTvRoute();
    for (var i = 0; i < 20 && Get.isRegistered<PlayerController>(); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return !Get.isRegistered<PlayerController>();
  }

  Future<void> start(PlayerController c, BuildContext context, {bool fromTv = false}) async {
    if (loading.value) return;
    final url = c.selectedVideo.value?.url ?? c.offlineVideoPath;
    if (url == null || url.isEmpty) return;
    if (c.isTorrentStream.value) {
      snackBar("Torrents can't play on the TV yet. Pick a debrid or direct stream.", duration: 4000, maxLines: 3);
      return;
    }
    loading.value = true;
    try {
      await link.start();
      if (link.localIp.value.isEmpty) {
        snackBar("This device isn't on your home network");
        return;
      }
      if (!link.isConnected) {
        final host = await _pickTv(context);
        if (host == null) return;
        await link.openOnTv(
          host,
          onPrompt: () =>
              snackBar('Look at the TV and choose Yes to allow this device', duration: 5000, maxLines: 3),
        );
        KvHelper.set(_kLastHost, host);
        if (!await _waitConnected(const Duration(seconds: 20))) {
          snackBar(
            "The AnymeX+ TV app didn't connect. Check it's installed on the TV and both are on the same network.",
            duration: 5000,
            maxLines: 3,
          );
          return;
        }
      } else if (!fromTv) {
        unawaited(_bringToFront());
      }
      if (PlusAirPlayRemote.instance.active.value) await PlusAirPlayRemote.instance.stop();
      if (CastService.instance.isCasting.value) await CastService.instance.stopCasting();

      final at = c.currentPosition.value;
      c.pause();
      _begin(c);
      await _send(c, url: url, headers: c.selectedVideo.value?.headers, start: at);
    } catch (e) {
      await _finish(Duration.zero);
      snackBar("Couldn't start on the TV: ${_clean(e)}", duration: 5000, maxLines: 3);
    } finally {
      loading.value = false;
    }
  }

  static String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');

  /// The TV to open the app on: the one used last time if it is around, the
  /// only one found, or the user's pick. A TV can show up twice (wired and
  /// Wi-Fi addresses); either works.
  Future<String?> _pickTv(BuildContext context) async {
    final tvs = await link.findTvs();
    if (tvs.isEmpty) {
      snackBar(
        'No LG TV found. Turn the TV on, or add it once in Settings → TV Remote (open by IP address).',
        duration: 5000,
        maxLines: 3,
      );
      return null;
    }
    var last = '';
    try {
      last = KvHelper.get<String>(_kLastHost, defaultVal: '');
    } catch (_) {}
    if (tvs.any((t) => t.host == last)) return last;
    if (tvs.length == 1) return tvs.first.host;
    if (!context.mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Which TV?'),
        children: [
          for (final t in tvs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t.host),
              child: Text('${t.name}\n${t.host}'),
            ),
        ],
      ),
    );
  }

  Future<bool> _waitConnected(Duration limit) async {
    final until = DateTime.now().add(limit);
    while (DateTime.now().isBefore(until)) {
      if (link.isConnected) return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return link.isConnected;
  }

  /// The TV app is connected but may be behind another app: open it again.
  Future<void> _bringToFront() async {
    var host = '';
    try {
      host = KvHelper.get<String>(_kLastHost, defaultVal: '');
    } catch (_) {}
    if (host.isEmpty) host = link.tvAddress.value;
    if (host.isEmpty) return;
    try {
      await link.openOnTv(host).timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  void _begin(PlayerController c) {
    _disposeWorkers();
    _c = c;
    _subFiles.clear();
    _subCache.clear();
    link.subtitleProvider = _subtitle;
    active.value = true;
    _workers.addAll([
      ever(link.tvState, _onState),
      ever(c.selectedAudioTrack, (_) => _sendAudio()),
      ever(c.selectedSubsTrack, (_) => _sendSub()),
      ever(c.selectedExternalSub, (_) => _sendSub()),
      // Another episode is being opened: the TV's reports about the old
      // video must not count for the new one.
      ever(c.currentEpisode, (_) {
        _id++;
        _seen = false;
        link.player('pause');
      }),
    ]);
    WidgetsBinding.instance.addObserver(this);
  }

  void _disposeWorkers() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }

  /// "video/x-matroska" → "mkv": the name the TV keeps its "has played"
  /// list under.
  static String kindOf(String mime) {
    const names = {
      'video/x-matroska': 'mkv',
      'video/mp4': 'mp4',
      'video/webm': 'webm',
      'video/quicktime': 'mov',
      'video/mp2t': 'ts',
      'video/x-msvideo': 'avi',
    };
    return names[mime] ?? mime;
  }

  /// The line under the title on the TV: "Episode 3 · Name", or nothing for
  /// a movie.
  static String episodeLine(String number, String? title, int episodeCount) {
    final t = (title ?? '').trim();
    if (episodeCount <= 1) return '';
    final ep = 'Episode $number';
    if (t.isEmpty || t.toLowerCase() == ep.toLowerCase()) return ep;
    return '$ep · $t';
  }

  Future<void> _send(
    PlayerController c, {
    required String url,
    Map<String, String>? headers,
    required Duration start,
  }) async {
    final isLocal = url.startsWith('/') || url.startsWith('file:');
    var playUrl = url;
    if (_proxied) {
      await CastProxyServer.stopProxy();
      _proxied = false;
    }
    // The TV fetches the video itself. It can't send a source's headers or
    // read a file on this device, so those go through the app's cast proxy.
    if (isLocal || (headers != null && headers.isNotEmpty)) {
      PlusMkvAudio.audioIndex = null;
      final p = await CastProxyServer.startProxy(originalUrl: url, headers: headers);
      if (p != null && p != url) {
        playUrl = p;
        _proxied = true;
      } else if (isLocal) {
        throw Exception("couldn't share the file with the TV");
      }
    }
    final kind = url.contains('.m3u8') ? 'hls' : kindOf(await plusDetectMime(url, headers));
    final ep = c.currentEpisode.value;

    _headers = headers;
    _id++;
    _seen = false;
    _endedHandled = false;
    _shownError = '';
    _lastSub = '';
    _startAt = start;
    _sentAt = DateTime.now();
    problem.value = '';
    position.value = start;
    playing.value = true;
    link.play(
      playUrl,
      title: c.anilistData.title.isNotEmpty ? c.anilistData.title : (ep.title ?? 'AnymeX+'),
      subtitle: episodeLine(ep.number, ep.title, c.episodeList.length),
      start: start,
      kind: kind,
      id: _id,
    );
    _sendAudio();
    _sendSub();
    _sendServers(c);
  }

  /// The servers of this episode, for the TV's own "Source" list.
  void _sendServers(PlayerController c) {
    final tracks = c.episodeTracks.toList();
    if (tracks.length < 2 || tracks.length > 80) return;
    final on = tracks.indexWhere((v) => identical(v, c.selectedVideo.value));
    link.send({
      't': 'servers',
      'id': _id,
      'on': on,
      'list': [for (var i = 0; i < tracks.length; i++) tracks[i].quality ?? 'Server ${i + 1}'],
    });
  }

  /// The TV picked another server from that list.
  void pickServer(int i) {
    final c = _c;
    if (c == null || !active.value || c.isClosed) return;
    if (i < 0 || i >= c.episodeTracks.length) return;
    final track = c.episodeTracks[i];
    PlusTvAnime.rememberServer(c.anilistData.id, track.quality ?? track.originalUrl ?? '');
    c.setServerTrack(track);
  }

  /// The player opened another video (next episode, another source or
  /// quality) while on the TV: that goes to the TV too.
  Future<void> mediaChanged(
      PlayerController c, String url, Map<String, String>? headers, Duration? start) async {
    if (!takes(c)) return;
    c.plusPauseLocal();
    if (c.isTorrentStream.value) {
      snackBar("Torrents can't play on the TV yet. Playing here instead.", duration: 4000, maxLines: 3);
      link.stopVideo();
      await _finish(Duration.zero);
      return;
    }
    try {
      // Same episode, another server or quality: carry on from where the TV
      // is (this device's own player is paused somewhere behind it).
      final at = _seen && position.value > Duration.zero ? position.value : (start ?? Duration.zero);
      await _send(c, url: url, headers: headers, start: at);
    } catch (e) {
      snackBar("Couldn't start on the TV: ${_clean(e)}", duration: 5000, maxLines: 3);
    }
  }

  // ------------------------------------------------- audio and subtitles

  void _sendAudio() {
    final c = _c;
    if (c == null || !active.value) return;
    // mpv numbers a file's audio tracks from 1; "auto" and "no" aren't numbers.
    final n = int.tryParse(c.selectedAudioTrack.value?.id ?? '');
    if (n != null && n >= 1) link.player('audio', index: n - 1);
  }

  void _sendSub() {
    final c = _c;
    if (c == null || !active.value) return;
    final file = c.selectedExternalSub.value.file ?? '';
    final inFile = int.tryParse(c.selectedSubsTrack.value?.id ?? '');
    final key = file.isNotEmpty ? 'f:$file' : (inFile != null && inFile >= 1 ? 'i:$inFile' : 'off');
    if (key == _lastSub) return;
    _lastSub = key;
    if (file.isNotEmpty) {
      // A subtitle file: the TV app fetches it from this device as WebVTT.
      final name = 's${++_subCount}';
      _subFiles[name] = file;
      link.player('sub', url: link.subtitleUrl(name), label: c.selectedExternalSub.value.label ?? '');
    } else if (inFile != null && inFile >= 1) {
      // One inside the video file: the TV's player shows it.
      link.player('sub', index: inFile - 1);
    } else {
      link.player('sub');
    }
  }

  Future<String?> _subtitle(String name) async {
    final file = _subFiles[name];
    if (file == null) return null;
    final cached = _subCache[name];
    if (cached != null) return cached;
    String? raw;
    try {
      if (file.startsWith('/') || file.startsWith('file:')) {
        final path = file.startsWith('file:') ? Uri.parse(file).toFilePath() : file;
        raw = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
      } else {
        var resp = await http.get(Uri.parse(file)).timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200 && (_headers?.isNotEmpty ?? false)) {
          resp = await http.get(Uri.parse(file), headers: _headers).timeout(const Duration(seconds: 15));
        }
        if (resp.statusCode == 200) raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      }
    } catch (_) {}
    if (raw == null || raw.trim().isEmpty) return null;
    return _subCache[name] = plusSubtitleToVtt(raw);
  }

  // ------------------------------------------------------ the TV's reports

  void _onState(Map<String, dynamic> state) {
    final c = _c;
    if (!active.value || c == null) return;
    if (c.isClosed) {
      // The player was closed on this device: nothing is left to track it.
      link.stopVideo();
      unawaited(_finish(Duration.zero));
      return;
    }
    final p = state['player'];
    if (p is! Map || p['id'] != _id) {
      // Our video was showing and now the TV is out of its player (Back on
      // the TV remote): carry on here.
      if (_seen && p is! Map && state.isNotEmpty) {
        final fromTv = _tvRoute != null;
        unawaited(_finish(position.value).then((_) {
          if (fromTv) _closeTvRoute(); // the TV asked for it: nothing to carry on here
        }));
      }
      return;
    }
    _seen = true;
    final pos = Duration(milliseconds: (((p['pos'] as num?) ?? 0) * 1000).round());
    final dur = Duration(milliseconds: (((p['dur'] as num?) ?? 0) * 1000).round());
    final ended = p['ended'] == true;
    final err = (p['error'] ?? '').toString();
    final note = (p['note'] ?? '').toString();
    problem.value = err.isNotEmpty ? err : note;
    if (err.isNotEmpty && err != _shownError) {
      _shownError = err;
      snackBar("The TV couldn't play this: $err", duration: 5000, maxLines: 3);
    }
    if (dur == Duration.zero) return; // still opening
    // Just after starting, the TV may report 0 before it jumps to the spot.
    final settling = DateTime.now().difference(_sentAt) < const Duration(seconds: 8) &&
        _startAt > const Duration(seconds: 5) &&
        pos < _startAt - const Duration(seconds: 5);
    if (settling || _endedHandled) return;
    playing.value = p['paused'] != true && !ended;
    position.value = pos;
    duration.value = dur;
    c.plusRemoteTick(pos, dur, playing: playing.value);
    if (ended && !_endedHandled) {
      _endedHandled = true;
      if (!c.plusRemoteEnded()) {
        link.stopVideo();
        unawaited(_finish(Duration.zero).then((_) => _closeTvRoute()));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the background: the system may have closed the server the
    // TV talks to. The TV kept playing and is retrying.
    if (state == AppLifecycleState.resumed && active.value && !link.isConnected) {
      unawaited(link.restart());
    }
  }

  // ------------------------------------------------------------- remote

  /// play, pause or toggle.
  void command(String cmd) {
    link.player(cmd);
    if (cmd == 'play') playing.value = true;
    if (cmd == 'pause') playing.value = false;
    if (cmd == 'toggle') playing.toggle();
  }

  void seekTo(Duration d) {
    position.value = d;
    link.player('seekTo', to: d.inMilliseconds / 1000.0);
  }

  /// The player was closed on this device: nothing is left to keep the
  /// progress, so the TV stops too.
  void playerClosed(PlayerController c) {
    _tvRoute = null;
    if (!takes(c)) return;
    link.stopVideo();
    unawaited(_finish(Duration.zero));
  }

  /// Stops on the TV; the app's player picks up where the TV was.
  Future<void> stop() async {
    _tvRoute = null; // "Play here": the player stays open on this device
    link.stopVideo();
    await _finish(position.value);
  }

  Future<void> _finish(Duration at) async {
    if (!active.value) return;
    active.value = false;
    playing.value = false;
    _disposeWorkers();
    WidgetsBinding.instance.removeObserver(this);
    link.subtitleProvider = null;
    if (_proxied) await CastProxyServer.stopProxy();
    _proxied = false;
    final c = _c;
    _c = null;
    if (c != null && !c.isClosed) {
      c.isPlaying.value = false;
      if (at > Duration.zero) c.seekTo(at);
    }
  }
}

/// "AnymeX+ TV" at the top of the Cast to Device sheet: a row to start, a
/// remote card while it plays.
class PlusTvPlayRow extends StatelessWidget {
  final PlayerController controller;
  const PlusTvPlayRow({super.key, required this.controller});

  static String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return '${h > 0 ? '$h:' : ''}${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tv = PlusTvPlay.instance;
    return Obx(() => tv.takes(controller) ? _card(theme, tv) : _row(context, theme, tv));
  }

  Widget _row(BuildContext context, ThemeData theme, PlusTvPlay tv) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.opaque(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.connected_tv_rounded, color: theme.colorScheme.primary, size: 22),
      ),
      title: const AnymeXText(
        'AnymeX+ TV',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
      ),
      subtitle: AnymeXText(
        "Plays in the AnymeX+ app on your LG TV. This player becomes the remote and your progress is kept.",
        size: 12,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      trailing: tv.loading.value
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right_rounded),
      onTap: () => tv.start(controller, context),
    );
  }

  Widget _card(ThemeData theme, PlusTvPlay tv) {
    final dur = tv.duration.value > Duration.zero ? tv.duration.value : controller.episodeDuration.value;
    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final pos = tv.position.value.inMilliseconds.toDouble().clamp(0.0, maxMs).toDouble();
    final connected = tv.link.status.value == PlusTvStatus.connected;
    final line = !connected
        ? 'Reconnecting to the TV…'
        : (tv.problem.value.isNotEmpty ? tv.problem.value : 'The player on this device is the remote');
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
              Icon(Icons.connected_tv_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AnymeXText('Playing on AnymeX+ TV', variant: TextVariant.bold, size: 14),
                    AnymeXText(line, size: 11, color: theme.colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
              TextButton(onPressed: tv.stop, child: const Text('Play here')),
            ],
          ),
          Slider(
            value: pos,
            max: maxMs,
            onChanged: (v) => tv.position.value = Duration(milliseconds: v.toInt()),
            onChangeEnd: (v) => tv.seekTo(Duration(milliseconds: v.toInt())),
          ),
          Row(
            children: [
              AnymeXText(_fmt(tv.position.value), size: 12),
              const Spacer(),
              IconButton(
                onPressed: () => controller.megaSeek(-10),
                icon: const Icon(Icons.replay_10_rounded),
              ),
              IconButton.filled(
                onPressed: () => tv.command('toggle'),
                icon: Icon(tv.playing.value ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              IconButton(
                onPressed: () => controller.megaSeek(10),
                icon: const Icon(Icons.forward_10_rounded),
              ),
              if (controller.hasNextEpisode)
                IconButton(
                  tooltip: 'Next episode',
                  onPressed: () => controller.navigator(true),
                  icon: const Icon(Icons.skip_next_rounded),
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
