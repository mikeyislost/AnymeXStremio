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

  // Plain text both ways (the runner speaks LG's C messenger API).
  static const _channel = BasicMessageChannel<String>('yumori/webos', StringCodec());
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
      final r = await _channel.send('set\n$property\n${on ? 'true' : 'false'}');
      status.value = switch (r) {
        'ok' => on ? 'Asked the TV for Back' : 'Back left to the TV (exit popup)',
        null => "This build's runner can't ask for Back",
        'no window' => 'The runner had no window to set it on',
        _ => 'The runner said: $r',
      };
    } catch (e) {
      status.value = 'Asking failed: $e';
    }
  }

  /// The runner's own notes (newest last).
  static Future<List<String>> nativeLog() async {
    if (!PlusWebos.isTv) return const [];
    try {
      final r = await _channel.send('log');
      if (r == null) return const ['(no runner channel in this build)'];
      return r.isEmpty ? const [] : r.split('\n');
    } catch (e) {
      return ['(log failed: $e)'];
    }
  }
}
