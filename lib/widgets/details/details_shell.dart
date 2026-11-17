// Shared shell for every Details page (AniList/MAL/extension titles and
// Stremio Movies/Series): the blurred poster backdrop, the poster-colour
// theme, the transparent Windows title bar, the scroll view and the bottom
// Info / Episodes / Comments bar. A page only supplies its header, its
// slivers and its tab items — where the info comes from is its own business.

import 'dart:io';
import 'dart:ui';

import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/database/data_keys/keys.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/utils/color_extractor.dart';
import 'package:anymex/utils/theme_extensions.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_image.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_text.dart';
import 'package:anymex/widgets/anymex_widgets/anymex_titlebar.dart';
import 'package:anymex/widgets/common/anymex_scaffold.dart';
import 'package:anymex/widgets/common/baked_blur_image.dart';
import 'package:anymex/widgets/common/navbar.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class DetailsShell extends StatefulWidget {
  /// The title being shown; the backdrop and colours come from its art.
  final Media media;

  /// The page's header (usually a [MediaHeader]).
  final Widget header;

  /// Everything under the header: quick actions, then the tab's content.
  final List<Widget> slivers;

  /// Usually a [DetailsBottomBar].
  final Widget bottomBar;

  const DetailsShell({
    super.key,
    required this.media,
    required this.header,
    required this.slivers,
    required this.bottomBar,
  });

  @override
  State<DetailsShell> createState() => _DetailsShellState();
}

class _DetailsShellState extends State<DetailsShell> {
  late final RxString _posterColor;
  bool _isRouteAnimating = true;
  String? _lastExtractedUrl;

  static final Map<String, ColorScheme> _posterSchemeCache = {};
  static ColorScheme? _getPosterScheme(Color? seed, Brightness brightness) {
    if (seed == null) return null;
    final key = '${seed.value}_${brightness.name}';
    return _posterSchemeCache.putIfAbsent(
      key,
      () => ColorScheme.fromSeed(brightness: brightness, seedColor: seed),
    );
  }

  @override
  void initState() {
    super.initState();
    final usePoster = settingsController.usePosterForBlur;
    _posterColor = (usePoster && widget.media.color.isNotEmpty
            ? widget.media.color
            : '')
        .obs;
    _resolveDynamicColor(widget.media, allowExtract: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows && mounted) {
        AnymeXTitleBar.isTransparent.value = true;
      }
      final route = ModalRoute.of(context);
      if (route != null && route.animation != null) {
        if (route.animation!.isCompleted) {
          _isRouteAnimating = false;
          _resolveDynamicColor(widget.media, allowExtract: true);
          if (mounted) setState(() {});
        } else {
          route.animation!.addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              setState(() => _isRouteAnimating = false);
              _resolveDynamicColor(widget.media, allowExtract: true);
            }
          });
        }
      } else {
        _isRouteAnimating = false;
        _resolveDynamicColor(widget.media, allowExtract: true);
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant DetailsShell old) {
    super.didUpdateWidget(old);
    if (!_isRouteAnimating &&
        (old.media.poster != widget.media.poster ||
            old.media.cover != widget.media.cover ||
            old.media.color != widget.media.color)) {
      // Not inside the build phase: it changes an Rx the tree listens to.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveDynamicColor(widget.media, allowExtract: true);
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AnymeXTitleBar.isTransparent.value = false;
      });
    }
    super.dispose();
  }

  void _resolveDynamicColor(Media media, {bool allowExtract = false}) {
    final usePoster = settingsController.usePosterForBlur;
    final effectiveCover =
        (media.cover?.isNotEmpty == true ? media.cover! : media.poster);
    final targetUrl = usePoster ? media.poster : effectiveCover;

    if (_posterColor.value.isEmpty && media.color.isNotEmpty) {
      _posterColor.value = media.color;
    }

    if (targetUrl.isEmpty) {
      if (!usePoster && _posterColor.value.isNotEmpty) {
        _posterColor.value = '';
      }
      return;
    }

    final cached = ImageColorExtractor.getCachedColor(targetUrl);
    if (cached != null) {
      final hex = '#${cached.value.toRadixString(16).padLeft(8, '0')}';
      if (_posterColor.value != hex) {
        _posterColor.value = hex;
      }
      _lastExtractedUrl = targetUrl;
      return;
    }

    if (!allowExtract || _isRouteAnimating || _lastExtractedUrl == targetUrl) {
      return;
    }

    _lastExtractedUrl = targetUrl;
    ImageColorExtractor.extractColor(targetUrl).then((c) {
      if (c != null && mounted) {
        _posterColor.value = '#${c.value.toRadixString(16).padLeft(8, '0')}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final activeColor = _posterColor.value.isNotEmpty
          ? _posterColor.value
          : widget.media.color;
      final posterSeed = activeColor.isNotEmpty
          ? AnymeXScaffold.parseColor(activeColor)
          : null;
      final posterScheme = posterSeed != null
          ? _getPosterScheme(posterSeed, Theme.of(context).brightness)
          : null;

      Widget buildScaffold(BuildContext ctx) {
        return AnymeXScaffold(
          extendBehindTitleBar: true,
          color: _posterColor.value,
          extendBody: true,
          resizeToAvoidBottomInset: false,
          bottomNavigationBar: widget.bottomBar,
          body: Obx(() {
            final blurScope = settingsController.detailsBlurScope;
            final isMesh = settingsController.detailsBlurStyle == 1;
            final isBaked = isMesh || settingsController.useComputedBlur;
            final blurAmount =
                UISettingsKeys.detailsBlurAmount.get<double>(20.0);
            final brightness =
                UISettingsKeys.detailsBackdropBrightness.get<double>(1.0);
            final media = widget.media;
            final posterUrl = media.poster;
            final effectiveCover =
                (media.cover?.isNotEmpty == true ? media.cover! : posterUrl);
            final usePoster = settingsController.usePosterForBlur;
            final blurSourceUrl = usePoster ? posterUrl : effectiveCover;
            final blurFallbackUrl = usePoster ? effectiveCover : posterUrl;
            final tintBlur = settingsController.tintBlur;
            final colors = ctx.colors;
            final blurColor = tintBlur ? colors.primary.opaque(0.4) : null;
            final isDark =
                Theme.of(ctx).brightness == Brightness.dark;
            final baseArtworkColor = tintBlur
                ? colors.primary
                : (AnymeXScaffold.parseColor(_posterColor.value) ??
                    colors.primary);
            final gradientBgColor = Color.alphaBlend(
              baseArtworkColor.withValues(alpha: isDark ? 0.20 : 0.12),
              colors.surface,
            );


            final scrollView = ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
              child: Align(
                alignment: Alignment.topCenter,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(child: widget.header),
                    ...widget.slivers,
                  ],
                ),
              ),
            );

            Widget buildBlurredImage({double? height}) {
              if (blurSourceUrl.isEmpty || _isRouteAnimating) {
                return Container(
                  height: height ?? double.infinity,
                  width: double.infinity,
                  color: gradientBgColor,
                );
              }
              return isBaked
                  ? BakedBlurImage(
                      url: blurSourceUrl,
                      fallback: blurFallbackUrl,
                      saturation: 1.0,
                      blurAmount: blurAmount,
                      brightness: brightness,
                      color: blurColor,
                      fit: BoxFit.cover,
                      height: height,
                      width: double.infinity,
                      fadeBottom: true,
                      isMesh: isMesh,
                    )
                  : ColorFiltered(
                      colorFilter: ColorFilter.matrix([
                        brightness, 0, 0, 0, 0,
                        0, brightness, 0, 0, 0,
                        0, 0, brightness, 0, 0,
                        0, 0, 0, 1, 0,
                      ]),
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(
                            sigmaX: blurAmount, sigmaY: blurAmount),
                        child: AnymeXImage(
                          imageUrl: blurSourceUrl,
                          errorImage: blurFallbackUrl,
                          radius: 0,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: height ?? double.infinity,
                          color: blurColor,
                        ),
                      ),
                    );
            }

            if (blurScope == 0) {
              return scrollView;
            }

            if (blurScope == 2) {
              final washHeight = (MediaQuery.sizeOf(ctx).height * 0.48)
                  .clamp(320.0, 520.0);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: Container(
                      color: gradientBgColor,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: washHeight,
                    child: RepaintBoundary(
                      child: buildBlurredImage(height: washHeight),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: washHeight + 1.0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.30, 0.60, 0.85, 1.0],
                          colors: [
                            gradientBgColor.withValues(
                                alpha: isDark ? 0.30 : 0.10),
                            gradientBgColor.withValues(
                                alpha: isDark ? 0.55 : 0.25),
                            gradientBgColor.withValues(
                                alpha: isDark ? 0.85 : 0.65),
                            gradientBgColor,
                            gradientBgColor,
                          ],
                        ),
                      ),
                    ),
                  ),
                  scrollView,
                ],
              );
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: buildBlurredImage(),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colors.surface.withValues(alpha: 0.40),
                          colors.surface.withValues(alpha: 0.65),
                          colors.surface.withValues(alpha: 0.90),
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
                scrollView,
              ],
            );
          }),
        );
      }

      if (posterScheme != null) {
        return Theme(
          data: Theme.of(context).copyWith(colorScheme: posterScheme),
          child: Builder(builder: (ctx) => buildScaffold(ctx)),
        );
      }
      return buildScaffold(context);
    });
  }
}

/// The bottom tab bar, with an optional widget (the Continue button) above it.
class DetailsBottomBar extends StatelessWidget {
  final List<NavItem> items;
  final int currentIndex;
  final Widget? above;

  const DetailsBottomBar({
    super.key,
    required this.items,
    required this.currentIndex,
    this.above,
  });

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        getResponsiveValue(context, mobileValue: false, desktopValue: true);
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: above ?? const SizedBox.shrink(),
        ),
        SafeArea(
          child: ResponsiveNavBar(
            isDesktop: false,
            currentIndex: currentIndex,
            margin: EdgeInsets.fromLTRB(
                32, 0, 32, settingsController.bottomNavBarMargin),
            items: items,
          ),
        ),
      ],
    );
    if (isDesktop == true) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: child,
        ),
      );
    }
    return child;
  }
}

/// The pill buttons under the header: filled when active, outlined otherwise.
class DetailsPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  const DetailsPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const pill = BorderRadius.all(Radius.circular(999));
    final textClr = active ? colors.onPrimary : colors.onSurface;
    return Material(
      color: active ? colors.primary : colors.surface.withOpacity(0.3),
      borderRadius: pill,
      child: InkWell(
        borderRadius: pill,
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: pill,
            border: active
                ? null
                : Border.all(
                    color: colors.onSurface.withOpacity(0.45), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: textClr),
              const SizedBox(width: 7),
              Flexible(
                child: AnymeXText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textClr,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
