import 'dart:async';

import 'package:anymex/controllers/services/stremio/stremio_api.dart';
import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/controllers/services/storage/anymex_cache_manager.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_bottomsheet.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_button.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_dialog.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_linear_indicator.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_section_builder.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_tile.dart';
import 'package:anymex/widgets/common/anymex_scaffold.dart';
import 'package:anymex/widgets/common/custom_tiles.dart';
import 'package:anymex/widgets/helper/scroll_wrapper.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stremio login, sync settings and addon management, styled like
/// AnymeX's Accounts settings.
class StremioAccountPage extends StatefulWidget {
  const StremioAccountPage({super.key});

  @override
  State<StremioAccountPage> createState() => _StremioAccountPageState();
}

class _StremioAccountPageState extends State<StremioAccountPage> {
  final _service = StremioService.to;
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      snackBar('Enter your Stremio email and password');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await _service.login(_email.text, _password.text);
      _password.clear();
      snackBar('Logged in to Stremio');
    } catch (e) {
      snackBar(e is StremioApiException ? e.message : 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loginWithLink() async {
    StremioLinkCode code;
    try {
      code = await _service.createLinkCode();
    } catch (e) {
      snackBar('Could not start code login: $e');
      return;
    }
    if (!mounted) return;
    var closed = false;
    final sheetContext = context;
    final sheet = AnymeXSheet.custom(
      _LinkCodeSheet(code: code),
      sheetContext,
      showDragHandle: true,
    ).whenComplete(() => closed = true);
    unawaited(
        launchUrl(Uri.parse(code.link), mode: LaunchMode.externalApplication));
    final ok =
        await _service.waitForLinkCode(code.code, isCancelled: () => closed);
    if (!closed && mounted) Navigator.of(sheetContext).pop();
    await sheet;
    if (ok) {
      snackBar('Logged in to Stremio');
    } else if (!closed) {
      snackBar('The code expired, try again');
    }
  }

  void _addAddon() {
    final controller = TextEditingController();
    AnymeXDialog(
      title: 'Install addon',
      contentWidget: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _AnymeXField(
          controller: controller,
          hint: 'https://…/manifest.json',
          icon: Icons.link_rounded,
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
      ),
      confirmText: 'Install',
      onConfirm: () async {
        final url = controller.text.trim();
        if (url.isEmpty) return;
        setState(() => _busy = true);
        try {
          final addon = await _service.installAddon(url);
          snackBar('Installed ${addon.name}');
        } catch (e) {
          snackBar('Install failed: $e');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      },
    ).show(context);
  }

  void _removeAddon(StremioAddon addon) {
    AnymeXDialog(
      title: 'Remove ${addon.name}?',
      message: _service.isLoggedIn.value
          ? 'It will also be removed from your Stremio account.'
          : 'It will be removed from this app.',
      confirmText: 'Remove',
      onConfirm: () async {
        try {
          await _service.uninstallAddon(addon);
        } catch (e) {
          snackBar('Could not remove addon: $e');
        }
      },
    ).show(context);
  }

  @override
  Widget build(BuildContext context) {
    return AnymeXScaffold(
      showHeader: true,
      headerTitle: 'Stremio',
      headerSubtitle: 'Account, sync & addons',
      headerAction: IconButton(
        tooltip: 'Reload',
        icon: const Icon(Icons.refresh_rounded),
        onPressed: () {
          _service.refreshAddons();
          _service.refreshContinueWatching();
        },
      ),
      body: Builder(
        builder: (ctx) => Obx(() {
          final loggedIn = _service.isLoggedIn.value;
          final syncOn = _service.syncEnabled.value;
          final addons = _service.addons.toList();
          return ScrollWrapper(
            comfortPadding: false,
            customPadding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 120.0),
            children: [
              SizedBox(height: AnymeXHeaderScope.of(ctx)),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(50),
                    child: AnymeXLinearIndicator(
                      minHeight: 3,
                      color: context.colors.primary,
                    ),
                  ),
                ),
              AnymeXSectionBuilder(
                title: 'Account',
                children: [
                  if (loggedIn) _accountTile(context) else _loginForm(context),
                ],
              ),
              const SizedBox(height: 16),
              AnymeXSectionBuilder(
                title: 'Sync',
                children: [
                  CustomSwitchTile(
                    icon: Icons.sync_rounded,
                    title: 'Sync watch progress to Stremio',
                    description:
                        'Continue Watching and watched episodes update in '
                        'Stremio as you watch here',
                    switchValue: syncOn,
                    disabled: !loggedIn,
                    onChanged: _service.setSyncEnabled,
                  ),
                  CustomSwitchTile(
                    icon: Icons.animation_rounded,
                    title: 'Include anime from AniList / MAL',
                    description:
                        'Matches each anime to its Stremio entry (Kitsu or '
                        'IMDb) and syncs episodes',
                    switchValue: _service.syncAnime.value,
                    disabled: !loggedIn || !syncOn,
                    onChanged: _service.setSyncAnime,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AnymeXSectionBuilder(
                title: 'Addons',
                children: [
                  ...addons.map((a) => _addonTile(context, a)),
                  if (addons.isEmpty && _service.addonsLoading.value)
                    const AnymeXTile(
                      icon: Icons.hourglass_top_rounded,
                      title: 'Loading addons…',
                      showChevron: false,
                    ),
                  AnymeXTile(
                    icon: Icons.add_rounded,
                    title: 'Install addon',
                    subtitle: loggedIn
                        ? 'From a manifest URL · saved to your Stremio account'
                        : 'From a manifest URL',
                    onTap: _busy ? null : _addAddon,
                  ),
                ],
              ),
              if (!loggedIn)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                  child: AnymeXText(
                    'Log in to use the addons installed on your Stremio account.',
                    size: 12,
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _accountTile(BuildContext context) {
    final avatar = _service.userAvatar.value;
    final email = _service.userEmail.value;
    final colors = context.colors;
    return AnymeXTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        clipBehavior: Clip.antiAlias,
        child: avatar.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: avatar,
                cacheManager: AnymeXCacheManager.instance,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) =>
                    Icon(Icons.person_rounded, color: colors.primary),
              )
            : Container(
                color: colors.surfaceContainerHighest.opaque(0.35),
                child: Icon(Icons.live_tv_rounded, color: colors.primary),
              ),
      ),
      title: 'Stremio',
      subtitle: email.isEmpty ? 'Connected' : 'Connected as $email',
      subtitleStyle:
          TextStyle(color: colors.primary, fontWeight: FontWeight.w500),
      showChevron: false,
      trailing: IconButton(
        icon: Icon(Icons.logout_rounded, size: 20, color: colors.error),
        tooltip: 'Log Out',
        onPressed: () => AnymeXDialog(
          title: 'Log Out',
          message: 'Are you sure you want to log out from Stremio?',
          confirmText: 'Log Out',
          onConfirm: () async {
            await _service.logout();
            snackBar('Logged out of Stremio');
          },
        ).show(context),
      ),
    );
  }

  Widget _loginForm(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AnymeXField(
              controller: _email,
              hint: 'Email',
              icon: Icons.alternate_email_rounded,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
            ),
            const SizedBox(height: 10),
            _AnymeXField(
              controller: _password,
              hint: 'Password',
              icon: Icons.lock_outline_rounded,
              obscure: _obscure,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _login(),
              suffix: IconButton(
                icon: Icon(
                    _obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    size: 20),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            const SizedBox(height: 14),
            AnymeXButton(
              onTap: _busy ? () {} : _login,
              height: 46,
              backgroundColor: colors.primary,
              borderRadius: BorderRadius.circular(14),
              child: AnymeXText('Log in',
                  variant: TextVariant.bold, color: colors.onPrimary),
            ),
            const SizedBox(height: 8),
            AnymeXButton(
              onTap: _busy ? () {} : _loginWithLink,
              height: 46,
              variant: ButtonVariant.outline,
              borderRadius: BorderRadius.circular(14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_rounded, size: 18, color: colors.primary),
                  const SizedBox(width: 8),
                  AnymeXText('Log in with Google / Apple (code)',
                      variant: TextVariant.semiBold, color: colors.primary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addonTile(BuildContext context, StremioAddon addon) {
    final logo = addon.logo;
    final colors = context.colors;
    final resources = <String>[
      if (addon.hasResource('catalog')) 'Catalogs',
      if (addon.hasResource('meta')) 'Metadata',
      if (addon.hasResource('stream')) 'Streams',
      if (addon.hasResource('subtitles')) 'Subtitles',
    ];
    return AnymeXTile(
      leading: Container(
        width: 38,
        height: 38,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.opaque(0.35),
          borderRadius: BorderRadius.circular(10),
        ),
        child: logo != null
            ? CachedNetworkImage(
                imageUrl: logo,
                fit: BoxFit.contain,
                errorWidget: (_, __, ___) =>
                    Icon(Icons.extension_rounded, color: colors.primary),
              )
            : Icon(Icons.extension_rounded, color: colors.primary),
      ),
      title: addon.name,
      subtitle: [
        if (addon.version.isNotEmpty) 'v${addon.version}',
        resources.join(', '),
      ].where((s) => s.isNotEmpty).join(' · '),
      showChevron: false,
      trailing: addon.isProtected
          ? null
          : IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: colors.error),
              tooltip: 'Remove',
              onPressed: () => _removeAddon(addon),
            ),
    );
  }
}

/// Text field in AnymeX's rounded, translucent style.
class _AnymeXField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final bool autofocus;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

  const _AnymeXField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.autofocus = false,
    this.keyboardType,
    this.autofillHints,
    this.onSubmitted,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: autofocus,
      keyboardType: keyboardType,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      style: TextStyle(color: colors.onSurface, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: colors.onSurfaceVariant),
        suffixIcon: suffix,
        filled: true,
        fillColor: colors.surfaceContainerHighest.opaque(0.4, iReallyMeanIt: true),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.primary, width: 1.2),
        ),
      ),
    );
  }
}

class _LinkCodeSheet extends StatelessWidget {
  final StremioLinkCode code;
  const _LinkCodeSheet({required this.code});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.qr_code_rounded, color: colors.primary, size: 22),
              const SizedBox(width: 10),
              const AnymeXText('Log in with a code',
                  size: 16, variant: TextVariant.bold),
            ],
          ),
          const SizedBox(height: 10),
          AnymeXText(
            'Open stremio.com, sign in (Google, Apple, Facebook or email) '
            'and confirm this code:',
            size: 13,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Center(
            child: SelectableText(
              code.code,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
                color: colors.primary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: AnymeXButton(
                  onTap: () => launchUrl(Uri.parse(code.link),
                      mode: LaunchMode.externalApplication),
                  height: 44,
                  backgroundColor: colors.primary,
                  borderRadius: BorderRadius.circular(14),
                  child: AnymeXText('Open stremio.com',
                      variant: TextVariant.bold, color: colors.onPrimary),
                ),
              ),
              const SizedBox(width: 8),
              AnymeXButton(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code.link));
                  snackBar('Link copied');
                },
                height: 44,
                width: 52,
                variant: ButtonVariant.outline,
                borderRadius: BorderRadius.circular(14),
                child: Icon(Icons.copy_rounded, size: 18, color: colors.primary),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: colors.primary),
              ),
              const SizedBox(width: 10),
              AnymeXText('Waiting for confirmation…',
                  size: 12, color: colors.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
