// AnymeX+: AnymeX's backup already saves every AnymeX+ setting (they live
// in the same settings store: Movies & TV rows, stream picks, sync
// switches, Stremio entry choices, Like / Love / Dislike, For you hides —
// under General; the Stremio and Simkl sign-ins under Auth tokens). After
// a restore this puts them into effect without restarting the app.

import 'package:anymex/plus/layout/layout_store.dart';
import 'package:anymex/plus/for_you/taste.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/utils/logger.dart';
import 'package:get/get.dart';

class PlusBackup {
  PlusBackup._();

  /// Setting keys that are AnymeX+'s own.
  static bool isPlusKey(String key) =>
      key.startsWith('anymexplus_') || key.startsWith('stremio_');

  static void afterRestore() {
    try {
      PlusTaste.reload();
      PlusLayoutStore.reload();
      if (Get.isRegistered<StremioService>()) {
        StremioService.to.reloadSettings();
      }
      Logger.i('AnymeX+ settings restored');
    } catch (e) {
      Logger.i('AnymeX+ settings restore: $e');
    }
  }
}
