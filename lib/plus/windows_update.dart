// AnymeX+: Windows in-app update. The new installer is downloaded to the
// temp folder (not Downloads) and run silently over the installed copy:
// no wizard or license pages, same folder, same "just me" / "all users"
// choice. The installer opens the updated app when it is done; the next
// start removes the installer, or says so if the update didn't install.
// Old installers left in Downloads by earlier versions are cleaned up too.

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
        '/FORCECLOSEAPPLICATIONS',
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

  static Future<File> _tempFile(String name) async =>
      File('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$name');

  /// The installer's own log of the last update (for when it fails).
  static Future<String> logPath() async => (await _tempFile('anymexplus_update.log')).path;

  /// Runs the update and returns true when it started (the caller then
  /// closes the app). False for a portable copy (no uninstaller next to
  /// the app): the caller opens the installer the normal way.
  ///
  /// The installer is started straight from the app, so a Windows
  /// permission prompt (apps installed for all users) comes up in front.
  /// It closes nothing itself and opens the app again when it is done (a
  /// [Run] line added to the installer by the build). An earlier version
  /// went through a hidden PowerShell script: on some PCs that never got
  /// as far as installing, and the app stayed closed.
  static Future<bool> start(String installer, {required String currentVersion}) async {
    final app = Platform.resolvedExecutable;
    final dir = File(app).parent.path;
    final installed = File('$dir${Platform.pathSeparator}unins000.exe');
    if (!await installed.exists()) return false;
    final args = [
      ...installerArgs(dir, allUsers: isAllUsersPath(dir, Platform.environment)),
      '/LOG=${await logPath()}',
    ];
    try {
      await (await _tempFile(_pendingName)).writeAsString(currentVersion);
    } catch (_) {}
    await Process.start(installer, args, mode: ProcessStartMode.detached);
    return true;
  }

  static const _pendingName = 'anymexplus_update_pending.txt';

  /// True when the version before the update is still the version now.
  static bool updateFailed(String versionBefore, String versionNow) =>
      versionBefore.trim().isNotEmpty && versionBefore.trim() == versionNow.trim();

  /// At startup: after an update, removes the installer, and returns a
  /// message when the app is still the old version (the update didn't
  /// install). Null otherwise.
  static Future<String?> afterStart(String currentVersion) async {
    if (!Platform.isWindows) return null;
    try {
      final pending = await _tempFile(_pendingName);
      if (!await pending.exists()) return null;
      final before = await pending.readAsString();
      await pending.delete();
      if (!updateFailed(before, currentVersion)) {
        await cleanUp();
        return null;
      }
      return "The update didn't install. Download the Setup.exe from the release page and run it. "
          'Details: ${await logPath()}';
    } catch (_) {
      return null;
    }
  }
}
