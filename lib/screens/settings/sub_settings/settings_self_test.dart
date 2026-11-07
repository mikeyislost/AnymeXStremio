import 'dart:io';

import 'package:anymex/utils/self_test.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_button.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_linear_indicator.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_section_builder.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_tile.dart';
import 'package:anymex/widgets/common/anymex_scaffold.dart';
import 'package:anymex/widgets/helper/scroll_wrapper.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

/// Settings → Diagnostics → Self Test.
class SettingsSelfTest extends StatefulWidget {
  const SettingsSelfTest({super.key});

  @override
  State<SettingsSelfTest> createState() => _SettingsSelfTestState();
}

class _SettingsSelfTestState extends State<SettingsSelfTest> {
  final SelfTestRunner runner = Get.isRegistered<SelfTestRunner>()
      ? Get.find<SelfTestRunner>()
      : Get.put(SelfTestRunner(), permanent: true);

  Future<void> _start(bool full) async {
    final path = await runner.run(comprehensive: full);
    if (!mounted) return;
    final fails = runner.count(SelfTestStatus.fail);
    final warns = runner.count(SelfTestStatus.warn);
    snackBar(path == null
        ? 'Test finished, but the report could not be saved'
        : (fails + warns == 0
            ? 'All checks passed. Report saved'
            : '$fails failed, $warns warnings. Report saved'));
  }

  Future<void> _share() async {
    final path = runner.reportPath.value;
    if (path.isEmpty) return;
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path)],
        subject: 'AnymeX+ self test report',
      ));
    } catch (e) {
      snackBar('Could not share: $e');
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: await runner.buildReport()));
    snackBar('Report copied to clipboard');
  }

  Future<void> _openFolder() async {
    final path = runner.reportPath.value;
    if (path.isEmpty) return;
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,$path']);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    }
  }

  Color _statusColor(BuildContext context, SelfTestStatus s) {
    final c = context.colors;
    return switch (s) {
      SelfTestStatus.pass => Colors.green,
      SelfTestStatus.warn => Colors.orange,
      SelfTestStatus.fail => c.error,
      SelfTestStatus.skip => c.onSurfaceVariant,
      SelfTestStatus.info => c.primary,
    };
  }

  IconData _statusIcon(SelfTestStatus s) => switch (s) {
        SelfTestStatus.pass => Icons.check_circle_rounded,
        SelfTestStatus.warn => Icons.warning_amber_rounded,
        SelfTestStatus.fail => Icons.cancel_rounded,
        SelfTestStatus.skip => Icons.remove_circle_outline_rounded,
        SelfTestStatus.info => Icons.info_outline_rounded,
      };

  void _showDetail(SelfTestResult r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: AnymeXText('${r.group} › ${r.name}',
            variant: TextVariant.bold, size: 15),
        content: SingleChildScrollView(
          child: SelectableText(
            '${r.symbol} · ${r.duration.inMilliseconds} ms\n\n${r.detail}'
            '${r.error == null ? '' : '\n\n${r.error}'}',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnymeXScaffold(
      showHeader: true,
      headerTitle: 'Self Test',
      headerSubtitle: 'Check the app, accounts, Stremio & sync',
      body: Builder(
        builder: (ctx) => Obx(() {
          final running = runner.running.value;
          final results = runner.results.toList();
          final total = runner.total.value;
          final path = runner.reportPath.value;

          final groups = <String, List<SelfTestResult>>{};
          for (final r in results) {
            groups.putIfAbsent(r.group, () => []).add(r);
          }

          return ScrollWrapper(
            comfortPadding: false,
            customPadding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            children: [
              SizedBox(height: AnymeXHeaderScope.of(ctx)),
              AnymeXSectionBuilder(
                title: 'Run',
                children: [
                  AnymeXTile(
                    icon: Icons.bolt_rounded,
                    title: 'Quick test',
                    subtitle:
                        'Essentials: app, storage, accounts, Stremio, comments, '
                        'updates (~15 s)',
                    enabled: !running,
                    onTap: running ? null : () => _start(false),
                  ),
                  AnymeXTile(
                    icon: Icons.fact_check_rounded,
                    title: 'Full test',
                    subtitle:
                        'Everything: every addon & catalog, streams, search, '
                        'AniList ↔ Stremio mapping for your anime, speed (~1–3 min)',
                    enabled: !running,
                    onTap: running ? null : () => _start(true),
                  ),
                ],
              ),
              if (running) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(50),
                  child: AnymeXLinearIndicator(
                    value: total == 0 ? null : results.length / total,
                    minHeight: 6,
                    color: colors.primary,
                    backgroundColor:
                        colors.onSurface.opaque(0.1, iReallyMeanIt: true),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: AnymeXText(
                        '${results.length}/$total · ${runner.current.value}',
                        size: 12,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    TextButton(
                        onPressed: runner.cancel, child: const Text('Cancel')),
                  ],
                ),
              ],
              if (results.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in SelfTestStatus.values)
                      if (runner.count(s) > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _statusColor(context, s)
                                .opaque(0.14, iReallyMeanIt: true),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_statusIcon(s),
                                  size: 14, color: _statusColor(context, s)),
                              const SizedBox(width: 5),
                              AnymeXText(
                                '${runner.count(s)} ${s.name}',
                                size: 12,
                                variant: TextVariant.semiBold,
                                color: _statusColor(context, s),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ],
              if (!running && path.isNotEmpty) ...[
                const SizedBox(height: 16),
                AnymeXSectionBuilder(
                  title: 'Report',
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            path,
                            style: TextStyle(
                                fontSize: 12, color: colors.onSurfaceVariant),
                          ),
                          if (Platform.isIOS) ...[
                            const SizedBox(height: 6),
                            AnymeXText(
                              'Also in the Files app: On My iPhone → AnymeX+ → '
                              'AnymeX+ Self Tests',
                              size: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: AnymeXButton(
                                  onTap: _share,
                                  height: 42,
                                  backgroundColor: colors.primary,
                                  borderRadius: BorderRadius.circular(14),
                                  child: AnymeXText('Share',
                                      variant: TextVariant.bold,
                                      color: colors.onPrimary),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: AnymeXButton(
                                  onTap: _copy,
                                  height: 42,
                                  variant: ButtonVariant.outline,
                                  borderRadius: BorderRadius.circular(14),
                                  child: AnymeXText('Copy',
                                      variant: TextVariant.bold,
                                      color: colors.primary),
                                ),
                              ),
                              if (Platform.isWindows || Platform.isMacOS) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: AnymeXButton(
                                    onTap: _openFolder,
                                    height: 42,
                                    variant: ButtonVariant.outline,
                                    borderRadius: BorderRadius.circular(14),
                                    child: AnymeXText('Show file',
                                        variant: TextVariant.bold,
                                        color: colors.primary),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
              for (final entry in groups.entries) ...[
                const SizedBox(height: 16),
                AnymeXSectionBuilder(
                  title: entry.key,
                  children: [
                    for (final r in entry.value)
                      AnymeXTile(
                        leading: Icon(_statusIcon(r.status),
                            color: _statusColor(context, r.status)),
                        title: r.name,
                        subtitle: r.detail,
                        maxLines: 3,
                        showChevron: false,
                        onTap: () => _showDetail(r),
                      ),
                  ],
                ),
              ],
            ],
          );
        }),
      ),
    );
  }
}
