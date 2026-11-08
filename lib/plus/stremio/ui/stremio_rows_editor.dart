import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/stremio_service.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:flutter/material.dart';

/// One home row in the editor.
class StremioRowEntry {
  final String key;
  final String title;
  final String addonName;
  const StremioRowEntry(this.key, this.title, this.addonName);
}

/// AnymeX+: hide, show and reorder the Movies & TV home rows.
///
/// [rows] are every row from your addons, already in your current order
/// (hidden ones included).
Future<void> showStremioRowsEditor(
    BuildContext context, List<StremioRowEntry> rows) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.colors.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _RowsEditor(rows: rows),
  );
}

class _RowsEditor extends StatefulWidget {
  final List<StremioRowEntry> rows;
  const _RowsEditor({required this.rows});

  @override
  State<_RowsEditor> createState() => _RowsEditorState();
}

class _RowsEditorState extends State<_RowsEditor> {
  final _service = StremioService.to;
  late final List<StremioRowEntry> _rows = List.of(widget.rows);
  late final Set<String> _hidden = {..._service.hiddenRows};

  void _save() {
    _service.saveRowLayout(
        _rows.map((r) => r.key).toList(), _hidden.intersection(_keys));
  }

  Set<String> get _keys => _rows.map((r) => r.key).toSet();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shown = _rows.where((r) => !_hidden.contains(r.key)).length;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.onSurfaceVariant.opaque(0.4, iReallyMeanIt: true),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AnymeXText('Home rows',
                          size: 17, variant: TextVariant.bold),
                      AnymeXText(
                          '$shown of ${_rows.length} shown · drag to reorder',
                          size: 12,
                          color: colors.onSurfaceVariant),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _service.resetRowLayout();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Reset'),
                ),
                FilledButton(
                  onPressed: () {
                    _save();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: _rows.length,
              onReorder: (from, to) {
                setState(() {
                  if (to > from) to--;
                  _rows.insert(to, _rows.removeAt(from));
                });
              },
              itemBuilder: (context, i) {
                final r = _rows[i];
                final visible = !_hidden.contains(r.key);
                return ListTile(
                  key: ValueKey(r.key),
                  contentPadding: const EdgeInsets.only(left: 8, right: 4),
                  leading: Checkbox(
                    value: visible,
                    onChanged: (v) => setState(() {
                      v == true ? _hidden.remove(r.key) : _hidden.add(r.key);
                    }),
                  ),
                  title: AnymeXText(r.title,
                      size: 14,
                      variant: TextVariant.semiBold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      color: visible ? null : colors.onSurfaceVariant),
                  subtitle: AnymeXText(r.addonName,
                      size: 12, color: colors.onSurfaceVariant),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(Icons.drag_handle_rounded,
                          color: colors.onSurfaceVariant),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Rows editor entries for these addon rows, in your order, hidden included.
List<StremioRowEntry> stremioRowEntries(
    List<(StremioAddon, StremioCatalog, String)> rows) {
  final service = StremioService.to;
  return service
      .arrangeRows(rows, (r) => StremioService.rowKey(r.$1, r.$2),
          includeHidden: true)
      .map((r) => StremioRowEntry(
          StremioService.rowKey(r.$1, r.$2), r.$3, r.$1.name))
      .toList();
}
