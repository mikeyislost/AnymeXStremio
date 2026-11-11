// AnymeX+: finding out why the AnymeX window loses focus to a game behind it
// about a second after you click it (Windows). Each time the window gets or
// loses focus, a line goes to the app log (app_logs.txt): which window took
// focus (title, class, program), whether it belongs to AnymeX itself, how
// long AnymeX had focus, and whether either window is "always on top".
// Read-only: it changes nothing about the windows.

import 'dart:ffi';
import 'dart:io';

import 'package:anymex/utils/logger.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

class PlusFocusWatch with WindowListener {
  PlusFocusWatch._();

  static final _instance = PlusFocusWatch._();
  static bool _started = false;
  DateTime? _focusedAt;

  static void start() {
    if (!Platform.isWindows || _started) return;
    _started = true;
    windowManager.addListener(_instance);
    Logger.i('[focus] watching window focus (${_describe(GetForegroundWindow())})');
  }

  @override
  void onWindowFocus() {
    _focusedAt = DateTime.now();
    Logger.i('[focus] AnymeX got focus');
  }

  @override
  void onWindowBlur() async {
    final had = _focusedAt == null
        ? '?'
        : '${(DateTime.now().difference(_focusedAt!).inMilliseconds / 1000).toStringAsFixed(1)} s';
    // Let Windows finish switching first.
    await Future.delayed(const Duration(milliseconds: 80));
    try {
      Logger.i('[focus] AnymeX lost focus after $had to: ${_describe(GetForegroundWindow())}');
    } catch (e) {
      Logger.i('[focus] AnymeX lost focus after $had (could not read the new window: $e)');
    }
  }

  static String _describe(int hwnd) {
    if (hwnd == 0) return 'no window (desktop or locked)';
    final parts = <String>[];
    final title = _text(hwnd, title: true), cls = _text(hwnd, title: false);
    parts.add('"$title" [$cls]');
    final pidPtr = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pidPtr);
      final pid = pidPtr.value;
      parts.add(pid == GetCurrentProcessId() ? 'ANYMEX ITSELF (pid $pid)' : '${_exe(pid)} (pid $pid)');
    } finally {
      calloc.free(pidPtr);
    }
    final ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (ex & WS_EX_TOPMOST != 0) parts.add('always-on-top');
    if (ex & WS_EX_TOOLWINDOW != 0) parts.add('tool window');
    if (IsWindowVisible(hwnd) == 0) parts.add('INVISIBLE');
    return parts.join(', ');
  }

  static String _text(int hwnd, {required bool title}) {
    final buf = wsalloc(256);
    try {
      final n = title ? GetWindowText(hwnd, buf, 256) : GetClassName(hwnd, buf, 256);
      return n > 0 ? buf.toDartString() : '';
    } finally {
      free(buf);
    }
  }

  static String _exe(int pid) {
    final h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h == 0) return 'program ?';
    final buf = wsalloc(1024);
    final size = calloc<Uint32>()..value = 1024;
    try {
      if (QueryFullProcessImageName(h, 0, buf, size) != 0) {
        return buf.toDartString().split('\\').last;
      }
      return 'program ?';
    } finally {
      free(buf);
      calloc.free(size);
      CloseHandle(h);
    }
  }
}
