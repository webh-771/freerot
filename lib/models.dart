// Shared data contracts (v2, multi-source). Every layer (sources, catalog,
// library, UI, player) codes against these types — do not change field names
// without updating all users.

/// A drama as shown in a grid/list card.
class Drama {
  /// Source key, e.g. "shortmax", "dramawave", "idrama", "rf:netshort".
  /// Decides which [DramaSource] serves detail + playback.
  final String source;

  /// Id within [source] (site id, provider id, hash...). Not globally unique.
  final String id;
  final String title;
  final String cover;
  final int? episodes;
  final String? synopsis;

  /// Real view/play count when the source publishes one (ShortMax), else null.
  final int? views;

  const Drama({
    required this.source,
    required this.id,
    required this.title,
    required this.cover,
    this.episodes,
    this.synopsis,
    this.views,
  });

  /// Globally unique identity — use for dedupe, library, widget keys.
  String get key => '$source:$id';

  Map<String, dynamic> toJson() => {
        'source': source,
        'id': id,
        'title': title,
        'cover': cover,
        'episodes': episodes,
        'synopsis': synopsis,
        'views': views,
      };

  factory Drama.fromJson(Map<String, dynamic> j) => Drama(
        // v1 entries predate multi-source; they were all ShortMax.
        source: j['source'] as String? ?? 'shortmax',
        id: j['id'] as String,
        title: j['title'] as String,
        cover: j['cover'] as String? ?? '',
        episodes: j['episodes'] as int?,
        synopsis: j['synopsis'] as String?,
        views: j['views'] as int?,
      );
}

/// A Home filter chip ("For you", "Most viewed", "Werewolf", ...).
class Shelf {
  final String id; // 'for_you', 'most_viewed', 'trending', 'new', 'g:werewolf'
  final String label;
  const Shelf(this.id, this.label);
}

/// Full drama page with its episode list.
class DramaDetail {
  final String source;
  final String id;
  final String title;
  final String cover;
  final String synopsis;
  final int totalEpisodes;

  /// Playable episode numbers (usually 1..totalEpisodes).
  final List<int> episodes;

  /// Episodes known to be unavailable (placeholders / 502). Shown greyed out,
  /// skipped by autoplay.
  final Set<int> locked;

  const DramaDetail({
    required this.source,
    required this.id,
    required this.title,
    required this.cover,
    required this.synopsis,
    required this.totalEpisodes,
    required this.episodes,
    this.locked = const {},
  });

  String get key => '$source:$id';

  Drama toDrama() => Drama(
        source: source,
        id: id,
        title: title,
        cover: cover,
        episodes: totalEpisodes,
        synopsis: synopsis,
      );
}

class VideoQuality {
  /// "1080p", "720p", "480p", "Auto".
  final String label;
  final String url;

  /// HLS (m3u8) vs progressive (mp4). The player must pass the right format
  /// hint — proxy URLs often have no telling extension.
  final bool isHls;

  const VideoQuality(this.label, this.url, {this.isHls = true});
}

class Subtitle {
  final String label; // "English"
  final String lang; // "en"
  final String url; // WebVTT
  const Subtitle(this.label, this.lang, this.url);
}

/// Resolved playback info for one episode on one server.
class EpisodeStream {
  final String dramaId;
  final int ep;

  /// Server option this came from (one of Catalog.servers(detail)).
  final String server;

  /// Default URL to play.
  final String playUrl;

  /// Alternate URL for the same stream (proxy); '' if none.
  final String proxyUrl;

  /// Format of [playUrl] / [proxyUrl].
  final bool isHls;

  /// Selectable qualities, best first. May be empty.
  final List<VideoQuality> qualities;

  final List<Subtitle> subtitles;

  /// Extra HTTP headers the media requests need (usually empty).
  final Map<String, String> headers;

  const EpisodeStream({
    required this.dramaId,
    required this.ep,
    required this.server,
    required this.playUrl,
    required this.proxyUrl,
    required this.qualities,
    this.isHls = true,
    this.subtitles = const [],
    this.headers = const {},
  });
}

class Paged<T> {
  final List<T> items;
  final bool hasMore;
  const Paged(this.items, this.hasMore);
}

/// A resume point for "Continue watching".
class WatchProgress {
  final Drama drama;
  final int ep;
  final int positionMs;
  final int durationMs;
  final int updatedAt; // epoch ms

  const WatchProgress({
    required this.drama,
    required this.ep,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  double get fraction =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'drama': drama.toJson(),
        'ep': ep,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt,
      };

  factory WatchProgress.fromJson(Map<String, dynamic> j) => WatchProgress(
        drama: Drama.fromJson((j['drama'] as Map).cast<String, dynamic>()),
        ep: j['ep'] as int,
        positionMs: j['positionMs'] as int,
        durationMs: j['durationMs'] as int,
        updatedAt: j['updatedAt'] as int,
      );
}
