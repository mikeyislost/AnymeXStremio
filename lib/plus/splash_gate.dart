import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:get/get.dart';

/// AnymeX+: decides when the splash screen gives way to Home.
///
/// AnymeX always showed the splash for 3 seconds. Now Home opens as soon as
/// your AniList account and anime list have loaded (so it opens filled in),
/// after at least [minimum] so the logo doesn't just flash, and never later
/// than [maximum] (the old 3 seconds) when AniList is slow or offline. With
/// no AniList sign-in, or another service active, it only waits [minimum].
class SplashGate {
  SplashGate._();

  static const minimum = Duration(milliseconds: 800);
  static const maximum = Duration(seconds: 3);
  static const _step = Duration(milliseconds: 50);

  static Future<void> wait() async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < maximum) {
      if (clock.elapsed >= minimum && homeReady()) return;
      await Future.delayed(_step);
    }
  }

  /// True when Home has what it shows first.
  static bool homeReady() {
    try {
      if (Get.isRegistered<ServiceHandler>() &&
          Get.find<ServiceHandler>().serviceType.value !=
              ServicesType.anilist) {
        return true;
      }
      final token = AuthKeys.authToken.get<String?>();
      if (token == null || token.isEmpty) return true;
      if (!Get.isRegistered<AnilistAuth>()) return true;
      final auth = Get.find<AnilistAuth>();
      return auth.isLoggedIn.value && auth.animeList.isNotEmpty;
    } catch (_) {
      return true;
    }
  }
}
