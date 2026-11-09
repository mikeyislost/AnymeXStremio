// AnymeX+: the page layouts behind "Edit layout" (Home, Movies & TV,
// Manga). Plain Dart, no Flutter, so it is unit-tested.

/// How a row shows its cards.
enum PlusRowView { row, grid }

/// Order of a row's items. [normal] keeps the source's order.
enum PlusRowSort { normal, title, score, year }

/// Card size relative to the card style's own size.
const plusRowSizes = <String, double>{
  'Small': 0.8,
  'Medium': 1.0,
  'Large': 1.2,
};

/// Item counts offered in the editor (0 = all).
const plusRowCounts = [0, 10, 20, 30, 50];

class PlusRowStyle {
  /// Card style index (MediaCardRegistry); null = the app's card style.
  final int? cardStyle;
  final double size;
  final PlusRowView view;

  /// Most items shown; 0 = all.
  final int count;
  final PlusRowSort sort;

  const PlusRowStyle({
    this.cardStyle,
    this.size = 1.0,
    this.view = PlusRowView.row,
    this.count = 0,
    this.sort = PlusRowSort.normal,
  });

  static const plain = PlusRowStyle();

  /// Same as the app would show without a layout.
  bool get isPlain =>
      cardStyle == null &&
      size == 1.0 &&
      view == PlusRowView.row &&
      count == 0 &&
      sort == PlusRowSort.normal;

  /// Only the card look/size/view differ (sorting and counts aside).
  bool get changesCards =>
      cardStyle != null || size != 1.0 || view != PlusRowView.row;

  PlusRowStyle copyWith({
    int? Function()? cardStyle,
    double? size,
    PlusRowView? view,
    int? count,
    PlusRowSort? sort,
  }) =>
      PlusRowStyle(
        cardStyle: cardStyle != null ? cardStyle() : this.cardStyle,
        size: size ?? this.size,
        view: view ?? this.view,
        count: count ?? this.count,
        sort: sort ?? this.sort,
      );

  Map<String, dynamic> toJson() => {
        if (cardStyle != null) 'card': cardStyle,
        if (size != 1.0) 'size': size,
        if (view != PlusRowView.row) 'view': view.name,
        if (count != 0) 'count': count,
        if (sort != PlusRowSort.normal) 'sort': sort.name,
      };

  factory PlusRowStyle.fromJson(dynamic j) {
    if (j is! Map) return plain;
    T byName<T extends Enum>(List<T> values, dynamic v, T fallback) {
      for (final e in values) {
        if (e.name == v) return e;
      }
      return fallback;
    }

    final size = (j['size'] as num?)?.toDouble() ?? 1.0;
    return PlusRowStyle(
      cardStyle: (j['card'] as num?)?.toInt(),
      size: size.clamp(0.5, 1.6).toDouble(),
      view: byName(PlusRowView.values, j['view'], PlusRowView.row),
      count: ((j['count'] as num?)?.toInt() ?? 0).clamp(0, 500).toInt(),
      sort: byName(PlusRowSort.values, j['sort'], PlusRowSort.normal),
    );
  }

  /// Short description for the editor, e.g. "Grid · Large · 20 items".
  String summary(List<String> cardStyleNames) {
    final parts = <String>[];
    if (cardStyle != null &&
        cardStyle! >= 0 &&
        cardStyle! < cardStyleNames.length) {
      parts.add(cardStyleNames[cardStyle!]);
    }
    if (view == PlusRowView.grid) parts.add('Grid');
    for (final e in plusRowSizes.entries) {
      if (e.value == size && size != 1.0) parts.add(e.key);
    }
    if (count > 0) parts.add('$count items');
    if (sort != PlusRowSort.normal) parts.add('By ${sortLabel(sort)}');
    return parts.join(' · ');
  }

  static String sortLabel(PlusRowSort s) => switch (s) {
        PlusRowSort.normal => 'default order',
        PlusRowSort.title => 'title',
        PlusRowSort.score => 'score',
        PlusRowSort.year => 'year (newest)',
      };
}

/// One row as you set it up.
class PlusRowConfig {
  final String key;

  /// Your name for it; null = the row's own title.
  final String? name;
  final bool hidden;
  final PlusRowStyle style;

  /// A row you added (filtered row, a catalog from elsewhere): kept even
  /// when it isn't in the page's list of rows.
  final bool added;

  /// What an added row shows (filters, catalog key…).
  final Map<String, dynamic> params;

  const PlusRowConfig({
    required this.key,
    this.name,
    this.hidden = false,
    this.style = PlusRowStyle.plain,
    this.added = false,
    this.params = const {},
  });

  PlusRowConfig copyWith({
    String? Function()? name,
    bool? hidden,
    PlusRowStyle? style,
    Map<String, dynamic>? params,
  }) =>
      PlusRowConfig(
        key: key,
        name: name != null ? name() : this.name,
        hidden: hidden ?? this.hidden,
        style: style ?? this.style,
        added: added,
        params: params ?? this.params,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        if (name != null) 'name': name,
        if (hidden) 'hidden': true,
        if (!style.isPlain) 'style': style.toJson(),
        if (added) 'added': true,
        if (params.isNotEmpty) 'params': params,
      };

  static PlusRowConfig? fromJson(dynamic j) {
    if (j is! Map || j['key'] is! String) return null;
    final name = j['name'];
    return PlusRowConfig(
      key: j['key'] as String,
      name: name is String && name.trim().isNotEmpty ? name : null,
      hidden: j['hidden'] == true,
      style: PlusRowStyle.fromJson(j['style']),
      added: j['added'] == true,
      params: j['params'] is Map
          ? Map<String, dynamic>.from(j['params'] as Map)
          : const {},
    );
  }

  static List<PlusRowConfig> listFromJson(dynamic j) => j is List
      ? j.map(fromJson).whereType<PlusRowConfig>().toList()
      : <PlusRowConfig>[];
}

/// A row a page can show, in the page's default order.
class PlusRowSpec {
  final String key;
  final String title;

  /// Shown before you change anything?
  final bool shownByDefault;

  /// Card rows can be renamed and styled; others (buttons, banners) only
  /// moved and hidden.
  final bool styled;

  const PlusRowSpec(this.key, this.title,
      {this.shownByDefault = true, this.styled = true});
}

/// A row ready to show: its spec (null for an added row) and your config.
class PlusPlacedRow {
  final PlusRowSpec? spec;
  final PlusRowConfig config;
  const PlusPlacedRow(this.spec, this.config);

  String get key => config.key;
  String get title => config.name ?? spec?.title ?? config.params['title']?.toString() ?? key;
  bool get styled => spec?.styled ?? true;
}

class PlusLayout {
  PlusLayout._();

  /// Your saved rows in your order, with rows you haven't placed yet (new
  /// lists, new addons…) put where they'd be by default: right after the
  /// row that comes before them in [specs]. Saved rows the page can't show
  /// right now are left out (unless you added them); they come back when
  /// they're there again.
  static List<PlusPlacedRow> arrange(
      List<PlusRowSpec> specs, List<PlusRowConfig> saved) {
    final specByKey = {for (final s in specs) s.key: s};
    final out = <PlusPlacedRow>[];
    final placed = <String>{};
    for (final c in saved) {
      if (placed.contains(c.key)) continue;
      final spec = specByKey[c.key];
      if (spec == null && !c.added) continue;
      out.add(PlusPlacedRow(spec, c));
      placed.add(c.key);
    }
    String? previous;
    for (final s in specs) {
      if (!placed.contains(s.key)) {
        final row = PlusPlacedRow(
            s, PlusRowConfig(key: s.key, hidden: !s.shownByDefault));
        final at = previous == null
            ? 0
            : out.indexWhere((r) => r.key == previous) + 1;
        out.insert(at.clamp(0, out.length).toInt(), row);
        placed.add(s.key);
      }
      previous = s.key;
    }
    return out;
  }

  /// What to save after editing [rows]: them, plus saved rows that weren't
  /// shown because the page can't show them right now (kept for later).
  static List<PlusRowConfig> toSave(
      List<PlusPlacedRow> rows, List<PlusRowConfig> saved) {
    final keys = rows.map((r) => r.key).toSet();
    return [
      ...rows.map((r) => r.config),
      ...saved.where((c) => !keys.contains(c.key) && !c.added),
    ];
  }

  /// Indices of [n] items in the order [sort] asks for. [title], [score]
  /// and [year] read item i (null = unknown, sorted last). Stable.
  static List<int> sortedIndices(
    int n,
    PlusRowSort sort, {
    String? Function(int i)? title,
    double? Function(int i)? score,
    int? Function(int i)? year,
  }) {
    final idx = List<int>.generate(n, (i) => i);
    int byNum(num? a, num? b, int ia, int ib) {
      if (a == null && b == null) return ia.compareTo(ib);
      if (a == null) return 1;
      if (b == null) return -1;
      final c = b.compareTo(a); // high first
      return c != 0 ? c : ia.compareTo(ib);
    }

    switch (sort) {
      case PlusRowSort.normal:
        return idx;
      case PlusRowSort.title:
        if (title == null) return idx;
        final t = [for (var i = 0; i < n; i++) (title(i) ?? '').toLowerCase()];
        idx.sort((a, b) {
          final c = t[a].compareTo(t[b]);
          return c != 0 ? c : a.compareTo(b);
        });
        return idx;
      case PlusRowSort.score:
        if (score == null) return idx;
        final s = [for (var i = 0; i < n; i++) score(i)];
        idx.sort((a, b) => byNum(s[a], s[b], a, b));
        return idx;
      case PlusRowSort.year:
        if (year == null) return idx;
        final y = [for (var i = 0; i < n; i++) year(i)];
        idx.sort((a, b) => byNum(y[a], y[b], a, b));
        return idx;
    }
  }

  /// A score from a card's rating text ("8.4", "84", "?") on a 0–10 scale.
  static double? scoreOf(String? text) {
    final v = double.tryParse((text ?? '').replaceAll(',', '.').trim());
    if (v == null || v <= 0) return null;
    return v > 10 ? v / 10 : v;
  }
}
