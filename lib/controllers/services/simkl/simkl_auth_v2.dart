// AnymeX+: Simkl "AUTH V2" support. Simkl apps registered now are V2 apps:
// sign-in goes through /oauth2/authorize with PKCE, tokens last 7 days and
// are renewed with a refresh token. Simkl also asks every API call to carry
// client_id, app-name and app-version parameters and a User-Agent header.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/database/kv_helper.dart';
import 'package:anymex/utils/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class SimklAuthV2 {
  static const appName = 'anymexplus';
  static const appVersion = '1.0';
  static const redirectUri = 'anymex://callback';
  static const userAgent = 'AnymeXPlus/$appVersion';

  static const _kRefresh = 'anymexplus_simkl_refresh';
  static const _kExpires = 'anymexplus_simkl_expires';
  static const _kConfidential = 'anymexplus_simkl_confidential';

  static String? get clientId {
    final v = dotenv.env['SIMKL_CLIENT_ID']?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static String? get clientSecret {
    final v = dotenv.env['SIMKL_CLIENT_SECRET']?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Adds Simkl's required URL parameters to an api.simkl.com URL.
  static Uri withAppParams(Uri u) {
    if (u.host != 'api.simkl.com') return u;
    final q = Map<String, String>.from(u.queryParameters);
    final id = clientId;
    if (id != null) q.putIfAbsent('client_id', () => id);
    q.putIfAbsent('app-name', () => appName);
    q.putIfAbsent('app-version', () => appVersion);
    return u.replace(queryParameters: q);
  }

  static Map<String, String> get baseHeaders => const {
        'User-Agent': userAgent,
        'Accept': 'application/json',
      };

  // ---- sign-in -------------------------------------------------------------

  static String? _verifier;
  static String? _state;

  static String _random(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = math.Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// The browser URL that starts sign-in (PKCE, read + write access).
  static String authorizeUrl() {
    _verifier = _random(64);
    _state = _random(24);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(_verifier!)).bytes)
        .replaceAll('=', '');
    return Uri.https('simkl.com', '/oauth2/authorize', {
      'response_type': 'code',
      'client_id': clientId ?? '',
      'redirect_uri': redirectUri,
      'scope': 'media:read media:write',
      'state': _state!,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'app-name': appName,
      'app-version': appVersion,
    }).toString();
  }

  /// Completes sign-in from the `anymex://callback?...` URL. Stores and
  /// returns the access token, or throws a message to show the user.
  static Future<String> finishLogin(String callbackUrl) async {
    final q = Uri.parse(callbackUrl).queryParameters;
    final error = q['error'];
    if (error != null) {
      throw error == 'access_denied'
          ? 'Simkl sign-in was cancelled'
          : 'Simkl sign-in failed: ${q['error_description'] ?? error}';
    }
    if (_state != null && q['state'] != null && q['state'] != _state) {
      throw 'Simkl sign-in expired, please try again';
    }
    final code = q['code'];
    if (code == null || code.isEmpty || _verifier == null) {
      throw 'Simkl did not send a sign-in code';
    }
    final fields = {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': _verifier!,
    };
    // Mobile apps have no secret; server apps need it. A 401 doesn't use up
    // the code, so try without first and add the secret if Simkl asks.
    var resp = await _token(fields, withSecret: false);
    var confidential = false;
    if (resp.statusCode == 401 && clientSecret != null) {
      resp = await _token(fields, withSecret: true);
      confidential = true;
    }
    if (resp.statusCode != 200) {
      final body = resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body;
      Logger.i('Simkl token exchange failed: ${resp.statusCode} $body');
      throw 'Simkl sign-in failed (HTTP ${resp.statusCode}). '
          '${_hint(resp.body)}';
    }
    KvHelper.set(_kConfidential, confidential);
    _verifier = null;
    _state = null;
    return _store(resp.body);
  }

  static String _hint(String body) {
    if (body.contains('redirect_uri')) {
      return 'Check that your Simkl app\'s redirect URL is exactly $redirectUri.';
    }
    if (body.contains('invalid_client')) {
      return 'Check SIMKL_CLIENT_ID / SIMKL_CLIENT_SECRET.';
    }
    return '';
  }

  static Future<http.Response> _token(Map<String, String> fields,
      {required bool withSecret}) {
    final body = <String, String>{
      ...fields,
      'client_id': clientId ?? '',
      if (withSecret && clientSecret != null) 'client_secret': clientSecret!,
    };
    return http
        .post(
          withAppParams(Uri.parse('https://api.simkl.com/oauth2/token')),
          headers: {
            ...baseHeaders,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));
  }

  static String _store(String body) {
    final data = jsonDecode(body) as Map;
    final access = data['access_token'].toString();
    AuthKeys.simklAuthToken.set(access);
    final refresh = data['refresh_token']?.toString();
    if (refresh != null && refresh.isNotEmpty) KvHelper.set(_kRefresh, refresh);
    final seconds = int.tryParse('${data['expires_in'] ?? ''}');
    if (seconds != null) {
      KvHelper.set(_kExpires,
          DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch);
    }
    return access;
  }

  // ---- refresh ---------------------------------------------------------------

  static bool get canRefresh =>
      (KvHelper.get<String?>(_kRefresh) ?? '').isNotEmpty;

  /// True when the saved login expires within a day.
  static bool get expiresSoon {
    final e = KvHelper.get<int?>(_kExpires);
    return e != null &&
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch > e;
  }

  static DateTime? get expiresAt {
    final e = KvHelper.get<int?>(_kExpires);
    return e == null ? null : DateTime.fromMillisecondsSinceEpoch(e);
  }

  static Future<bool>? _refreshing;

  /// Gets a fresh access token. Concurrent callers share one request.
  static Future<bool> refresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  static Future<bool> _doRefresh() async {
    final rt = KvHelper.get<String?>(_kRefresh);
    if (rt == null || rt.isEmpty) return false;
    try {
      final fields = {'grant_type': 'refresh_token', 'refresh_token': rt};
      final confidential =
          KvHelper.get<bool>(_kConfidential, defaultVal: false);
      var resp = await _token(fields,
          withSecret: confidential && clientSecret != null);
      if (resp.statusCode == 401 && !confidential && clientSecret != null) {
        resp = await _token(fields, withSecret: true);
        if (resp.statusCode == 200) KvHelper.set(_kConfidential, true);
      }
      if (resp.statusCode != 200) {
        Logger.i('Simkl refresh failed: HTTP ${resp.statusCode}');
        return false;
      }
      _store(resp.body);
      return true;
    } catch (e) {
      Logger.i('Simkl refresh failed: $e');
      return false;
    }
  }

  static void clear() {
    KvHelper.remove(_kRefresh);
    KvHelper.remove(_kExpires);
    KvHelper.remove(_kConfidential);
  }
}

/// Wraps an http client for api.simkl.com: adds the required parameters and
/// User-Agent, and on a 401 for a signed-in call renews the login once and
/// retries.
class SimklHttpClient extends http.BaseClient {
  final http.Client inner;
  SimklHttpClient(this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request || request.url.host != 'api.simkl.com') {
      return inner.send(request);
    }
    final resp = await inner.send(_copy(request, null));
    final hasAuth = request.headers.keys
        .any((k) => k.toLowerCase() == 'authorization');
    if (resp.statusCode == 401 &&
        hasAuth &&
        !request.url.path.startsWith('/oauth') &&
        SimklAuthV2.canRefresh) {
      if (await SimklAuthV2.refresh()) {
        await resp.stream.drain<void>();
        return inner.send(
            _copy(request, AuthKeys.simklAuthToken.get<String?>()));
      }
    }
    return resp;
  }

  http.Request _copy(http.Request r, String? token) {
    final c = http.Request(r.method, SimklAuthV2.withAppParams(r.url))
      ..followRedirects = r.followRedirects
      ..maxRedirects = r.maxRedirects
      ..persistentConnection = r.persistentConnection;
    c.headers.addAll(r.headers);
    if (!c.headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      c.headers['User-Agent'] = SimklAuthV2.userAgent;
    }
    if (token != null) {
      c.headers.removeWhere((k, _) => k.toLowerCase() == 'authorization');
      c.headers['Authorization'] = 'Bearer $token';
    }
    if (r.bodyBytes.isNotEmpty) c.bodyBytes = r.bodyBytes;
    return c;
  }
}
