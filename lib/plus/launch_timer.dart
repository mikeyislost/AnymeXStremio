/// AnymeX+: how long the app takes to open, for the Self Test.
///
/// [firstFrame] is when the first screen (the splash) was drawn; [home] is
/// when Home appeared after the splash.
class LaunchTimer {
  LaunchTimer._();

  static final Stopwatch _clock = Stopwatch();
  static Duration? firstFrame;
  static Duration? home;

  static void start() {
    if (!_clock.isRunning) _clock.start();
  }

  static void markFirstFrame() => firstFrame ??= _clock.elapsed;

  static void markHome() => home ??= _clock.elapsed;
}
