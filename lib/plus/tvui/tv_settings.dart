import 'package:anymex/controllers/services/anilist/anilist_auth.dart';
import 'package:anymex/main.dart' show FilterScreen;
import 'package:anymex/plus/app_channel.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/plus/tvui/tv_shell.dart';
import 'package:anymex/plus/tvui/tv_widgets.dart';
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
          _row('Stremio', st.isLoggedIn.value ? 'Signed in · ${st.addons.length} addons' : 'Not signed in'),
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
