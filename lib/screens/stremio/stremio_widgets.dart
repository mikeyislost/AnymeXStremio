import 'package:anymex/controllers/services/stremio/stremio_models.dart';
import 'package:anymex/screens/stremio/stremio_details_page.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

void openStremioDetails(BuildContext context, String type, String id,
    {StremioMetaPreview? preview}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => StremioDetailsPage(type: type, id: id, preview: preview),
  ));
}

class StremioPosterCard extends StatelessWidget {
  final String title;
  final String? poster;
  final String? subtitle;
  final double? progress;
  final VoidCallback onTap;
  final double width;

  const StremioPosterCard({
    super.key,
    required this.title,
    required this.poster,
    required this.onTap,
    this.subtitle,
    this.progress,
    this.width = 112,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: theme.colorScheme.surfaceContainerHighest),
                    if (poster != null && poster!.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: poster!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _fallback(theme),
                      )
                    else
                      _fallback(theme),
                    if (progress != null && progress! > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: progress!.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: Colors.black45,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium,
          ),
        ),
      );
}

class StremioRow extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final VoidCallback? onMore;

  const StremioRow({
    super.key,
    required this.title,
    required this.children,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (onMore != null)
                TextButton(onPressed: onMore, child: const Text('See all')),
            ],
          ),
        ),
        SizedBox(
          height: 215,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => children[i],
          ),
        ),
      ],
    );
  }
}

String typeLabel(String type) {
  switch (type) {
    case 'movie':
      return 'Movies';
    case 'series':
      return 'Series';
    case 'channel':
      return 'Channels';
    case 'tv':
      return 'TV';
    case 'anime':
      return 'Anime';
    default:
      return type.isEmpty ? '' : '${type[0].toUpperCase()}${type.substring(1)}';
  }
}
