import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/main.dart' show FilterScreen;
import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_shell.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Settings on the TV: categories on the left, their options on the right.
class TvSettingsPage extends StatefulWidget {
  const TvSettingsPage({super.key});

  @override
  State<TvSettingsPage> createState() => _TvSettingsPageState();
}

class _TvSettingsPageState extends State<TvSettingsPage> {
  int _cat = 0;
  static const _cats = ['Accounts', 'Layout', 'About this TV'];

  Widget _row(String title, String sub, {Widget? trailing}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        decoration: BoxDecoration(color: TvStyle.panel, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 4),
              Text(sub, style: const TextStyle(fontSize: 18, color: TvStyle.dim)),
            ]),
          ),
          if (trailing != null) trailing,
        ]),
      );

  Widget _accounts() => Obx(() {
        final auth = Get.find<AnilistAuth>();
        final st = StremioService.to;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _row('Get logins from your phone', 'Coming in a test build soon: your phone sends AniList, Stremio and Simkl to the TV.'),
          _row('AniList', auth.isLoggedIn.value ? 'Signed in as ${auth.profileData.value.name ?? 'you'}' : 'Not signed in'),
          _row('Stremio', st.isLoggedIn.value ? 'Signed in · ${st.addons.length} addons' : 'Not signed in. Sign in with a code from your phone.',
              trailing: TvButton(
                label: st.isLoggedIn.value ? 'Sign out' : 'Sign in',
                onSelect: () {
                  if (st.isLoggedIn.value) {
                    st.logout();
                  } else {
                    Navigator.of(context).push(tvRoute(const TvStremioSignIn()));
                  }
                },
              )),
        ]);
      });

  Widget _layout() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row('Windows layout', 'Switch to the full Windows layout (made for the Magic Remote pointer). Restart the app to come back.',
            trailing: TvButton(
              label: 'Switch',
              onSelect: () {
                PlusTvUi.enabled = false;
                Get.offAll(() => const FilterScreen());
              },
            )),
      ]);

  Widget _about() => ValueListenableBuilder<List<String>>(
        valueListenable: PlusTvUi.keyLog,
        builder: (context, keys, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _row('AnymeX+ (Flutter, test build)', AppChannel.isBeta ? 'Beta channel' : 'Stable channel'),
          _row('The Back button',
              "LG doesn't pass the remote's Back button to Flutter apps yet (the TV asks to exit instead; LG plans to change this). "
              'Until then, Left at the left edge goes back: it closes a page or opens the menu.'),
          _row('Last remote keys', keys.isEmpty ? 'Press a few buttons on the remote' : keys.join('\n')),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final accent = TvStyle.accent(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 64, TvStyle.pad, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 400,
          child: FocusTraversalGroup(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 28),
                child: Text('Settings', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
              for (var i = 0; i < _cats.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TvFocusable(
                    onSelect: () => setState(() => _cat = i),
                    onFocus: (f) {
                      if (f) setState(() => _cat = i);
                    },
                    builder: (context, f) => Container(
                      height: 64,
                      width: 380,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: f ? Colors.white : (i == _cat ? accent.withValues(alpha: 0.18) : Colors.transparent),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(_cats[i],
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: f ? Colors.black : (i == _cat ? Colors.white : const Color(0xFF9A9A9A)))),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 56),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 96, bottom: 200),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_cats[_cat].toUpperCase(), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 3, color: accent)),
              ),
              if (_cat == 0) _accounts() else if (_cat == 1) _layout() else _about(),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Stremio sign-in on the TV: open the link on your phone and enter the code.
class TvStremioSignIn extends StatefulWidget {
  const TvStremioSignIn({super.key});

  @override
  State<TvStremioSignIn> createState() => _TvStremioSignInState();
}

class _TvStremioSignInState extends State<TvStremioSignIn> {
  String _code = '';
  String _link = '';
  String _qr = '';
  String _msg = 'Getting a code…';
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  Future<void> _start() async {
    final st = StremioService.to;
    try {
      final c = await st.createLinkCode();
      if (_gone) return;
      setState(() {
        _code = c.code;
        _link = c.link;
        _qr = c.qrcode ?? '';
        _msg = 'Waiting for you to confirm on your phone…';
      });
      final ok = await st.waitForLinkCode(c.code, isCancelled: () => _gone);
      if (_gone) return;
      if (ok) {
        tvToast(context, 'Signed in to Stremio');
        Navigator.of(context).maybePop();
      } else {
        setState(() => _msg = 'The code ran out. Press OK to get a new one.');
      }
    } catch (e) {
      if (!_gone) setState(() => _msg = "Couldn't reach Stremio. Press OK to try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget? qr;
    if (_qr.isNotEmpty) {
      try {
        final data = _qr.contains(',') ? _qr.split(',').last : _qr;
        qr = Image.memory(base64Decode(data), width: 320, height: 320, filterQuality: FilterQuality.none);
      } catch (_) {}
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 90, TvStyle.pad, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Sign in to Stremio', style: TextStyle(fontSize: 52, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 30),
            const Text('On your phone or computer, open', style: TextStyle(fontSize: 26, color: TvStyle.text2)),
            const SizedBox(height: 8),
            Text(_link.isEmpty ? 'link.stremio.com' : _link.replaceFirst(RegExp(r'^https?://'), ''),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 26),
            const Text('and enter this code:', style: TextStyle(fontSize: 26, color: TvStyle.text2)),
            const SizedBox(height: 12),
            Text(_code.isEmpty ? '…' : _code, style: const TextStyle(fontSize: 84, fontWeight: FontWeight.w800, letterSpacing: 10, color: Colors.white)),
            const SizedBox(height: 30),
            Text(_msg, style: const TextStyle(fontSize: 22, color: TvStyle.dim)),
            const SizedBox(height: 30),
            TvButton(
              label: 'New code',
              autofocus: true,
              onSelect: () {
                if (_msg.startsWith('Waiting')) return;
                setState(() => _msg = 'Getting a code…');
                _start();
              },
            ),
          ]),
        ),
        if (qr != null)
          Container(padding: const EdgeInsets.all(16), color: Colors.white, child: qr),
      ]),
    );
  }
}
