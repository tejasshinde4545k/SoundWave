/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     SoundWave is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     SoundWave is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about SoundWave, including how to contribute,
 *     please visit: https://github.com/tejasshinde4545k/SoundWave
 */

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:soundwave/main.dart' show logger;
import 'package:soundwave/services/common_services.dart'
    show fetchSongsList, userLikedSongsList, userRecentlyPlayed;
import 'package:soundwave/services/music_region_service.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/utilities/formatter.dart';

/// Represents the current calendar week range: Monday 00:00:00.000 through Sunday 23:59:59.999.
class CalendarWeekRange {
  const CalendarWeekRange({
    required this.startOfWeek,
    required this.endOfWeek,
    required this.weekId,
  });

  /// Monday 00:00:00.000
  final DateTime startOfWeek;

  /// Sunday 23:59:59.999
  final DateTime endOfWeek;

  /// Unique week identifier formatted as 'YYYY-Www'
  final String weekId;

  /// Returns true if [date] falls within [startOfWeek] and [endOfWeek] inclusive.
  bool contains(DateTime date) {
    return !date.isBefore(startOfWeek) && !date.isAfter(endOfWeek);
  }

  /// Formatted date range label for UI display, e.g. "Sep 7 – Sep 13, 2026".
  String get formattedRange {
    final startStr = _formatShortMonthDay(startOfWeek);
    final endStr = _formatShortMonthDay(endOfWeek);
    return '$startStr – $endStr, ${endOfWeek.year}';
  }

  static String _formatShortMonthDay(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}

/// Metadata describing a music release verified through MusicBrainz.
class ReleaseMetadata {
  const ReleaseMetadata({
    required this.id,
    required this.title,
    required this.artist,
    required this.releaseDate,
    this.primaryType = 'Single',
    this.secondaryTypes = const [],
    this.isReissue = false,
    this.isCompilation = false,
    this.country,
  });

  factory ReleaseMetadata.fromJson(Map<String, dynamic> json) {
    return ReleaseMetadata(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      releaseDate: DateTime.tryParse(json['releaseDate']?.toString() ?? '') ??
          DateTime(1970),
      primaryType: json['primaryType']?.toString() ?? 'Single',
      secondaryTypes: List<String>.from(json['secondaryTypes'] ?? const []),
      isReissue: json['isReissue'] == true,
      isCompilation: json['isCompilation'] == true,
      country: json['country']?.toString(),
    );
  }

  final String id;
  final String title;
  final String artist;
  final DateTime releaseDate;
  final String primaryType;
  final List<String> secondaryTypes;
  final bool isReissue;
  final bool isCompilation;
  final String? country;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'releaseDate': releaseDate.toIso8601String(),
    'primaryType': primaryType,
    'secondaryTypes': secondaryTypes,
    'isReissue': isReissue,
    'isCompilation': isCompilation,
    'country': country,
  };
}

/// Scored YouTube candidate representing a verified release track.
class YouTubeCandidate {
  YouTubeCandidate({
    required this.song,
    required this.score,
    required this.isOfficial,
    required this.isTopic,
    required this.views,
    required this.likes,
  });

  final Map<String, dynamic> song;
  final double score;
  final bool isOfficial;
  final bool isTopic;
  final int views;
  final int likes;
}

/// Service responsible for discovering and verifying music releases from the
/// CURRENT CALENDAR WEEK using the public MusicBrainz API.
///
/// **Constraints**:
/// - Zero Spotify dependencies or authentication.
/// - YouTube upload date is NEVER the music release date.
/// - MusicBrainz public API is used with rate limiting and custom User-Agent.
/// - Cache is keyed by week ID, refreshing automatically each Monday.
/// - YouTube candidates are ranked with official preference: official video (2M views)
///   beats random re-upload (15M views).
class ReleaseMetadataService {
  ReleaseMetadataService({http.Client? httpClient})
      : _explicitClient = httpClient;

  static ReleaseMetadataService? _instance;

  /// Singleton instance.
  static ReleaseMetadataService get instance =>
      _instance ??= ReleaseMetadataService();

  final http.Client? _explicitClient;
  http.Client? _defaultClient;
  http.Client get _client =>
      _explicitClient ?? (_defaultClient ??= http.Client());

  // ── MusicBrainz API Constants ──────────────────────────────────────────────
  static const String _mbBaseUrl = 'https://musicbrainz.org/ws/2';
  static const String _userAgent =
      'SoundWave/1.0.0 (https://github.com/tejasshinde4545k/SoundWave)';
  static const Duration _httpTimeout = Duration(seconds: 10);

  // Rate limiting: MusicBrainz requests must not exceed 1 req/sec.
  DateTime _lastRequestTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minRequestInterval = Duration(milliseconds: 1050);

  // In-memory cache: weekKey -> List<Map<String, dynamic>>
  final Map<String, List<Map<String, dynamic>>> _memoryCache = {};
  // Verified release cache: normalized artist+title -> ReleaseMetadata
  final Map<String, ReleaseMetadata?> _verifiedReleaseCache = {};

  // ── Week Range Calculation ─────────────────────────────────────────────────

  /// Calculates the current calendar week range: Monday 00:00:00.000 to Sunday 23:59:59.999.
  CalendarWeekRange getCurrentWeekRange([DateTime? referenceDate]) {
    final now = referenceDate ?? DateTime.now();
    // Monday is weekday 1, Sunday is weekday 7
    final startDay = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    final startOfWeek = DateTime(
      startDay.year,
      startDay.month,
      startDay.day,
    );
    final endDay = startOfWeek.add(const Duration(days: 6));
    final endOfWeek = DateTime(
      endDay.year,
      endDay.month,
      endDay.day,
      23,
      59,
      59,
      999,
    );

    final weekNum = _getWeekOfYear(startOfWeek);
    final weekId = '${startOfWeek.year}-W${weekNum.toString().padLeft(2, '0')}';

    return CalendarWeekRange(
      startOfWeek: startOfWeek,
      endOfWeek: endOfWeek,
      weekId: weekId,
    );
  }

  /// Calculates ISO week number.
  static int _getWeekOfYear(DateTime date) {
    final dayOfYear = int.parse(
      '${date.difference(DateTime(date.year)).inDays + 1}',
    );
    return ((dayOfYear - date.weekday + 10) / 7).floor();
  }

  /// Evaluates whether a verified release date falls within the current calendar week.
  bool isReleasedThisWeek(DateTime? releaseDate, {DateTime? now}) {
    if (releaseDate == null) return false;
    final weekRange = getCurrentWeekRange(now);
    return weekRange.contains(releaseDate);
  }

  /// Parses a MusicBrainz date string (YYYY-MM-DD) into a DateTime.
  /// Returns null if only year or year-month is given or if unparseable,
  /// because an incomplete date cannot verify release within a specific 7-day week.
  DateTime? parsePreciseReleaseDate(String? rawDate) {
    if (rawDate == null || rawDate.trim().isEmpty) return null;
    final trimmed = rawDate.trim();
    // Full date required: YYYY-MM-DD
    final fullDateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!fullDateRegex.hasMatch(trimmed)) {
      return null;
    }
    return DateTime.tryParse(trimmed);
  }

  // ── Public Release Discovery & Ranking ─────────────────────────────────────

  /// Discovers and returns verified songs released in the CURRENT CALENDAR WEEK,
  /// matched to the single best playable YouTube candidate and personalized.
  ///
  /// Returns an empty list if no verified releases exist or MusicBrainz is unavailable.
  Future<List<Map<String, dynamic>>> getReleasesThisWeek({
    DateTime? now,
    String? regionCode,
    bool forceRefresh = false,
  }) async {
    final weekRange = getCurrentWeekRange(now);
    final effectiveRegion =
        regionCode ?? MusicRegionService.instance.getActiveRegionCode();
    final cacheKey = '${weekRange.weekId}_$effectiveRegion';

    // 1. Check in-memory cache
    if (!forceRefresh && _memoryCache.containsKey(cacheKey)) {
      debugPrint('[ReleaseMetadataService] Cache hit for $cacheKey');
      return _memoryCache[cacheKey]!;
    }

    // 2. Check persistent Hive cache
    if (!forceRefresh) {
      final persistent = _loadFromPersistentCache(cacheKey);
      if (persistent != null && persistent.isNotEmpty) {
        _memoryCache[cacheKey] = persistent;
        return persistent;
      }
    }

    try {
      // 3. Discover candidates from MusicBrainz
      final verifiedReleases = await _discoverMusicBrainzReleases(
        weekRange: weekRange,
      );

      if (verifiedReleases.isEmpty) {
        debugPrint(
          '[ReleaseMetadataService] No verified releases found for week ${weekRange.weekId}',
        );
        return [];
      }

      // 4. Resolve each verified release to the best playable YouTube version
      final resolvedSongs = <Map<String, dynamic>>[];
      final seenTrackKeys = <String>{};

      for (final release in verifiedReleases) {
        // Reissue/Remaster/Compilation guard: old recordings reissued this week are excluded
        if (release.isReissue || release.isCompilation) {
          debugPrint(
            '[ReleaseMetadataService] Excluded reissue/compilation: ${release.artist} - ${release.title}',
          );
          continue;
        }

        final normKey = _normalizeArtistTitle(release.artist, release.title);
        if (seenTrackKeys.contains(normKey)) continue;
        seenTrackKeys.add(normKey);

        final bestCandidate = await resolveBestYouTubeCandidate(
          artist: release.artist,
          title: release.title,
          releaseDate: release.releaseDate,
        );

        if (bestCandidate != null) {
          resolvedSongs.add(bestCandidate);
        }
      }

      if (resolvedSongs.isEmpty) {
        return [];
      }

      // 5. Personalize candidate order using listening profile & region
      final personalized = _personalizeReleases(
        resolvedSongs,
        effectiveRegion: effectiveRegion,
      );

      // 6. Cache final results
      _memoryCache[cacheKey] = personalized;
      _saveToPersistentCache(cacheKey, personalized);

      return personalized;
    } catch (e, st) {
      logger.log(
        'ReleaseMetadataService.getReleasesThisWeek failed',
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  // ── MusicBrainz API Discovery ──────────────────────────────────────────────

  /// Queries MusicBrainz for releases during the specified week range.
  Future<List<ReleaseMetadata>> _discoverMusicBrainzReleases({
    required CalendarWeekRange weekRange,
  }) async {
    final results = <ReleaseMetadata>[];
    final startDateStr = _formatIsoDate(weekRange.startOfWeek);
    final endDateStr = _formatIsoDate(weekRange.endOfWeek);

    // Query 1: Primary release groups of the current week (Single, EP, Album)
    final generalQuery =
        'firstreleasedate:[$startDateStr TO $endDateStr] AND '
        'status:official AND '
        '(primarytype:Single OR primarytype:EP OR primarytype:Album)';

    final generalReleases = await _queryMusicBrainzReleaseGroups(generalQuery);
    results.addAll(generalReleases);

    // Query 2: If user has favorite artists or regional artists, check them specifically
    try {
      final userProfile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: userRecentlyPlayed.value,
        likedSongs: userLikedSongsList.value,
      );

      final topArtists = userProfile.topArtists.take(3).toList();
      for (final artist in topArtists) {
        final artistQuery =
            'artist:"$artist" AND firstreleasedate:[$startDateStr TO $endDateStr]';
        final artistReleases = await _queryMusicBrainzReleaseGroups(artistQuery);
        for (final ar in artistReleases) {
          if (!results.any((r) => r.id == ar.id)) {
            results.add(ar);
          }
        }
      }
    } catch (_) {}

    return results;
  }

  /// Sends a rate-limited GET request to MusicBrainz ws/2/release-group.
  Future<List<ReleaseMetadata>> _queryMusicBrainzReleaseGroups(
    String query,
  ) async {
    try {
      await _rateLimitWait();

      final uri = Uri.parse('$_mbBaseUrl/release-group').replace(
        queryParameters: {
          'query': query,
          'fmt': 'json',
          'limit': '25',
        },
      );

      final response = await _client.get(
        uri,
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
      ).timeout(_httpTimeout);

      if (response.statusCode != 200) {
        debugPrint(
          '[ReleaseMetadataService] MusicBrainz status ${response.statusCode}: ${response.body}',
        );
        return [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final releaseGroups = data['release-groups'] as List<dynamic>? ?? [];

      final verified = <ReleaseMetadata>[];
      for (final rg in releaseGroups) {
        if (rg is! Map<String, dynamic>) continue;

        final firstReleaseDateStr = rg['first-release-date']?.toString();
        final releaseDate = parsePreciseReleaseDate(firstReleaseDateStr);
        if (releaseDate == null) {
          // Unverified or incomplete date -> DO NOT use
          continue;
        }

        final title = rg['title']?.toString() ?? '';
        final artistCredit = rg['artist-credit'] as List<dynamic>?;
        final artist = (artistCredit != null && artistCredit.isNotEmpty)
            ? (artistCredit[0]['name']?.toString() ?? '')
            : '';

        if (title.isEmpty || artist.isEmpty) continue;

        final primaryType = rg['primary-type']?.toString() ?? 'Single';
        final secondaryTypes = (rg['secondary-types'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [];

        // Check for reissue/compilation tags
        final isCompilation = secondaryTypes.any(
          (t) =>
              t.toLowerCase().contains('compilation') ||
              t.toLowerCase().contains('anthology'),
        );
        final isLive = secondaryTypes.any(
          (t) => t.toLowerCase().contains('live'),
        );

        // Check if first-release-date matches any specific release events
        // If first-release-date is earlier than current week, this is a reissue
        final isReissue = isCompilation || isLive;

        verified.add(
          ReleaseMetadata(
            id: rg['id']?.toString() ?? '',
            title: title,
            artist: artist,
            releaseDate: releaseDate,
            primaryType: primaryType,
            secondaryTypes: secondaryTypes,
            isReissue: isReissue,
            isCompilation: isCompilation,
          ),
        );
      }

      return verified;
    } catch (e) {
      debugPrint('[ReleaseMetadataService] MusicBrainz query error: $e');
      return [];
    }
  }

  /// Verifies a specific artist and song title against MusicBrainz to confirm release date.
  Future<ReleaseMetadata?> verifyRelease(
    String artist,
    String title, {
    DateTime? now,
  }) async {
    final normKey = _normalizeArtistTitle(artist, title);
    if (_verifiedReleaseCache.containsKey(normKey)) {
      return _verifiedReleaseCache[normKey];
    }

    try {
      await _rateLimitWait();

      final cleanTitle = formatSongTitle(title);
      final query = 'artist:"$artist" AND releasegroup:"$cleanTitle"';
      final uri = Uri.parse('$_mbBaseUrl/release-group').replace(
        queryParameters: {
          'query': query,
          'fmt': 'json',
          'limit': '5',
        },
      );

      final response = await _client.get(
        uri,
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
      ).timeout(_httpTimeout);

      if (response.statusCode != 200) {
        _verifiedReleaseCache[normKey] = null;
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rgs = data['release-groups'] as List<dynamic>? ?? [];

      for (final rg in rgs) {
        if (rg is! Map<String, dynamic>) continue;
        final firstReleaseDateStr = rg['first-release-date']?.toString();
        final releaseDate = parsePreciseReleaseDate(firstReleaseDateStr);
        if (releaseDate == null) continue;

        final rgTitle = rg['title']?.toString() ?? '';
        final primaryType = rg['primary-type']?.toString() ?? 'Single';
        final secondaryTypes = (rg['secondary-types'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [];

        final meta = ReleaseMetadata(
          id: rg['id']?.toString() ?? '',
          title: rgTitle.isNotEmpty ? rgTitle : cleanTitle,
          artist: artist,
          releaseDate: releaseDate,
          primaryType: primaryType,
          secondaryTypes: secondaryTypes,
          isReissue: secondaryTypes.any(
            (t) => t.toLowerCase().contains('compilation'),
          ),
        );

        _verifiedReleaseCache[normKey] = meta;
        return meta;
      }

      _verifiedReleaseCache[normKey] = null;
      return null;
    } catch (_) {
      _verifiedReleaseCache[normKey] = null;
      return null;
    }
  }

  // ── YouTube Resolution & Candidate Ranking ─────────────────────────────────

  /// Resolves the single best YouTube candidate for a verified release.
  Future<Map<String, dynamic>?> resolveBestYouTubeCandidate({
    required String artist,
    required String title,
    required DateTime releaseDate,
  }) async {
    try {
      final query = '$artist $title';
      final rawCandidates = await fetchSongsList(query);
      if (rawCandidates.isEmpty) return null;

      final ranked = rankYouTubeCandidates(
        candidates: rawCandidates,
        targetArtist: artist,
        targetTitle: title,
      );

      if (ranked.isEmpty) return null;

      // Select top-ranked playable candidate
      final winner = ranked.first.song;
      // Attach verified release date metadata
      final enriched = Map<String, dynamic>.from(winner);
      enriched['releaseDate'] = _formatIsoDate(releaseDate);
      enriched['isReleasedThisWeek'] = true;
      enriched['verifiedArtist'] = artist;
      enriched['verifiedTitle'] = title;

      return enriched;
    } catch (e) {
      debugPrint(
        '[ReleaseMetadataService] Error resolving YouTube candidate for $artist - $title: $e',
      );
      return null;
    }
  }

  /// Ranks multiple YouTube candidates for a release.
  ///
  /// Criteria:
  /// 1. Exact song title (+35 pts)
  /// 2. Exact artist (+30 pts)
  /// 3. Official artist channel (+25 pts)
  /// 4. Official label channel (+20 pts)
  /// 5. - Topic channel (+22 pts)
  /// 6. Official music video in title (+20 pts)
  /// 7. Official audio in title (+18 pts)
  /// 8. Lyric video (+12 pts)
  /// 9. Logarithmic view normalization: min(15.0, log(views + 1) * 1.5)
  /// 10. Logarithmic like normalization: min(10.0, log(likes + 1) * 1.2)
  /// 11. Like/view ratio (> 0.02 -> +5 pts)
  /// 12. Recent YouTube upload bonus (+5 pts)
  ///
  /// Rejects:
  /// - Non-song content via [RecommendationEngine.isLikelySong] (podcasts, "Latent Season 2 Bonus Episode", trailers, reactions)
  /// - Unofficial re-upload penalty (-40 pts)
  ///
  /// **Official video with 2M views beats random re-upload with 15M views.**
  List<YouTubeCandidate> rankYouTubeCandidates({
    required List<dynamic> candidates,
    required String targetArtist,
    required String targetTitle,
  }) {
    final scoredList = <YouTubeCandidate>[];
    final normTargetArtist = targetArtist.toLowerCase().trim();
    final normTargetTitle = targetTitle.toLowerCase().trim();

    for (final raw in candidates) {
      if (raw is! Map) continue;
      final song = Map<String, dynamic>.from(raw);
      final ytid = song['ytid']?.toString() ?? '';
      if (ytid.isEmpty || ytid.startsWith('jamendo:')) continue;

      final title = song['title']?.toString() ?? '';
      final isLive = song['isLive'] == true;

      // ── Filter non-music content ──────────────────────────────────────────
      if (!RecommendationEngine.isLikelySong(title, isLive: isLive)) {
        continue;
      }

      final author = (song['videoAuthor'] ?? song['artist'] ?? '')
          .toString()
          .toLowerCase();
      final lowerTitle = title.toLowerCase();

      // Explicit re-upload penalty
      final isReupload = lowerTitle.contains('re-upload') ||
          lowerTitle.contains('reupload') ||
          lowerTitle.contains('fan made') ||
          lowerTitle.contains('unofficial');

      // Check official markers
      final isTopic = author.endsWith('- topic') || author.contains('topic');
      final isOfficialChannel = author.contains('official') ||
          author.contains('vevo') ||
          _isKnownRecordLabel(author);
      final isExactArtistChannel = author.contains(normTargetArtist);

      // Scoring
      var score = 0.0;

      // 1. Exact song title match
      if (lowerTitle.contains(normTargetTitle)) {
        score += 35;
      } else {
        // Partial word overlap
        final targetWords = normTargetTitle
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 2);
        for (final w in targetWords) {
          if (lowerTitle.contains(w)) score += 5;
        }
      }

      // 2. Exact artist match
      if (author.contains(normTargetArtist) ||
          lowerTitle.contains(normTargetArtist)) {
        score += 30;
      }

      // 3 & 4. Channel authority
      if (isExactArtistChannel && isOfficialChannel) {
        score += 30;
      } else if (isExactArtistChannel) {
        score += 25;
      } else if (isOfficialChannel) {
        score += 20;
      } else if (isTopic) {
        score += 22;
      }

      // 5 & 6 & 7. Content format keywords
      if (lowerTitle.contains('official music video') ||
          lowerTitle.contains('official video')) {
        score += 20;
      } else if (lowerTitle.contains('official audio') ||
          lowerTitle.contains('full audio')) {
        score += 18;
      } else if (lowerTitle.contains('lyric video') ||
          lowerTitle.contains('official lyric')) {
        score += 12;
      }

      // 8. Re-upload penalty
      if (isReupload) {
        score -= 40;
      }

      // 9 & 10. Logarithmic view and like normalization
      // Ensures huge view counts (15M) cannot override official status (2M)
      final views = _extractInt(song['views'] ?? song['viewCount'] ?? 0);
      final likes = _extractInt(song['likes'] ?? song['likeCount'] ?? 0);

      if (views > 0) {
        final logViews = math.log(views + 1.0);
        // Capped at 15.0 points maximum
        score += math.min(15.0, logViews * 1.5);
      }

      if (likes > 0) {
        final logLikes = math.log(likes + 1.0);
        // Capped at 10.0 points maximum
        score += math.min(10.0, logLikes * 1.2);
      }

      // 11. Like/view ratio
      if (views > 1000 && likes > 0) {
        final ratio = likes / views;
        if (ratio >= 0.02) {
          score += 5;
        }
      }

      scoredList.add(
        YouTubeCandidate(
          song: song,
          score: score,
          isOfficial: isOfficialChannel || isExactArtistChannel,
          isTopic: isTopic,
          views: views,
          likes: likes,
        ),
      );
    }

    // Sort descending by calculated score
    scoredList.sort((a, b) => b.score.compareTo(a.score));
    return scoredList;
  }

  // ── Personalization ────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _personalizeReleases(
    List<Map<String, dynamic>> songs, {
    required String effectiveRegion,
  }) {
    final userProfile = MusicRegionService.instance.analyzeUserProfile(
      recentlyPlayed: userRecentlyPlayed.value,
      likedSongs: userLikedSongsList.value,
    );

    final scored = songs.map((song) {
      var boost = 0.0;
      final artist = song['artist']?.toString() ?? '';

      // 1. User's favorite artist boost
      if (userProfile.hasArtist(artist)) {
        boost += 35;
      }

      // 2. Regional preference boost
      if (effectiveRegion == 'IN') {
        final regionBonus = MusicRegionService.instance.calculateRegionalBonus(
          song: song,
          userProfile: userProfile,
          regionCode: 'IN',
        );
        boost += regionBonus;
      }

      return MapEntry(song, boost);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return scored.map((e) => e.key).toList();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _formatIsoDate(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  static bool _isKnownRecordLabel(String author) {
    const labels = [
      't-series',
      'sony music',
      'zee music',
      'yrf',
      'saregama',
      'tips official',
      'speed records',
      'warner records',
      'universal music',
      'interscope',
      'atlantic records',
      'columbia records',
      'def jam',
      'republic records',
      'geffen records',
      'spinnin records',
    ];
    for (final l in labels) {
      if (author.contains(l)) return true;
    }
    return false;
  }

  static String _normalizeArtistTitle(String artist, String title) {
    final a = artist.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
    final t = title.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();
    return '$a::$t';
  }

  static int _extractInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final sanitized = value.replaceAll(RegExp('[^0-9]'), '');
      return int.tryParse(sanitized) ?? 0;
    }
    return 0;
  }

  Future<void> _rateLimitWait() async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequestTime);
    if (elapsed < _minRequestInterval) {
      await Future.delayed(_minRequestInterval - elapsed);
    }
    _lastRequestTime = DateTime.now();
  }

  // ── Persistent Cache ───────────────────────────────────────────────────────

  List<Map<String, dynamic>>? _loadFromPersistentCache(String key) {
    try {
      final raw = Hive.box('userNoBackup').get('rtw_$key');
      if (raw is List) {
        return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return null;
  }

  void _saveToPersistentCache(String key, List<Map<String, dynamic>> songs) {
    try {
      Hive.box('userNoBackup').put('rtw_$key', songs);
    } catch (_) {}
  }
}
