// AnymeX+: Movies & TV downloads, through AnymeX's own downloader (they show
// up in Downloads and play offline like downloaded anime).

import 'package:anymex/plus/stremio/stremio_models.dart';
import 'package:anymex/plus/stremio/ui/stremio_player_bridge.dart';
import 'package:anymex/plus/stremio/ui/stremio_widgets.dart'
    show stremioEpisodeLabel;
import 'package:anymex/screens/downloads/controller/download_controller.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:get/get.dart';

/// Direct links only: a torrent would need TorrServer running for the whole
/// download.
bool canDownloadStremioStream(StremioStream s) {
  final url = s.url;
  return !s.isTorrent && url != null && url.startsWith('http');
}

final Source _stremioSource = Source(name: 'Stremio', itemType: ItemType.anime);

/// Queues [stream] for download. False when it couldn't be started.
Future<bool> downloadStremioStream({
  required StremioMeta meta,
  StremioVideo? video,
  required StremioStream stream,
}) async {
  if (!canDownloadStremioStream(stream)) {
    snackBar('Only direct links can be downloaded, not torrents');
    return false;
  }
  if (!Get.isRegistered<DownloadController>()) {
    snackBar('Downloads are still starting. Try again in a moment.');
    return false;
  }
  final controller = Get.find<DownloadController>();
  final season = video == null ? null : (video.season ?? 1);
  final media =
      StremioPlayerBridge.mediaFor(meta, season: season).toOfflineMedia();
  final episode = StremioPlayerBridge.episodeFor(meta, video);
  final v = StremioPlayerBridge.videoFromStream(stream);
  await controller.enqueueDownloadBatch(
    episodes: [episode],
    source: _stremioSource,
    media: media,
    preferredQuality: stream.quality.isNotEmpty ? stream.quality : 'Default',
    firstEpisodeVideoUrl: v.url,
    firstEpisodeHeaders: stream.requestHeaders.isEmpty
        ? null
        : Map<String, String>.from(stream.requestHeaders),
    firstEpisodeSubtitles: v.subtitles,
    isFromMetadataPage: true,
  );
  final which = video == null ? '' : ' ${stremioEpisodeLabel(video.id) ?? ''}';
  snackBar('Downloading ${meta.name}$which'.trim(), title: 'Download Started');
  return true;
}
