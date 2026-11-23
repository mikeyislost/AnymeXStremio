import 'dart:convert';

import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/controllers/services/mal/mal_service.dart';
import 'package:anymex/controllers/services/simkl/simkl_service.dart';
import 'package:anymex/plus/tvui/tv_ext.dart';
import 'package:anymex/plus/tvui/tv_pair.dart';
import 'package:anymex/plus/tvui/tv_back_key.dart';
import 'package:anymex/main.dart' show FilterScreen;
import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_player.dart' show TvPlayerDebug, TvPlayerPrefs;
import 'package:anymex/plus/tvui/tv_home_rows.dart';
import 'package:anymex/plus/tvui/tv_home.dart' show TvHomePage;
import 'package:anymex/controllers/theme.dart';
import 'package:anymex/constants/contants.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:provider/provider.dart';
import 'package:anymex/plus/tvui/tv_shell.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
import 'package:anymex/theme/yumori_tokens.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Settings on the TV: categories on the left, their options on the right.
class TvSettingsPage extends StatefulWidget {
  const TvSettingsPage({super.key});

  @override
  State<TvSettingsPage> createState() => _TvSettingsPageState();
}

class _TvSettingsPageState extends State<TvSettingsPage> {
  int _runnerLogAsk = 0; // Refresh on About this TV asks the runner again
  int _cat = 0;
  static const _cats = ['Accounts', 'Home rows', 'Addons', 'Player', 'Appearance', 'Layout', 'About this TV'];
  final _removing = <String>{}; // addons waiting for a second press

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
        final simkl = Get.find<SimklService>();
        final mal = Get.find<MalService>();
        final st = StremioService.to;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ValueListenableBuilder<String>(
            valueListenable: PlusTvPair.instance.status,
            builder: (context, st, _) => _row(
                'Get logins from your phone',
                st.isNotEmpty
                    ? st
                    : 'Your phone or PC sends AniList, Simkl, MyAnimeList and Stremio to the TV. After the first time it keeps them fresh by itself.',
                trailing: TvButton(
                  label: 'Connect',
                  onSelect: () => Navigator.of(context).push(tvRoute(const TvPhoneLogins())),
                )),
          ),
          _row('AniList', auth.isLoggedIn.value ? 'Signed in as ${auth.profileData.value.name ?? 'you'}' : 'Not signed in'),
          ValueListenableBuilder<String>(
            valueListenable: TvExt.instance.using,
            builder: (context, dev, _) {
              final list = TvExt.instance.devices;
              return _row(
                  'Extensions',
                  list.isEmpty
                      ? 'Not paired: your phone or PC runs your extensions for the TV once you get logins from it.'
                      : '${list.map((d) => d.name + (d.name == dev ? ' (connected)' : '')).join(', ')} · works while the app is open there',
                  trailing: list.isEmpty
                      ? null
                      : TvButton(
                          label: 'Forget',
                          onSelect: () {
                            TvExt.instance.forget();
                            setState(() {});
                          }));
            },
          ),
          _row('Simkl', simkl.isLoggedIn.value ? 'Signed in as ${simkl.profileData.value.name ?? 'you'}' : 'Not signed in'),
          _row('MyAnimeList', mal.isLoggedIn.value ? 'Signed in as ${mal.profileData.value.name ?? 'you'}' : 'Not signed in'),
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

  // ---- Home rows ------------------------------------------------------------

  Widget _homeRows() => ValueListenableBuilder<int>(
        valueListenable: TvHomeRows.version,
        builder: (context, _, __) {
          final rows = TvHomeRows.load();
          final shown = [for (final r in rows) if (r.on) TvHomeRows.title(r.key)];
          final hidden = rows.length - shown.length;
          return FocusTraversalGroup(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _row('Edit rows', 'Opens Home with every row and its cards, so you can see what you move or hide.',
                  trailing: TvButton(
                    label: 'Edit rows',
                    icon: Icons.edit_rounded,
                    primary: true,
                    onSelect: () => Navigator.of(context).push(tvRoute(const TvHomePage(editing: true))),
                  )),
              _row('On Home now', '${shown.join(' · ')}${hidden > 0 ? '\n$hidden hidden' : ''}',
                  trailing: TvButton(label: 'Reset', onSelect: TvHomeRows.reset)),
            ]),
          );
        },
      );

  // ---- Addons --------------------------------------------------------------

  Widget _addons() => Obx(() {
        final st = StremioService.to;
        final list = st.addons.toList();
        st.unreachableAddons.length; // rebuild when health changes
        if (!st.isLoggedIn.value && list.isEmpty) {
          return _row('No addons yet', 'Sign in to Stremio (Accounts) and your addons show here.');
        }
        return FocusTraversalGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row('Your Stremio addons',
                'Sources are tried in this order. To add one, install it on your phone or at stremio.com: it comes to the TV with your Stremio account.',
                trailing: TvButton(
                  label: st.addonsLoading.value ? 'Refreshing…' : 'Refresh',
                  onSelect: () async {
                    await st.refreshAddons();
                    await st.checkAddonHealth();
                    if (mounted) tvToast(context, 'Addons refreshed');
                  },
                )),
            for (var i = 0; i < list.length; i++)
              KeyedSubtree(
                key: ValueKey('addon-${list[i].transportUrl}'),
                child: _row(
                  '${i + 1}.  ${list[i].name}',
                  st.unreachableAddons[list[i].transportUrl] != null
                      ? 'Not working: ${st.unreachableAddons[list[i].transportUrl]}'
                      : (list[i].description ?? '').replaceAll('\n', ' ').trim().isEmpty
                          ? 'Working'
                          : (list[i].description ?? '').replaceAll('\n', ' ').trim(),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    TvButton(label: '↑', onSelect: () => st.moveAddon(list[i], -1)),
                    const SizedBox(width: 12),
                    TvButton(label: '↓', onSelect: () => st.moveAddon(list[i], 1)),
                    if (!list[i].isProtected) ...[
                      const SizedBox(width: 12),
                      TvButton(
                        label: _removing.contains(list[i].transportUrl) ? 'Press again' : 'Remove',
                        onSelect: () async {
                          final a = list[i];
                          if (!_removing.contains(a.transportUrl)) {
                            setState(() => _removing.add(a.transportUrl));
                            return;
                          }
                          setState(() => _removing.remove(a.transportUrl));
                          await st.uninstallAddon(a);
                          if (mounted) tvToast(context, 'Removed ${a.name}');
                        },
                      ),
                    ],
                  ]),
                ),
              ),
          ]),
        );
      });

  // ---- Player --------------------------------------------------------------

  Widget _onOff(bool on, ValueChanged<bool> set) => SizedBox(
        width: 130,
        child: TvButton(label: on ? 'On' : 'Off', primary: on, onSelect: () => setState(() => set(!on))),
      );

  Widget _player() {
    final sub = TvPlayerPrefs.subLang, audio = TvPlayerPrefs.audioLang;
    return FocusTraversalGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row('Play the next episode', 'When an episode ends, the next one starts with a source like the one you used.',
            trailing: _onOff(TvPlayerPrefs.autoNext, (v) => TvPlayerPrefs.autoNext = v)),
        _row('Skip intros and recaps', 'Jumps past them by itself (once, so you can go back). Credits keep their button.',
            trailing: _onOff(TvPlayerPrefs.autoSkip, (v) => TvPlayerPrefs.autoSkip = v)),
        _row('Subtitles',
            sub.isEmpty ? 'Off until you pick a language in the player; then it remembers it.' : 'Remembered: ${TvPlayerPrefs.langName(sub)}',
            trailing: sub.isEmpty ? null : TvButton(label: 'Forget', onSelect: () => setState(TvPlayerPrefs.forgetSubLang))),
        _row('Audio language',
            audio.isEmpty ? 'The video\'s own until you pick one in the player.' : 'Remembered: ${TvPlayerPrefs.langName(audio)}',
            trailing: audio.isEmpty ? null : TvButton(label: 'Forget', onSelect: () => setState(TvPlayerPrefs.forgetAudioLang))),
      ]),
    );
  }

  // ---- Appearance ----------------------------------------------------------

  Widget _appearance() {
    final theme = Provider.of<ThemeProvider>(context);
    final custom = theme.currentThemeMode == 'custom';
    final current = custom ? ThemeKeys.customColorIndex.get<int>(0) : -2; // -2: default
    Widget swatch(String name, Color c, bool on, VoidCallback pick) => TvFocusable(
          onSelect: pick,
          builder: (context, f) => Padding(
            padding: const EdgeInsets.all(10),
            child: TvRing(
              on: f,
              radius: 32,
              gap: 4,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                child: on ? const Icon(Icons.check_rounded, color: Colors.white, size: 34) : null,
              ),
            ),
          ),
        );
    return FocusTraversalGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row('Moving highlight', 'A coloured glint keeps travelling round the box you\'re on. Off: a plain white ring.',
            trailing: ValueListenableBuilder<bool>(
              valueListenable: TvRing.animated,
              builder: (context, on, _) => _onOff(on, (v) => TvRing.moving = v),
            )),
        ValueListenableBuilder<String>(
          valueListenable: TvStyle.palette,
          builder: (context, p, _) => _row(
              'Palette',
              p == 'yumori'
                  ? 'Yumori: lavender highlights with cream glints. The accent colour below is ignored.'
                  : 'Your colour: the accent colour below.',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 170, child: TvButton(label: 'Yumori', primary: p == 'yumori', onSelect: () => TvStyle.setPalette('yumori'))),
                const SizedBox(width: 14),
                SizedBox(width: 200, child: TvButton(label: 'Your colour', primary: p != 'yumori', onSelect: () => TvStyle.setPalette('default'))),
              ])),
        ),
        ValueListenableBuilder<double>(
          valueListenable: TvRing.lap,
          builder: (context, lap, _) {
            const steps = 12;
            final pos = ((TvRing.lapMax - lap) / (TvRing.lapMax - TvRing.lapMin) * steps).round(); // 0 slow … 12 fast
            void set(int p) => TvRing.setLap(TvRing.lapMax - p.clamp(0, steps) * (TvRing.lapMax - TvRing.lapMin) / steps);
            return _row(
              'Glint speed',
              '${lap.toStringAsFixed(lap % 1 == 0 ? 0 : 1)} seconds a lap${lap == TvRing.lapDefault ? ' (default)' : ''}',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TvButton(label: 'Slower', onSelect: () => set(pos - 1)),
                const SizedBox(width: 14),
                SizedBox(
                  width: 260,
                  height: 10,
                  child: Stack(children: [
                    Container(decoration: BoxDecoration(color: TvStyle.chip, borderRadius: BorderRadius.circular(5))),
                    FractionallySizedBox(
                      widthFactor: (pos + 1) / (steps + 1),
                      child: Container(decoration: BoxDecoration(color: TvStyle.accent(context), borderRadius: BorderRadius.circular(5))),
                    ),
                  ]),
                ),
                const SizedBox(width: 14),
                TvButton(label: 'Faster', onSelect: () => set(pos + 1)),
                const SizedBox(width: 14),
                TvButton(label: 'Default', onSelect: () => TvRing.setLap(TvRing.lapDefault)),
              ]),
            );
          },
        ),
        _row('Accent colour', 'Used for the highlight\'s glint, progress bars and labels. Shared with the Windows layout on this TV.'),
        Wrap(children: [
          swatch('Default', Colors.indigo, current == -2, theme.setDefaultTheme),
          for (var i = 0; i < colorList.length; i++)
            swatch(colorMap.keys.elementAt(i), colorList[i], current == i, () => theme.setCustomSeedColor(i)),
        ]),
        const SizedBox(height: 18),
        ValueListenableBuilder<int>(
          valueListenable: TvRing.second,
          builder: (context, sec, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row('Second colour',
                sec < 0
                    ? 'Auto: a colour next to your accent. The glints fade from your accent into it.'
                    : 'The glints fade from your accent into ${colorMap.keys.elementAt(sec)}.'),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: 130,
                  child: TvButton(label: 'Auto', primary: sec < 0, onSelect: () => TvRing.setSecond(-1)),
                ),
              ),
              for (var i = 0; i < colorList.length; i++)
                swatch(colorMap.keys.elementAt(i), TvStyle.strong(colorList[i]), sec == i, () => TvRing.setSecond(i)),
            ]),
          ]),
        ),
      ]),
    );
  }

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
          _row('Yumori for TV (test build)', AppChannel.isBeta ? 'Beta channel' : 'Stable channel'),
          ValueListenableBuilder<String>(
            valueListenable: TvBackKey.status,
            builder: (context, status, _) => _row(
              'The Back button',
              "LG's SDK doesn't pass Back to Flutter apps yet, so the app asks webOS for it. "
              'On: Back closes pages, opens the menu, then asks before leaving. '
              "Off: the TV's own exit popup. Left at the left edge also goes back.\n"
              'Now: $status',
              trailing: TvButton(
                label: TvBackKey.enabled ? 'On' : 'Off',
                primary: TvBackKey.enabled,
                onSelect: () async {
                  await TvBackKey.setEnabled(!TvBackKey.enabled);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
          FutureBuilder<List<String>>(
            key: ValueKey(_runnerLogAsk),
            future: TvBackKey.nativeLog(),
            builder: (context, snap) => _row(
              'What the TV runner did',
              snap.hasData ? (snap.data!.isEmpty ? 'Nothing yet' : snap.data!.join('\n')) : 'Asking…',
              trailing: TvButton(label: 'Refresh', onSelect: () => setState(() => _runnerLogAsk++)),
            ),
          ),
          _row('Last remote keys', keys.isEmpty ? 'Press a few buttons on the remote' : keys.join('\n')),
          if (TvPlayerDebug.lastSourceInfo.isNotEmpty)
            _row('Last video: what the TV reported',
                TvPlayerDebug.lastSourceInfo.length > 900 ? '${TvPlayerDebug.lastSourceInfo.substring(0, 900)}…' : TvPlayerDebug.lastSourceInfo),
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
                        color: f ? accent : (i == _cat ? accent.withValues(alpha: 0.16) : Colors.transparent),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(_cats[i],
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: f ? TvStyle.onAccent : (i == _cat ? YumoriColors.text : TvStyle.dim))),
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
              switch (_cats[_cat]) {
                'Accounts' => _accounts(),
                'Home rows' => _homeRows(),
                'Addons' => _addons(),
                'Player' => _player(),
                'Appearance' => _appearance(),
                'Layout' => _layout(),
                _ => _about(),
              },
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

/// "Get logins from your phone": a code to type on the phone.
class TvPhoneLogins extends StatefulWidget {
  const TvPhoneLogins({super.key});

  @override
  State<TvPhoneLogins> createState() => _TvPhoneLoginsState();
}

class _TvPhoneLoginsState extends State<TvPhoneLogins> {
  final _pair = PlusTvPair.instance;
  late final String _before = _pair.status.value;

  @override
  void initState() {
    super.initState();
    _pair.status.value = '';
    _pair.openPage();
    _pair.status.addListener(_onStatus);
  }

  void _onStatus() {
    if (!mounted) return;
    // Done once the code was used (the page then has no code any more).
    if (!_pair.isOpen && _pair.status.value.startsWith('Logins from')) {
      tvToast(context, _pair.status.value);
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _pair.status.removeListener(_onStatus);
    _pair.closePage();
    if (_pair.status.value.isEmpty) _pair.status.value = _before;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(TvStyle.pad, 90, TvStyle.pad, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Get logins from your phone', style: TextStyle(fontSize: 52, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 30),
        const Text('On your phone or PC, open Yumori (or AnymeX+) → Settings → TV Remote → Send logins to the Flutter TV app,',
            style: TextStyle(fontSize: 26, color: TvStyle.text2)),
        const SizedBox(height: 8),
        ValueListenableBuilder<String>(
          valueListenable: _pair.address,
          builder: (context, ip, _) => Text(
              ip.isEmpty ? 'pick this TV and type this code:' : 'pick this TV ($ip) and type this code:',
              style: const TextStyle(fontSize: 26, color: TvStyle.text2)),
        ),
        const SizedBox(height: 18),
        ValueListenableBuilder<String>(
          valueListenable: _pair.code,
          builder: (context, c, _) => Text(c.isEmpty ? '…' : '${c.substring(0, 3)} ${c.substring(3)}',
              style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w800, letterSpacing: 12, color: Colors.white)),
        ),
        const SizedBox(height: 24),
        ValueListenableBuilder<String>(
          valueListenable: _pair.status,
          builder: (context, st, _) => Text(st.isEmpty ? 'Waiting for your phone…' : st,
              style: const TextStyle(fontSize: 22, color: TvStyle.dim)),
        ),
        const SizedBox(height: 30),
        TvButton(label: 'New code', autofocus: true, onSelect: _pair.openPage),
        const SizedBox(height: 40),
        const Text('Logins are locked with this code on the way, so nobody else on your network can read them.',
            style: TextStyle(fontSize: 19, color: TvStyle.dim)),
      ]),
    );
  }
}
