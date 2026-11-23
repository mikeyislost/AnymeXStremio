// AnymeX+: edit a page's rows on the page itself. "Edit layout" turns Home,
// Movies & TV or Manga into its own editor: every row shows with what's in
// it (hidden rows dimmed), with buttons to move it, hide it or change its
// look. The list editor (Edit layout screen) stays for the Library and for
// adding rows.

import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/plus/layout/layout_editor.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:anymex/plus/layout/layout_store.dart';
import 'package:anymex/plus/layout/page_rows.dart';
import 'package:anymex/plus/stremio/ui/stremio_home_page.dart' show stremioHomeRows;
import 'package:anymex/utils/function.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PlusLayoutLive {
  PlusLayoutLive._();

  /// The page being edited in place (null = none).
  static final Rxn<PlusLayoutPage> editing = Rxn<PlusLayoutPage>();

  static bool isEditing(PlusLayoutPage p) => editing.value == p;

  static void start(PlusLayoutPage p) => editing.value = p;
  static void stop() => editing.value = null;

  static List<PlusPlacedRow> rows(PlusLayoutPage page) => switch (page) {
        PlusLayoutPage.home => PlusPageRows.homeRows(discoverByDefault: PlusPageRows.discoverByDefault),
        PlusLayoutPage.manga => PlusPageRows.mangaRows(),
        PlusLayoutPage.movies => stremioHomeRows(),
      };

  static void _save(PlusLayoutPage page, List<PlusPlacedRow> rows) {
    PlusLayoutStore.save(page, PlusLayout.toSave(rows, PlusLayoutStore.saved(page)));
  }

  /// Moves the row [key] up (−1) or down (+1).
  static void move(PlusLayoutPage page, String key, int by) {
    final list = rows(page);
    final i = list.indexWhere((r) => r.key == key);
    final j = i + by;
    if (i < 0 || j < 0 || j >= list.length) return;
    list.insert(j, list.removeAt(i));
    _save(page, list);
  }

  static void setHidden(PlusLayoutPage page, String key, bool hidden) {
    final list = rows(page);
    final i = list.indexWhere((r) => r.key == key);
    if (i < 0) return;
    // Home's list rows are AnymeX's own Home switches too.
    if (page == PlusLayoutPage.home) {
      final sw = PlusPageRows.homeSwitchFor(key);
      if (sw != null) Get.find<Settings>().updateHomePageCard(sw, !hidden);
    }
    list[i] = PlusPlacedRow(list[i].spec, list[i].config.copyWith(hidden: hidden));
    _save(page, list);
  }

  static String _pageName(PlusLayoutPage p) => switch (p) {
        PlusLayoutPage.home => 'Home',
        PlusLayoutPage.movies => 'Movies & TV',
        PlusLayoutPage.manga => 'Manga',
      };

  /// The bar at the top of a page being edited.
  static Widget bar(BuildContext context, PlusLayoutPage page) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(Icons.dashboard_customize_outlined, color: colors.onPrimaryContainer),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Editing ${_pageName(page)}',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: colors.onPrimaryContainer)),
            Text('Move or hide rows right here. ⋯ changes a row\'s look.',
                style: TextStyle(fontSize: 12, color: colors.onPrimaryContainer.withValues(alpha: 0.8))),
          ]),
        ),
        TextButton(
          onPressed: () => navigate(() => PlusLayoutEditorPage(page: page)),
          child: const Text('Add row'),
        ),
        FilledButton(onPressed: stop, child: const Text('Done')),
      ]),
    );
  }

  /// A row of a page being edited: its controls above what it shows.
  static Widget frame(BuildContext context, PlusLayoutPage page, PlusPlacedRow row, Widget? child,
      {required bool first, required bool last}) {
    final colors = context.colors;
    final hidden = row.config.hidden;
    return Container(
      key: ValueKey('plus-live-${row.key}'),
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: hidden ? colors.outlineVariant : colors.primary.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 0),
          child: Row(children: [
            Expanded(
              child: Text(row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: hidden ? colors.onSurfaceVariant : colors.onSurface)),
            ),
            if (hidden)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(label: const Text('Hidden'), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
              ),
            IconButton(
              tooltip: 'Move up',
              onPressed: first ? null : () => move(page, row.key, -1),
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
            IconButton(
              tooltip: 'Move down',
              onPressed: last ? null : () => move(page, row.key, 1),
              icon: const Icon(Icons.arrow_downward_rounded),
            ),
            IconButton(
              tooltip: hidden ? 'Show' : 'Hide',
              onPressed: () => setHidden(page, row.key, !hidden),
              icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            ),
            if (row.styled || row.config.added)
              IconButton(
                tooltip: 'Look',
                onPressed: () => navigate(() => PlusLayoutEditorPage(page: page, row: row.key)),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
          ]),
        ),
        Opacity(
          opacity: hidden ? 0.4 : 1,
          child: IgnorePointer(
            // Cards stay still while editing (no accidental opens).
            child: child ??
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text('Nothing in this row right now. It shows when it has something.',
                      style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                ),
          ),
        ),
      ]),
    );
  }
}
