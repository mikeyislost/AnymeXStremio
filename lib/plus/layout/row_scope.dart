// AnymeX+: a page row's settings from "Edit layout" (name, card style and
// size, row or grid, how many items, order), handed down to the carousel
// that draws it. AnymeX's ReusableCarousel reads this; without a scope it
// draws exactly as before.

import 'package:anymex/models/Anilist/anilist_media_user.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/models/models_convertor/carousel/carousel_data.dart';
import 'package:anymex/plus/layout/layout_model.dart';
import 'package:anymex/widgets/common/cards/card_gate.dart';
import 'package:flutter/material.dart';

class PlusRowScope extends InheritedWidget {
  final PlusRowStyle style;

  /// Your name for the row (null = its own title).
  final String? title;

  const PlusRowScope({
    super.key,
    required this.style,
    this.title,
    required super.child,
  });

  static PlusRowScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlusRowScope>();

  /// The row's title as you named it.
  static String titleOf(BuildContext context, String original) {
    final t = of(context)?.title;
    return (t == null || t.trim().isEmpty) ? original : t;
  }

  @override
  bool updateShouldNotify(PlusRowScope oldWidget) =>
      oldWidget.style.toJson().toString() != style.toJson().toString() ||
      oldWidget.title != title;

  /// The card style this row uses.
  int cardStyleOr(int appStyle) => style.cardStyle ?? appStyle;

  /// [cards] (made from [raw], same order) sorted and cut to the count.
  List<CarouselData> apply(List<dynamic> raw, List<CarouselData> cards) {
    var out = cards;
    if (style.sort != PlusRowSort.normal) {
      final sameLength = raw.length == cards.length;
      final idx = PlusLayout.sortedIndices(
        cards.length,
        style.sort,
        title: (i) => cards[i].title,
        score: (i) {
          final r = sameLength ? raw[i] : null;
          if (r is Media) return PlusLayout.scoreOf(r.rating);
          if (r is TrackedMedia) return PlusLayout.scoreOf(r.rating);
          return PlusLayout.scoreOf(cards[i].extraData);
        },
        year: (i) {
          final r = sameLength ? raw[i] : null;
          if (r is Media) return r.seasonYear;
          if (r is TrackedMedia) return r.startYear;
          return null;
        },
      );
      out = [for (final i in idx) cards[i]];
    }
    if (style.count > 0 && out.length > style.count) {
      out = out.sublist(0, style.count);
    }
    return out;
  }

  /// [card] drawn at the row's size (cards fill the height they're given;
  /// the width follows).
  Widget sizeCard(BuildContext context, Widget card, int styleIndex) {
    final grid = style.view == PlusRowView.grid;
    if (style.size == 1.0 && !grid) return card;
    final desktop = MediaQuery.sizeOf(context).width > 600;
    final h = getCardHeight(styleIndex, desktop);
    // In a grid nothing else gives the card its height.
    if (style.size == 1.0) return SizedBox(height: h, child: card);
    return SizedBox(
      height: h * style.size,
      child: FittedBox(
        alignment: Alignment.topLeft,
        child: SizedBox(height: h, child: card),
      ),
    );
  }

  /// The row's items as a grid (wrapping rows of cards).
  Widget grid(BuildContext context, int count,
      Widget Function(BuildContext, int) itemBuilder) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 5, 10, 10),
      child: Wrap(
        spacing: 0,
        runSpacing: 8,
        children: [for (var i = 0; i < count; i++) itemBuilder(context, i)],
      ),
    );
  }
}
