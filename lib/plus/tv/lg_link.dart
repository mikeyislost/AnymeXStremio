import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anymex/database/kv_helper.dart';

/// AnymeX+: LG's own phone link (the one LG's phone app uses: a websocket on
/// port 3001/3000). AnymeX+ uses it to open the AnymeX+ TV app on the TV and
/// hand it this phone's address. One-time "Allow" prompt on the TV; the key
/// is kept. Pairing manifest from aiowebostv (home-assistant-libs, Apache-2.0).
class PlusLgTv {
  PlusLgTv._(this.host, this._ws) {
    _sub = _ws.listen(
      (raw) {
        try {
          final m = jsonDecode(raw as String);
          if (m is Map) _messages.add(Map<String, dynamic>.from(m));
        } catch (_) {}
      },
      onDone: () => _messages.close(),
      onError: (_) => _messages.close(),
    );
  }

  final String host;
  final WebSocket _ws;
  late final StreamSubscription _sub;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  int _id = 0;

  bool get isOpen => _ws.closeCode == null;

  static const _kKeys = 'plus_lg_client_keys';

  static Map<String, dynamic> _keys() {
    try {
      return Map<String, dynamic>.from(
          KvHelper.get<Map<String, dynamic>>(_kKeys, defaultVal: const {}));
    } catch (_) {
      return {};
    }
  }

  static void _saveKey(String host, String key) =>
      KvHelper.set(_kKeys, {..._keys(), host: key});

  /// True if [host] has the LG remote-app port open (a quick check).
  static Future<bool> isLgTv(String host) async {
    for (final port in const [3001, 3000]) {
      try {
        final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 900));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Connects (wss first, then ws) and pairs. [onPrompt] is called when the
  /// TV is showing its "Allow" prompt.
  static Future<PlusLgTv> connect(String host, {void Function()? onPrompt}) async {
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    WebSocket? ws;
    Object? lastError;
    for (final uri in ['wss://$host:3001', 'ws://$host:3000']) {
      try {
        ws = await WebSocket.connect(uri, customClient: client)
            .timeout(const Duration(seconds: 5));
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (ws == null) throw Exception("Couldn't reach the TV ($lastError)");
    ws.pingInterval = const Duration(seconds: 20);
    final tv = PlusLgTv._(host, ws);
    try {
      await tv._register(signed: true, onPrompt: onPrompt);
    } on _LgRejected {
      await tv._register(signed: false, onPrompt: onPrompt);
    }
    return tv;
  }

  Future<void> _register({required bool signed, void Function()? onPrompt}) async {
    final id = 'register_${_id++}';
    final payload = _registration(signed);
    final key = _keys()[host];
    if (key is String && key.isNotEmpty) payload['client-key'] = key;
    final done = Completer<void>();
    late final StreamSubscription sub;
    sub = _messages.stream.where((m) => m['id'] == id).listen((m) {
      final type = m['type'];
      final p = m['payload'];
      if (type == 'response' && p is Map && p['pairingType'] == 'PROMPT') {
        onPrompt?.call();
      } else if (type == 'registered') {
        final k = p is Map ? p['client-key'] : null;
        if (k is String && k.isNotEmpty) _saveKey(host, k);
        if (!done.isCompleted) done.complete();
      } else if (type == 'error') {
        if (!done.isCompleted) done.completeError(_LgRejected('${m['error']}'));
      }
    }, onDone: () {
      if (!done.isCompleted) done.completeError(Exception('The TV closed the connection'));
    });
    _ws.add(jsonEncode({'type': 'register', 'id': id, 'payload': payload}));
    try {
      await done.future.timeout(const Duration(seconds: 60),
          onTimeout: () => throw Exception('Nobody accepted the prompt on the TV'));
    } finally {
      await sub.cancel();
    }
  }

  /// Sends an ssap request and returns its payload.
  Future<Map<String, dynamic>> request(String uri, [Map<String, dynamic>? payload]) async {
    final id = 'req_${_id++}';
    final f = _messages.stream
        .firstWhere((m) => m['id'] == id)
        .timeout(const Duration(seconds: 10));
    _ws.add(jsonEncode({'type': 'request', 'id': id, 'uri': 'ssap://$uri', 'payload': payload ?? {}}));
    final m = await f;
    final p = m['payload'];
    final ok = m['type'] == 'response' && (p is! Map || p['returnValue'] != false);
    if (!ok) throw Exception(m['error'] ?? (p is Map ? p['errorText'] : null) ?? 'The TV refused');
    return p is Map ? Map<String, dynamic>.from(p) : {};
  }

  Future<void> close() async {
    await _sub.cancel();
    await _messages.close();
    await _ws.close();
  }

  static Map<String, dynamic> _registration(bool signed) {
    const permissions = [
      'LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'TEST_OPEN', 'TEST_PROTECTED',
      'CONTROL_AUDIO', 'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK',
      'CONTROL_INPUT_MEDIA_RECORDING', 'CONTROL_INPUT_MEDIA_PLAYBACK', 'CONTROL_INPUT_TV',
      'CONTROL_POWER', 'CONTROL_TV_SCREEN', 'READ_APP_STATUS', 'READ_CURRENT_CHANNEL',
      'READ_INPUT_DEVICE_LIST', 'READ_NETWORK_STATE', 'READ_RUNNING_APPS',
      'READ_TV_CHANNEL_LIST', 'WRITE_NOTIFICATION_TOAST', 'READ_POWER_STATE',
      'READ_COUNTRY_INFO', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD',
      'READ_INSTALLED_APPS', 'READ_SETTINGS',
    ];
    const signedPermissions = [
      'TEST_SECURE', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD',
      'READ_INSTALLED_APPS', 'READ_LGE_SDX', 'READ_NOTIFICATIONS', 'SEARCH',
      'WRITE_SETTINGS', 'WRITE_NOTIFICATION_ALERT', 'CONTROL_POWER',
      'READ_CURRENT_CHANNEL', 'READ_RUNNING_APPS', 'READ_UPDATE_INFO',
      'UPDATE_FROM_REMOTE_APP', 'READ_LGE_TV_INPUT_EVENTS', 'READ_TV_CURRENT_TIME',
    ];
    const signature = 'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbm'
        'ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR'
        '+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy'
        'aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4'
        'RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n'
        '50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM'
        '2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj'
        'oa7NQnAtw==';
    final manifest = <String, dynamic>{
      'appVersion': '1.1',
      'manifestVersion': 1,
      'permissions': signed
          ? permissions
          : ({...permissions, ...signedPermissions}.toList()..sort()),
      if (signed) 'signatures': [
        {'signature': signature, 'signatureVersion': 1}
      ],
      if (signed)
        'signed': {
          'appId': 'com.lge.test',
          'created': '20140509',
          'localizedAppNames': {'': 'LG Remote App'},
          'localizedVendorNames': {'': 'LG Electronics'},
          'permissions': signedPermissions,
          'serial': '2f930e2d2cfe083771f68e4fe7bb07',
          'vendorId': 'com.lge',
        },
    };
    return {'forcePairing': false, 'pairingType': 'PROMPT', 'manifest': manifest};
  }
}

class _LgRejected implements Exception {
  final String message;
  _LgRejected(this.message);
  @override
  String toString() => message;
}

