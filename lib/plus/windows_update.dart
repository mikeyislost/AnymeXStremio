// AnymeX+: Windows in-app update. The new installer is downloaded to the
// temp folder (not Downloads) and run silently over the installed copy:
// no wizard or license pages, same folder, same "just me" / "all users"
// choice. A small hidden script waits for it, deletes the installer and
// opens the updated app. Old installers left in Downloads by earlier
// versions of the updater are cleaned up too.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class PlusWindowsUpdate {
  PlusWindowsUpdate._();

  /// Where the installer is saved: the temp folder.
  static Future<String> installerPath(String version) async {
    final dir = await getTemporaryDirectory();
    final safe = version.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
    return '${dir.path}${Platform.pathSeparator}anymexplus_update_$safe.exe';
  }

  /// Removes installers the old updater left in Downloads
  /// (app_update_<version>.exe) and stale ones in the temp folder.
  static Future<void> cleanUp({String? keep}) async {
    final dirs = <Directory?>[];
    try {
      dirs.add(await getDownloadsDirectory());
    } catch (_) {}
    try {
      dirs.add(await getTemporaryDirectory());
    } catch (_) {}
    final pattern =
        RegExp(r'^(app_update_.+|anymexplus_update_.+)\.(exe|ps1)$');
    for (final d in dirs.whereType<Directory>()) {
      try {
        await for (final f in d.list(followLinks: false)) {
          if (f is! File) continue;
          final name = f.uri.pathSegments.last;
          if (!pattern.hasMatch(name)) continue;
          if (keep != null && f.path == keep) continue;
          try {
            await f.delete();
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  /// The installer's command-line switches for updating the copy in
  /// [installDir] (Inno Setup): silent with a progress bar, no license or
  /// other pages, no restart, and the same install mode as now.
  static List<String> installerArgs(String installDir,
      {required bool allUsers}) =>
      [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/SP-',
        '/CLOSEAPPLICATIONS',
        allUsers ? '/ALLUSERS' : '/CURRENTUSER',
        '/DIR=$installDir',
      ];

  /// Installed under Program Files (for all users)?
  static bool isAllUsersPath(String dir, Map<String, String> env) {
    final d = dir.toLowerCase();
    for (final k in const ['ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)']) {
      final p = env[k];
      if (p != null && p.isNotEmpty && d.startsWith(p.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  /// A PowerShell single-quoted string.
  static String psQuote(String s) => "'${s.replaceAll("'", "''")}'";

  /// The hidden script that runs the installer, deletes it and opens the
  /// app again.
  static String script({
    required String installer,
    required List<String> args,
    required String app,
  }) {
    // ArgumentList as one string so /DIR=... with spaces stays one switch.
    final argLine = args
        .map((a) => a.contains(' ') ? '"$a"' : a)
        .join(' ');
    return [
      r'$ErrorActionPreference = "SilentlyContinue"',
      'Start-Sleep -Seconds 2',
      'Start-Process -FilePath ${psQuote(installer)} '
          '-ArgumentList ${psQuote(argLine)} -Wait',
      'Remove-Item -LiteralPath ${psQuote(installer)} -Force',
      'Start-Process -FilePath ${psQuote(app)}',
      r'Remove-Item -LiteralPath $PSCommandPath -Force',
    ].join('\r\n');
  }

  /// Runs the update and returns true when it started (the caller then
  /// closes the app). False for a portable copy (no uninstaller next to
  /// the app): the caller opens the installer the normal way.
  static Future<bool> start(String installer) async {
    final app = Platform.resolvedExecutable;
    final dir = File(app).parent.path;
    final installed = File('$dir${Platform.pathSeparator}unins000.exe');
    if (!await installed.exists()) return false;
    final args = installerArgs(dir,
        allUsers: isAllUsersPath(dir, Platform.environment));
    final ps1 = File(installer.replaceAll(RegExp(r'\.exe$'), '.ps1'));
    await ps1.writeAsString(script(installer: installer, args: args, app: app));
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        ps1.path,
      ],
      mode: ProcessStartMode.detached,
    );
    return true;
  }
}
