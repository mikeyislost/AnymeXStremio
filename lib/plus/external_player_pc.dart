// AnymeX+: "External player" on Windows. AnymeX handed the stream link to
// Windows, which opens links in the browser, so the episode just
// downloaded. Here the link goes to a real video player when one is
// installed: mpv, VLC, MPC-HC or PotPlayer (first found), with the
// stream's headers where the player takes them.

import 'dart:io';

class PlusExternalPlayerPc {
  PlusExternalPlayerPc._();

  /// Where each player usually lives. [env] = Platform.environment.
  static List<String> candidates(Map<String, String> env) {
    final out = <String>[];
    final pf = [env['ProgramFiles'], env['ProgramW6432'], env['ProgramFiles(x86)']]
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();
    final local = env['LOCALAPPDATA'] ?? '';
    final home = env['USERPROFILE'] ?? '';
    // mpv: on PATH (scoop, winget, choco put it there) or common folders.
    for (final dir in (env['PATH'] ?? env['Path'] ?? '').split(';')) {
      if (dir.trim().isEmpty) continue;
      out.add('${dir.trim()}\\mpv.exe');
    }
    if (home.isNotEmpty) out.add('$home\\scoop\\apps\\mpv\\current\\mpv.exe');
    for (final p in pf) {
      out.add('$p\\mpv\\mpv.exe');
    }
    // VLC
    for (final p in pf) {
      out.add('$p\\VideoLAN\\VLC\\vlc.exe');
    }
    // MPC-HC / MPC-BE
    for (final p in pf) {
      out
        ..add('$p\\MPC-HC\\mpc-hc64.exe')
        ..add('$p\\MPC-HC\\mpc-hc.exe')
        ..add('$p\\K-Lite Codec Pack\\MPC-HC64\\mpc-hc64.exe')
        ..add('$p\\MPC-BE x64\\mpc-be64.exe');
    }
    // PotPlayer
    for (final p in pf) {
      out
        ..add('$p\\DAUM\\PotPlayer\\PotPlayerMini64.exe')
        ..add('$p\\DAUM\\PotPlayer\\PotPlayerMini.exe');
    }
    if (local.isNotEmpty) out.add('$local\\Programs\\mpv\\mpv.exe');
    return out;
  }

  /// The command line for [exe] playing [url] with [headers].
  static List<String> argsFor(String exe, String url, Map<String, String>? headers) {
    final name = exe.split('\\').last.toLowerCase();
    final h = <String, String>{};
    headers?.forEach((k, v) => h[k.toLowerCase()] = v);
    final ua = h.remove('user-agent');
    final ref = h.remove('referer') ?? h.remove('referrer');
    if (name.startsWith('mpv')) {
      return [
        if (ua != null) '--user-agent=$ua',
        if (ref != null) '--referrer=$ref',
        if (h.isNotEmpty)
          '--http-header-fields=${h.entries.map((e) => '${e.key}: ${e.value.replaceAll(',', r'\,')}').join(',')}',
        '--force-window=immediate',
        '--',
        url,
      ];
    }
    if (name.startsWith('vlc')) {
      return [
        if (ua != null) '--http-user-agent=$ua',
        if (ref != null) '--http-referrer=$ref',
        url,
      ];
    }
    return [url]; // MPC-HC / PotPlayer take no headers
  }

  /// The first installed player, or null.
  static Future<String?> find() async {
    for (final c in candidates(Platform.environment)) {
      try {
        if (await File(c).exists()) return c;
      } catch (_) {}
    }
    return null;
  }

  /// Opens [url] in an installed player. Null when it started; otherwise
  /// what went wrong, to show to the user.
  static Future<String?> launch(String url, {Map<String, String>? headers}) async {
    final exe = await find();
    if (exe == null) {
      return 'No video player found. Install VLC or mpv, then try again.';
    }
    try {
      await Process.start(exe, argsFor(exe, url, headers), mode: ProcessStartMode.detached);
      return null;
    } catch (e) {
      return "Couldn't open ${exe.split('\\').last}: $e";
    }
  }
}
