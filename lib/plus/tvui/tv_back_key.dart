import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/plus/webos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The remote's Back button on the TV (test).
///
/// LG's SDK doesn't hand Back to Flutter apps yet (webOS shows its own "exit
/// app?" popup instead). The TV runner (tv_runner/main.cc) asks webOS for
/// Back by setting the window property _WEBOS_ACCESS_POLICY_KEYS_BACK; this
/// talks to it over the "yumori/webos" channel: turn it on or off, and read
/// what the runner did. Builds without that runner just say so.
class TvBackKey {
  TvBackKey._();

  static const _channel = MethodChannel('yumori/webos');
  static const _kOn = 'plus_tv_back_key';
  static const property = '_WEBOS_ACCESS_POLICY_KEYS_BACK';

  /// What happened the last time the app asked: shown in Settings.
  static final status = ValueNotifier<String>('Not asked yet');

  static bool get enabled {
    try {
      return KvHelper.get<bool>(_kOn, defaultVal: true);
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool on) async {
    try {
      KvHelper.set(_kOn, on);
    } catch (_) {}
    await apply();
  }

  /// Tells the runner what the setting says (on at start already).
  static Future<void> apply() async {
    if (!PlusWebos.isTv) return;
    final on = enabled;
    try {
      final ok = await _channel.invokeMethod<bool>('setWindowProperty', {'name': property, 'value': on ? 'true' : 'false'});
      status.value = ok == true
          ? (on ? 'Asked the TV for Back' : 'Back left to the TV (exit popup)')
          : 'The runner had no window to set it on';
    } on MissingPluginException {
      status.value = "This build's runner can't ask for Back";
    } catch (e) {
      status.value = 'Asking failed: $e';
    }
  }

  /// The runner's own notes (newest last).
  static Future<List<String>> nativeLog() async {
    if (!PlusWebos.isTv) return const [];
    try {
      final l = await _channel.invokeListMethod<String>('log');
      return l ?? const [];
    } on MissingPluginException {
      return const ['(no runner channel in this build)'];
    } catch (e) {
      return ['(log failed: $e)'];
    }
  }
}
