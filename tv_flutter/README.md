# AnymeX+ Flutter tests for the LG TV

Two tiny Flutter apps, built with LG's flutter-webOS SDK by the
"TV Flutter test" workflow (`.github/workflows/tv-flutter-test.yml`):

- **blank** (`com.mikeyislost.anymexplus.flutter1`): no plugins. If its
  screen shows, Flutter draws on the TV at all.
- **video** (`com.mikeyislost.anymexplus.flutter2`): a small AnymeX+-style
  screen with LG's `video_player_webos` plugin and the four test videos.

They are published on the `tv-flutter-test` pre-release, with a Homebrew
Channel repository file:
`https://github.com/mikeyislost/AnymeXStremio/releases/download/tv-flutter-test/webos-flutter-test.json`

Only the folders' `lib/` and `pubspec.yaml` live here; the workflow makes the
rest with `flutter-webos create`. Not part of the main app (excluded from
its analysis).
