import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Which AnymeX+ build this is: the normal app or the beta ("AnymeX+ β").
///
/// The build workflow writes APP_CHANNEL and APP_VERSION_TAG into .env.
/// Beta builds come from the `beta` branch, are tagged like `v1.1.2-beta` /
/// `v1.1.2-beta+1` (GitHub pre-releases) and install next to the stable app
/// with their own app ID and data.
class AppChannel {
  AppChannel._();

  static const String repo = 'mikeyislost/AnymeXStremio';

  /// Feather source for beta builds (kept on the `feather` branch, because
  /// GitHub's "latest release" link never points at a pre-release).
  static const String betaSourceUrl =
      'https://raw.githubusercontent.com/$repo/feather/source-beta.json';

  static String _env(String key) {
    try {
      return (dotenv.env[key] ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  static bool get isBeta => _env('APP_CHANNEL') == 'beta';

  /// Name shown to the user.
  static String get appName => isBeta ? 'AnymeX+ β' : 'AnymeX+';

  /// The release this build came from, e.g. `1.1.2-beta+1` or `1.1.1`.
  /// Empty for local builds.
  static String get versionTag => _env('APP_VERSION_TAG');

  /// Version to show and compare for updates (beta tag included).
  /// The newest beta in a GitHub releases list. Picked by publish date:
  /// GitHub lists releases by tag name, which can put an older beta
  /// (v1.1.1-beta) above a newer one (v1.1.1+1-beta).
  static Map<String, dynamic>? newestBeta(List<dynamic> releases) {
    Map<String, dynamic>? best;
    DateTime? bestAt;
    for (final r in releases) {
      if (r is! Map<String, dynamic>) continue;
      final tag = (r['tag_name'] ?? '').toString();
      if (r['draft'] == true || r['prerelease'] != true) continue;
      if (!tag.contains('-beta')) continue;
      final at = DateTime.tryParse(
          (r['published_at'] ?? r['created_at'] ?? '').toString());
      if (best == null || (at != null && (bestAt == null || at.isAfter(bestAt)))) {
        best = r;
        bestAt = at;
      }
    }
    return best;
  }

  static Future<String> version() async {
    final tag = versionTag;
    if (tag.isNotEmpty) return tag;
    return (await PackageInfo.fromPlatform()).version;
  }
}
