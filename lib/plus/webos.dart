import 'dart:ffi';
import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

/// AnymeX+: the app running on an LG TV (webOS), built with LG's
/// flutter-webOS SDK (TV app phase 2, Flutter check).
///
/// On the TV the app looks like Linux to Dart, but desktop parts (window
/// manager, protocol handlers) aren't there, and the native libraries the
/// app needs (Isar's database core, rhttp) are built for the TV by CI and
/// sit in the app's lib folder.
class PlusWebos {
  PlusWebos._();

  static const _built = bool.fromEnvironment('ANYMEX_WEBOS');

  static final bool isTv = _built ||
      (Platform.isLinux && (Directory('/usr/palm').existsSync() || Directory('/media/developer').existsSync()));

  /// A library that ships in the app's lib folder.
  static String lib(String name) => p.join(p.dirname(Platform.resolvedExecutable), 'lib', name);

  /// Points Isar at its core library (before the database opens).
  static Future<void> initNative() async {
    if (!isTv) return;
    await Isar.initializeIsarCore(libraries: {Abi.current(): lib('libisar.so')});
  }
}
