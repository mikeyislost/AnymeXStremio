// Data models for the Stremio addon protocol and Stremio account API.
//
// Formats mirror stremio-core (github.com/Stremio/stremio-core):
//   - addon manifest / descriptor: src/types/addon
//   - meta / stream / video:       src/types/resource
//   - library item:                src/types/library/library_item.rs

String? _str(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

List<String> _strList(dynamic v) {
  if (v is List) {
    return v.where((e) => e != null).map((e) => e.toString()).toList();
  }
  return const [];
}

Map<String, dynamic> _map(dynamic v) {
  if (v is Map) return Map<String, dynamic>.from(v);
  return <String, dynamic>{};
}

class StremioExtraProp {
  final String name;
  final bool isRequired;
  final List<String> options;

  const StremioExtraProp({
    required this.name,
    this.isRequired = false,
    this.options = const [],
  });
}

class StremioCatalog {
  final String type;
  final String id;
  final String name;
  final List<StremioExtraProp> extra;

  const StremioCatalog({
    required this.type,
    required this.id,
    required this.name,
    this.extra = const [],
  });

  factory StremioCatalog.fromJson(Map<String, dynamic> json) {
    final extra = <StremioExtraProp>[];
    if (json['extra'] is List) {
      for (final e in json['extra'] as List) {
        if (e is Map && e['name'] != null) {
          extra.add(StremioExtraProp(
            name: e['name'].toString(),
            isRequired: e['isRequired'] == true,
            options: _strList(e['options']),
          ));
        }
      }
    } else {
      // Legacy manifest format: extraSupported / extraRequired string arrays.
      final required = _strList(json['extraRequired']);
      for (final name in _strList(json['extraSupported'])) {
        extra.add(StremioExtraProp(
          name: name,
          isRequired: required.contains(name),
        ));
      }
    }
    return StremioCatalog(
      type: json['type']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      name: _str(json['name']) ?? _str(json['id']) ?? '',
      extra: extra,
    );
  }

  bool get supportsSearch => extra.any((e) => e.name == 'search');

  /// A catalog can be shown on the "board" when no extra is mandatory.
  bool get isBoardCatalog => !extra.any((e) => e.isRequired);

  /// Search-only catalogs (search is required).
  bool get isSearchOnly =>
      extra.any((e) => e.name == 'search' && e.isRequired);
}

class StremioAddon {
  final String transportUrl;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> flags;

  StremioAddon({
    required this.transportUrl,
    required this.manifest,
    Map<String, dynamic>? flags,
  }) : flags = flags ?? <String, dynamic>{};

  factory StremioAddon.fromDescriptor(Map<String, dynamic> json) {
    return StremioAddon(
      transportUrl: json['transportUrl']?.toString() ?? '',
      manifest: _map(json['manifest']),
      flags: _map(json['flags']),
    );
  }

  Map<String, dynamic> toDescriptor() => {
        'manifest': manifest,
        'transportUrl': transportUrl,
        'flags': flags,
      };

  String get id => manifest['id']?.toString() ?? transportUrl;
  String get name => _str(manifest['name']) ?? id;
  String get version => manifest['version']?.toString() ?? '';
  String? get logo => _str(manifest['logo']);
  String? get description => _str(manifest['description']);
  List<String> get types => _strList(manifest['types']);
  List<String>? get idPrefixes => manifest['idPrefixes'] is List
      ? _strList(manifest['idPrefixes'])
      : null;
  bool get isOfficial => flags['official'] == true;
  bool get isProtected => flags['protected'] == true;

  /// Base URL used to build resource requests (transport URL without
  /// the trailing `/manifest.json`).
  String get baseUrl {
    var url = transportUrl;
    final q = url.indexOf('?');
    if (q != -1) url = url.substring(0, q);
    if (url.endsWith('/manifest.json')) {
      url = url.substring(0, url.length - '/manifest.json'.length);
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  List<StremioCatalog> get catalogs {
    final raw = manifest['catalogs'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => StremioCatalog.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Whether this addon can serve [resource] (catalog/meta/stream/subtitles)
  /// for the given content [type] and [id].
  bool supports(String resource, String type, String id) {
    final resources = manifest['resources'];
    if (resources is! List) return false;
    for (final r in resources) {
      List<String> rTypes;
      List<String>? rPrefixes;
      if (r is String) {
        if (r != resource) continue;
        rTypes = types;
        rPrefixes = idPrefixes;
      } else if (r is Map) {
        if (r['name']?.toString() != resource) continue;
        rTypes = r['types'] is List ? _strList(r['types']) : types;
        rPrefixes =
            r['idPrefixes'] is List ? _strList(r['idPrefixes']) : idPrefixes;
      } else {
        continue;
      }
      if (rTypes.isNotEmpty && !rTypes.contains(type)) continue;
      if (rPrefixes != null &&
          rPrefixes.isNotEmpty &&
          !rPrefixes.any((p) => id.startsWith(p))) {
        continue;
      }
      return true;
    }
    return false;
  }

  bool hasResource(String resource) {
    final resources = manifest['resources'];
    if (resources is! List) return false;
    return resources.any((r) =>
        (r is String && r == resource) ||
        (r is Map && r['name']?.toString() == resource));
  }
}

class StremioMetaPreview {
  final String id;
  final String type;
  final String name;
  final String? poster;
  final String posterShape;
  final String? background;
  final String? logo;
  final String? description;
  final String? releaseInfo;
  final String? imdbRating;
  final List<String> genres;

  const StremioMetaPreview({
    required this.id,
    required this.type,
    required this.name,
    this.poster,
    this.posterShape = 'poster',
    this.background,
    this.logo,
    this.description,
    this.releaseInfo,
    this.imdbRating,
    this.genres = const [],
  });

  factory StremioMetaPreview.fromJson(Map<String, dynamic> json) {
    return StremioMetaPreview(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? 'movie',
      name: _str(json['name']) ?? '',
      poster: _str(json['poster']),
      posterShape: _str(json['posterShape']) ?? 'poster',
      background: _str(json['background']),
      logo: _str(json['logo']),
      description: _str(json['description']),
      releaseInfo: _str(json['releaseInfo']) ?? _str(json['year']),
      imdbRating: _str(json['imdbRating']),
      genres: json['genres'] is List
          ? _strList(json['genres'])
          : _strList(json['genre']),
    );
  }
}

class StremioVideo {
  final String id;
  final String title;
  final int? season;
  final int? episode;
  final DateTime? released;
  final String? thumbnail;
  final String? overview;

  const StremioVideo({
    required this.id,
    required this.title,
    this.season,
    this.episode,
    this.released,
    this.thumbnail,
    this.overview,
  });

  factory StremioVideo.fromJson(Map<String, dynamic> json) {
    DateTime? released;
    final r = json['released'];
    if (r != null) released = DateTime.tryParse(r.toString());
    return StremioVideo(
      id: json['id']?.toString() ?? '',
      title: _str(json['title']) ?? _str(json['name']) ?? '',
      season: _int(json['season']),
      episode: _int(json['episode']) ?? _int(json['number']),
      released: released,
      thumbnail: _str(json['thumbnail']),
      overview: _str(json['overview']) ?? _str(json['description']),
    );
  }

  bool get isReleased =>
      released == null || released!.isBefore(DateTime.now().toUtc());
}

class StremioMeta extends StremioMetaPreview {
  final List<StremioVideo> videos;
  final String? runtime;
  final String? defaultVideoId;
  final List<String> cast;

  const StremioMeta({
    required super.id,
    required super.type,
    required super.name,
    super.poster,
    super.posterShape,
    super.background,
    super.logo,
    super.description,
    super.releaseInfo,
    super.imdbRating,
    super.genres,
    this.videos = const [],
    this.runtime,
    this.defaultVideoId,
    this.cast = const [],
  });

  factory StremioMeta.fromJson(Map<String, dynamic> json) {
    final p = StremioMetaPreview.fromJson(json);
    final videos = <StremioVideo>[];
    if (json['videos'] is List) {
      for (final v in json['videos'] as List) {
        if (v is Map) {
          final video = StremioVideo.fromJson(Map<String, dynamic>.from(v));
          if (video.id.isNotEmpty) videos.add(video);
        }
      }
    }
    final hints = _map(json['behaviorHints']);
    return StremioMeta(
      id: p.id,
      type: p.type,
      name: p.name,
      poster: p.poster,
      posterShape: p.posterShape,
      background: p.background,
      logo: p.logo,
      description: p.description,
      releaseInfo: p.releaseInfo,
      imdbRating: p.imdbRating,
      genres: p.genres,
      videos: videos,
      runtime: _str(json['runtime']),
      defaultVideoId: _str(hints['defaultVideoId']),
      cast: _strList(json['cast']),
    );
  }

  /// Movies (and anything without a list of videos) play a single video
  /// whose id is the meta id itself (or behaviorHints.defaultVideoId).
  bool get isSingleVideo => videos.isEmpty || defaultVideoId != null;

  String get singleVideoId => defaultVideoId ?? id;

  /// Seasons in display order; specials (season 0) go last.
  List<int> get seasons {
    final s = videos.map((v) => v.season ?? 1).toSet().toList()..sort();
    if (s.length > 1 && s.first == 0) {
      s
        ..removeAt(0)
        ..add(0);
    }
    return s;
  }

  List<StremioVideo> videosForSeason(int season) {
    final list = videos.where((v) => (v.season ?? 1) == season).toList()
      ..sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
    return list;
  }
}

class StremioStream {
  final String addonName;
  final String? url;
  final String? infoHash;
  final int? fileIdx;
  final String? ytId;
  final String? externalUrl;
  final String? name;
  final String? title;
  final String? description;
  final List<String> sources;
  final String? bingeGroup;
  final String? filename;
  final Map<String, String> requestHeaders;
  final List<Map<String, String>> subtitles;

  const StremioStream({
    required this.addonName,
    this.url,
    this.infoHash,
    this.fileIdx,
    this.ytId,
    this.externalUrl,
    this.name,
    this.title,
    this.description,
    this.sources = const [],
    this.bingeGroup,
    this.filename,
    this.requestHeaders = const {},
    this.subtitles = const [],
  });

  factory StremioStream.fromJson(Map<String, dynamic> json, String addonName) {
    final hints = _map(json['behaviorHints']);
    final proxy = _map(hints['proxyHeaders']);
    final req = _map(proxy['request']);
    final headers = <String, String>{};
    req.forEach((k, v) {
      if (v != null) headers[k] = v.toString();
    });
    final subs = <Map<String, String>>[];
    if (json['subtitles'] is List) {
      for (final s in json['subtitles'] as List) {
        if (s is Map && s['url'] != null) {
          subs.add({
            'url': s['url'].toString(),
            'lang': s['lang']?.toString() ?? 'Unknown',
          });
        }
      }
    }
    return StremioStream(
      addonName: addonName,
      url: _str(json['url']),
      infoHash: _str(json['infoHash'])?.toLowerCase(),
      fileIdx: _int(json['fileIdx']),
      ytId: _str(json['ytId']),
      externalUrl: _str(json['externalUrl']),
      name: _str(json['name']),
      title: _str(json['title']),
      description: _str(json['description']),
      sources: _strList(json['sources']),
      bingeGroup: _str(hints['bingeGroup']),
      filename: _str(hints['filename']),
      requestHeaders: headers,
      subtitles: subs,
    );
  }

  bool get isTorrent => url == null && infoHash != null;

  /// Whether the AnymeX player can open this stream.
  bool get isPlayable => playableUrl != null;

  /// Direct URL, or a magnet link for torrent streams. The file index is
  /// passed to the player through the private `anymex_fidx` parameter,
  /// which the player strips before handing the magnet to TorrServer.
  String? get playableUrl {
    if (url != null) return url;
    if (infoHash != null) {
      final b = StringBuffer('magnet:?xt=urn:btih:$infoHash');
      final dn = filename ?? title?.split('\n').first;
      if (dn != null && dn.isNotEmpty) {
        b.write('&dn=${Uri.encodeQueryComponent(dn)}');
      }
      for (final s in sources) {
        if (s.startsWith('tracker:')) {
          b.write('&tr=${Uri.encodeQueryComponent(s.substring(8))}');
        }
      }
      if (fileIdx != null) b.write('&anymex_fidx=$fileIdx');
      return b.toString();
    }
    return null;
  }

  /// Short label for lists and the in-player source switcher.
  String get label {
    final first = (name ?? addonName).replaceAll('\n', ' ').trim();
    final second =
        (description ?? title ?? '').split('\n').first.trim();
    if (second.isEmpty) return first;
    return '$first · $second';
  }

  /// Full multi-line details (quality, size, seeds…) as addons send them.
  String get details => (description ?? title ?? '').trim();
}

/// A raw Stremio library item. The original JSON map is kept so that fields
/// this app doesn't know about are never dropped when writing back.
class StremioLibraryItem {
  final Map<String, dynamic> raw;

  StremioLibraryItem(this.raw) {
    raw['state'] = _map(raw['state']);
  }

  factory StremioLibraryItem.create({
    required String id,
    required String type,
    required String name,
    String? poster,
  }) {
    final now = stremioDate(DateTime.now());
    return StremioLibraryItem({
      '_id': id,
      'name': name,
      'type': type,
      'poster': poster,
      'posterShape': 'poster',
      // Same defaults Stremio uses for items created by playback:
      // not explicitly added to the library, but kept for Continue Watching.
      'removed': true,
      'temp': true,
      '_ctime': now,
      '_mtime': now,
      'state': <String, dynamic>{
        'lastWatched': now,
        'timeWatched': 0,
        'timeOffset': 0,
        'overallTimeWatched': 0,
        'timesWatched': 0,
        'flaggedWatched': 0,
        'duration': 0,
        'video_id': null,
        'watched': null,
        'noNotif': false,
      },
      'behaviorHints': <String, dynamic>{
        'defaultVideoId': null,
        'featuredVideoId': null,
        'hasScheduledVideos': false,
      },
    });
  }

  Map<String, dynamic> get state => raw['state'] as Map<String, dynamic>;

  String get id => raw['_id']?.toString() ?? '';
  String get type => raw['type']?.toString() ?? '';
  String get name => raw['name']?.toString() ?? '';
  String? get poster => _str(raw['poster']);
  bool get removed => raw['removed'] == true;
  bool get temp => raw['temp'] == true;

  DateTime? get mtime => DateTime.tryParse(raw['_mtime']?.toString() ?? '');
  DateTime? get lastWatched =>
      DateTime.tryParse(state['lastWatched']?.toString() ?? '');

  int get timeOffset => _int(state['timeOffset']) ?? 0;
  int get duration => _int(state['duration']) ?? 0;
  int get timeWatched => _int(state['timeWatched']) ?? 0;
  int get overallTimeWatched => _int(state['overallTimeWatched']) ?? 0;
  int get timesWatched => _int(state['timesWatched']) ?? 0;
  int get flaggedWatched => _int(state['flaggedWatched']) ?? 0;
  String? get videoId => _str(state['video_id']);
  String? get watchedField => _str(state['watched']);

  set timeOffset(int v) => state['timeOffset'] = v;
  set duration(int v) => state['duration'] = v;
  set timeWatched(int v) => state['timeWatched'] = v;
  set overallTimeWatched(int v) => state['overallTimeWatched'] = v;
  set timesWatched(int v) => state['timesWatched'] = v;
  set flaggedWatched(int v) => state['flaggedWatched'] = v;
  set videoId(String? v) => state['video_id'] = v;
  set watchedField(String? v) => state['watched'] = v;
  set lastWatched(DateTime? v) =>
      state['lastWatched'] = v == null ? null : stremioDate(v);

  void touch() => raw['_mtime'] = stremioDate(DateTime.now());

  bool get isInContinueWatching =>
      type != 'other' && (!removed || temp) && timeOffset > 0;

  /// In the user's Stremio library (explicitly added, not removed).
  bool get isInLibrary => type != 'other' && !removed && !temp;

  double get progress =>
      (timeOffset > 0 && duration > 0) ? timeOffset / duration : 0.0;

  Map<String, dynamic> toJson() => raw;
}

/// RFC 3339 UTC timestamp with millisecond precision, as Stremio uses.
String stremioDate(DateTime d) {
  final u = d.toUtc();
  final ms = DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second,
      u.millisecond);
  return ms.toIso8601String();
}
