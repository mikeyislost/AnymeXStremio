import 'dart:async';

import 'package:anymex/controllers/services/stremio/stremio_api.dart';
import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/controllers/services/stremio/stremio_service.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stremio login, sync settings and addon management.
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
      snackBar('Could not start link login: $e');
      return;
    }
    if (!mounted) return;
    var cancelled = false;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Log in with a code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Open the link below, sign in to Stremio (Google, Apple, '
                  'Facebook or email) and confirm this code:'),
              const SizedBox(height: 16),
              Center(
                child: SelectableText(
                  code.code,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open stremio.com'),
                      onPressed: () => launchUrl(Uri.parse(code.link),
                          mode: LaunchMode.externalApplication),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy link',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code.link));
                      snackBar('Link copied');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Row(
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Expanded(child: Text('Waiting for confirmation…')),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.of(ctx).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
    unawaited(launchUrl(Uri.parse(code.link),
        mode: LaunchMode.externalApplication));
    final ok = await _service.waitForLinkCode(code.code,
        isCancelled: () => cancelled);
    if (!cancelled && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialog;
    if (ok) {
      snackBar('Logged in to Stremio');
    } else if (!cancelled) {
      snackBar('The code expired, try again');
    }
  }

  Future<void> _addAddon() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install addon'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…/manifest.json',
            helperText: 'Paste the addon\'s manifest URL',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Install')),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    setState(() => _busy = true);
    try {
      final addon = await _service.installAddon(url);
      snackBar('Installed ${addon.name}');
    } catch (e) {
      snackBar('Install failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAddon(StremioAddon addon) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${addon.name}?'),
        content: Text(_service.isLoggedIn.value
            ? 'It will also be removed from your Stremio account.'
            : 'It will be removed from this app.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _service.uninstallAddon(addon);
    } catch (e) {
      snackBar('Could not remove addon: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stremio'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              _service.refreshAddons();
              _service.refreshContinueWatching();
            },
          ),
        ],
      ),
      body: Obx(() {
        final loggedIn = _service.isLoggedIn.value;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            if (_busy) const LinearProgressIndicator(),
            _sectionTitle(theme, 'Account'),
            if (loggedIn) _accountCard(theme) else _loginForm(theme),
            const SizedBox(height: 24),
            _sectionTitle(theme, 'Sync'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _service.syncEnabled.value,
                    onChanged: loggedIn ? _service.setSyncEnabled : null,
                    title: const Text('Sync watch progress to Stremio'),
                    subtitle: const Text(
                        'Continue Watching and watched episodes update in '
                        'Stremio as you watch here'),
                  ),
                  SwitchListTile(
                    value: _service.syncAnime.value,
                    onChanged: loggedIn && _service.syncEnabled.value
                        ? _service.setSyncAnime
                        : null,
                    title: const Text('Include anime from AniList / MAL'),
                    subtitle: const Text(
                        'Matches each anime to its Stremio entry (Kitsu or '
                        'IMDb) and syncs episodes'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: _sectionTitle(theme, 'Addons')),
                TextButton.icon(
                  onPressed: _busy ? null : _addAddon,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_service.addonsLoading.value && _service.addons.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ..._service.addons.map((a) => _addonTile(theme, a)),
            if (!loggedIn)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Log in to use the addons installed on your Stremio account.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(text,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  Widget _accountCard(ThemeData theme) {
    final avatar = _service.userAvatar.value;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundImage:
              avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
          child: avatar.isEmpty ? const Icon(Icons.person_rounded) : null,
        ),
        title: const Text('Connected'),
        subtitle: Text(_service.userEmail.value.isEmpty
            ? 'Stremio account'
            : _service.userEmail.value),
        trailing: TextButton(
          onPressed: () async {
            await _service.logout();
            snackBar('Logged out of Stremio');
          },
          child: Text('Log out',
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      ),
    );
  }

  Widget _loginForm(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _login(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: const Text('Log in'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _loginWithLink,
                icon: const Icon(Icons.link_rounded),
                label: const Text('Log in with Google / Apple (code)'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addonTile(ThemeData theme, StremioAddon addon) {
    final logo = addon.logo;
    final resources = <String>[
      if (addon.hasResource('catalog')) 'Catalogs',
      if (addon.hasResource('meta')) 'Metadata',
      if (addon.hasResource('stream')) 'Streams',
      if (addon.hasResource('subtitles')) 'Subtitles',
    ];
    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 40,
          height: 40,
          child: logo != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: logo,
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) =>
                        const Icon(Icons.extension_rounded),
                  ),
                )
              : const Icon(Icons.extension_rounded),
        ),
        title: Text(addon.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (addon.version.isNotEmpty) 'v${addon.version}',
            resources.join(', '),
          ].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: addon.isProtected
            ? null
            : IconButton(
                icon: Icon(Icons.delete_outline_rounded,
                    color: theme.colorScheme.error),
                onPressed: () => _removeAddon(addon),
              ),
      ),
    );
  }
}

