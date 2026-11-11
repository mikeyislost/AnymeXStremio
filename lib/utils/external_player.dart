import 'dart:io';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:anymex/plus/external_player_pc.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_toast.dart';

class ExternalPlayer {
  static const MethodChannel _channel = MethodChannel('com.ryan.anymex/utils');

  static Future<bool> launch(String url, {Map<String, String>? headers}) async {
    if (Platform.isAndroid) {
      try {
        final String mimeType = _getMimeType(url);
        final bool success = await _channel.invokeMethod('openWithMime', {
          'url': url,
          'mimeType': mimeType,
          if (headers != null) 'headers': headers,
        });
        return success;
      } on PlatformException catch (e) {
        print("ExternalPlayer failed: $e");
        return false;
      }
    } else if (Platform.isWindows) {
      // AnymeX+: a real video player, not the browser (which downloaded it).
      final problem = await PlusExternalPlayerPc.launch(url, headers: headers);
      if (problem != null) {
        AnymeXToast.show(message: problem, duration: const Duration(seconds: 4));
      }
      return true; // the message above already says what went wrong
    } else {
      try {
        if (await canLaunchUrlString(url)) {
          return await launchUrlString(url, mode: LaunchMode.externalApplication);
        }
        return false;
      } catch (e) {
        print("ExternalPlayer url_launcher failed: $e");
        return false;
      }
    }
  }

  static String _getMimeType(String url) {
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('.m3u8')) {
      return 'application/x-mpegURL';
    } else if (lowerUrl.contains('.mpd')) {
      return 'application/dash+xml';
    } else if (lowerUrl.contains('.mp4')) {
      return 'video/mp4';
    } else if (lowerUrl.contains('.mkv')) {
      return 'video/x-matroska';
    } else if (lowerUrl.contains('.webm')) {
      return 'video/webm';
    } else if (lowerUrl.contains('.ogg')) {
      return 'video/ogg';
    } else if (lowerUrl.contains('.3gp')) {
      return 'video/3gpp';
    }
    return 'video/*';
  }
}
