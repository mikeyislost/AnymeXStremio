import 'dart:io';

import 'package:flutter/widgets.dart';

/// On Windows the custom title bar (minimize / maximize / close) floats over
/// every page; pages that aren't built on AnymeXScaffold wrap themselves in
/// this so their content starts below it.
class TitleBarInset extends StatelessWidget {
  final Widget child;
  const TitleBarInset({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return child;
    return Padding(padding: const EdgeInsets.only(top: 40), child: child);
  }
}
