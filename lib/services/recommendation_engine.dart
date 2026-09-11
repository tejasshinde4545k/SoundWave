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

import 'package:flutter/foundation.dart';
import 'package:soundwave/main.dart' show logger;
import 'package:soundwave/services/common_services.dart'
    show fetchSongsList, userLikedSongsList, userRecentlyPlayed;
import 'package:soundwave/services/music_region_service.dart';
import 'package:soundwave/services/proxy_manager.dart';
import 'package:soundwave/services/recommendation_cache.dart';
import 'package:soundwave/utilities/formatter.dart' show returnSongLayout;

/// Generates a ranked pool of YouTube song recommendations for the current song.
///
/// **YouTube-only**: this class never touches Jamendo. Jamendo is handled
/// separately in `MusifyAudioHandler._tryPlayJamendoFallback()`.
///
/// Three candidate sources are queried in parallel; each result is scored by
/// relevance, deduplicated by YouTube video ID, and filtered through
/// [isLikelySong] before being returned as a sorted list.
///
/// Source scoring (base values, weighted by result position):
///   A. Related videos  → +50 pts  (most relevant — direct YouTube signal)
///   B. Same-artist     → +30 pts  (e.g. "Tame Impala songs")
///   C. Artist + title  → +20 pts  (e.g. "Tame Impala Loser")
///
/// Modifier adjustments applied after scoring:
///   Liked by user      → +10 pts
///   Recently played    → −50 pts  (discourages immediate repetition)
///   Regional alignment → +0..35 pts (location-aware cultural relevance)
class RecommendationEngine {
  RecommendationEngine._();

  /// Singleton instance.
  static final RecommendationEngine instance = RecommendationEngine._();

  // ── Fetch limits ─────────────────────────────────────────────────────────────
  static const int _maxRelatedCandidates = 15;
  static const int _maxArtistResults = 10;
  static const int _maxTitleResults = 8;
  static const Duration _fetchTimeout = Duration(seconds: 12);

  // ── Score weights ─────────────────────────────────────────────────────────────
  static const double _relatedBase = 50;
  static const double _artistBase = 30;
  static const double _titleBase = 20;
  static const double _likedBonus = 10;
  static const double _recentPenalty = 50;

  /// Internal map key used to carry raw score through the candidate pipeline.
  static const String _scoreKey = '_rec_score';

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Returns up to [limit] scored YouTube song candidates for [currentSong],
  /// excluding every ID in [excludeIds].
  ///
  /// [recentlyPlayedIds] receive a score penalty; [likedIds] receive a bonus.
  /// [regionCode] and [userProfile] incorporate culturally relevant signals.
  Future<List<Map<String, dynamic>>> getRecommendations(
    Map<String, dynamic> currentSong,
    Set<String> excludeIds, {
    int limit = 10,
    Set<String> recentlyPlayedIds = const {},
    Set<String> likedIds = const {},
    String? regionCode,
    UserMusicProfile? userProfile,
  }) async {
    final ytid = currentSong['ytid']?.toString() ?? '';
    if (ytid.isEmpty || ytid.startsWith('jamendo:')) return [];

    debugPrint(
      '[SoundWave Recommendation] CURRENT SONG: ${currentSong['title']}',
    );

    // ── Cache lookup ──────────────────────────────────────────────────────────
    final cached = RecommendationCache.instance.get(ytid);
    final List<Map<String, dynamic>> rawCandidates;

    if (cached != null) {
      debugPrint('[SoundWave Recommendation] CACHE HIT for $ytid');
      rawCandidates = List.of(cached);
    } else {
      rawCandidates = await _fetchAllCandidates(currentSong, excludeIds);
      if (rawCandidates.isNotEmpty) {
        // Strip internal score key before caching so the same entry is
        // re-usable across callers with different exclude sets.
        final toCache = rawCandidates
            .map((c) => Map<String, dynamic>.from(c)..remove(_scoreKey))
            .toList();
        RecommendationCache.instance.put(ytid, toCache);
      }
    }

    var effectiveRegion = regionCode ?? 'GLOBAL';
    if (regionCode == null) {
      try {
        effectiveRegion = MusicRegionService.instance.getActiveRegionCode();
      } catch (_) {}
    }

    var profile = userProfile ??
        const UserMusicProfile(
          isColdStart: true,
          totalSampledSongs: 0,
          topArtists: {},
          languageAffinities: {},
          isEnglishHeavy: false,
          isKPopHeavy: false,
          isIndianHeavy: false,
        );
    if (userProfile == null) {
      try {
        profile = MusicRegionService.instance.analyzeUserProfile(
          recentlyPlayed: userRecentlyPlayed.value,
          likedSongs: userLikedSongsList.value,
        );
      } catch (_) {}
    }

    // ── Score → dedup → sort ──────────────────────────────────────────────────
    return rankCandidates(
      rawCandidates,
      excludeIds: excludeIds,
      limit: limit,
      recentlyPlayedIds: recentlyPlayedIds,
      likedIds: likedIds,
      regionCode: effectiveRegion,
      userProfile: profile,
    );
  }

  /// Scores, filters through [isLikelySong], deduplicates, and ranks [candidates]
  /// combining base relevance, user affinity (liked/recently played), and
  /// location/regional preference signals.
  List<Map<String, dynamic>> rankCandidates(
    List<Map<String, dynamic>> candidates, {
    Set<String> excludeIds = const {},
    int limit = 15,
    Set<String> recentlyPlayedIds = const {},
    Set<String> likedIds = const {},
    String? regionCode,
    UserMusicProfile? userProfile,
  }) {
    var effectiveRegion = regionCode ?? 'GLOBAL';
    if (regionCode == null) {
      try {
        effectiveRegion = MusicRegionService.instance.getActiveRegionCode();
      } catch (_) {}
    }

    var profile = userProfile ??
        const UserMusicProfile(
          isColdStart: true,
          totalSampledSongs: 0,
          topArtists: {},
          languageAffinities: {},
          isEnglishHeavy: false,
          isKPopHeavy: false,
          isIndianHeavy: false,
        );
    if (userProfile == null) {
      try {
        profile = MusicRegionService.instance.analyzeUserProfile(
          recentlyPlayed: userRecentlyPlayed.value,
          likedSongs: userLikedSongsList.value,
        );
      } catch (_) {}
    }

    final scores = <String, double>{};
    final songMap = <String, Map<String, dynamic>>{};

    for (final c in candidates) {
      final id = c['ytid']?.toString() ?? '';
      if (id.isEmpty || id.startsWith('jamendo:') || excludeIds.contains(id)) {
        continue;
      }
      final title = c['title']?.toString() ?? '';
      if (!isLikelySong(title, isLive: c['isLive'] == true)) continue;

      final base = (c[_scoreKey] as double?) ?? 50.0;
      var score = (scores[id] ?? 0.0) + base;

      if (recentlyPlayedIds.contains(id)) score -= _recentPenalty;
      if (likedIds.contains(id)) score += _likedBonus;

      // Personal artist match bonus
      final artist = c['artist']?.toString() ?? '';
      if (artist.isNotEmpty && profile.hasArtist(artist)) {
        score += 30.0;
      }

      // User language preference match bonus
      final candLang = MusicRegionService.instance.detectCandidateLanguage(c);
      final userLangAffinity = profile.getAffinityForLanguage(candLang);
      if (!profile.isColdStart) {
        score += userLangAffinity * 25.0;
      }

      // Regional recommendation signal
      final regBonus = MusicRegionService.instance.calculateRegionalBonus(
        song: c,
        regionCode: effectiveRegion,
        userProfile: profile,
      );
      score += regBonus;

      scores[id] = score;
      songMap[id] = c;
    }

    debugPrint(
      '[SoundWave Recommendation] AFTER DUPLICATE & FILTER: ${scores.length}',
    );

    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final result = sorted.take(limit).map((e) {
      return Map<String, dynamic>.from(songMap[e.key]!)..remove(_scoreKey);
    }).toList();

    debugPrint('[SoundWave Recommendation] FINAL RANKED CANDIDATES: ${result.length}');
    return result;
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _fetchAllCandidates(
    Map<String, dynamic> currentSong,
    Set<String> excludeIds,
  ) async {
    final ytid = currentSong['ytid']?.toString() ?? '';
    final artist = currentSong['artist']?.toString().trim() ?? '';
    final title = currentSong['title']?.toString().trim() ?? '';

    // All three sources fire concurrently to minimise wall-clock time.
    final futures = <Future<List<Map<String, dynamic>>>>[
      _fetchRelatedVideos(ytid, excludeIds),
      if (artist.isNotEmpty)
        _fetchSearch(
          '$artist songs',
          excludeIds,
          _artistBase,
          _maxArtistResults,
        )
      else
        Future.value([]),
      if (artist.isNotEmpty && title.isNotEmpty)
        _fetchSearch('$artist $title', excludeIds, _titleBase, _maxTitleResults)
      else
        Future.value([]),
    ];

    final results = await Future.wait(futures);

    debugPrint(
      '[SoundWave Recommendation] RELATED CANDIDATES: ${results[0].length}',
    );
    debugPrint(
      '[SoundWave Recommendation] ARTIST CANDIDATES: ${results[1].length}',
    );
    debugPrint(
      '[SoundWave Recommendation] SEARCH CANDIDATES: ${results[2].length}',
    );

    return results.expand((r) => r).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchRelatedVideos(
    String ytid,
    Set<String> excludeIds,
  ) async {
    try {
      final client = ProxyManager().getClientSync();
      final video = await client.videos.get(ytid).timeout(_fetchTimeout);
      final related =
          await client.videos.getRelatedVideos(video).timeout(_fetchTimeout) ??
          [];

      final results = <Map<String, dynamic>>[];
      var acceptCount = 0;

      for (var i = 0; i < related.length; i++) {
        final v = related[i];
        final id = v.id.value;
        if (excludeIds.contains(id)) continue;
        if (v.isLive) continue;
        if (!isLikelySong(v.title)) continue;
        if (acceptCount >= _maxRelatedCandidates) break;

        final song = Map<String, dynamic>.from(returnSongLayout(0, v));
        // Weight by position: earliest related videos are most relevant.
        song[_scoreKey] =
            _relatedBase * (1.0 - acceptCount / _maxRelatedCandidates);
        results.add(song);
        acceptCount++;
      }

      return results;
    } catch (e, st) {
      logger.log(
        'RecommendationEngine: error fetching related videos for $ytid',
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchSearch(
    String query,
    Set<String> excludeIds,
    double baseScore,
    int maxResults,
  ) async {
    try {
      final rawList = await fetchSongsList(query).timeout(_fetchTimeout);
      final results = <Map<String, dynamic>>[];
      var acceptCount = 0;

      for (final item in rawList) {
        if (item is! Map) continue;
        final id = item['ytid']?.toString() ?? '';
        if (id.isEmpty || id.startsWith('jamendo:')) continue;
        if (excludeIds.contains(id)) continue;
        final title = item['title']?.toString() ?? '';
        if (!isLikelySong(title, isLive: item['isLive'] == true)) continue;
        if (acceptCount >= maxResults) break;

        final song = Map<String, dynamic>.from(item);
        song[_scoreKey] = baseScore * (1.0 - acceptCount / maxResults);
        results.add(song);
        acceptCount++;
      }

      return results;
    } catch (e, st) {
      logger.log(
        'RecommendationEngine: error in search "$query"',
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  // ── Song-title filter ────────────────────────────────────────────────────────

  /// Returns `true` when [title] looks like a music song, and `false` when it
  /// clearly describes non-music content (podcast, vlog, gaming, etc.).
  ///
  /// The filter is intentionally *permissive*: ambiguous titles are accepted.
  static bool isLikelySong(String title, {bool isLive = false}) {
    final t = title.toLowerCase();

    // Explicit music signals → always accept (takes priority over non-song signals).
    final musicSignals = RegExp(
      r'\b(official\s+music\s+video|official\s+audio|official\s+video|'
      r'official\s+lyric|lyric\s+video|lyrics\s+video|full\s+audio|'
      r'music\s+video|\blyrics?\b|\bsong\b|\btrack\b|\bremix\b|'
      r'\bcover\b|acoustic|\bsingl[e]?\b|\balbum\b|'
      r'\bkaraoke\b|\bost\b|\bsoundtrack\b|feat\.|ft\.|'
      r'official\s+performance|live\s+(performance|concert|session|show)|'
      r'\baudio\b|\boriginal\s+song\b|music\s+only|'
      r'unplugged|mashup|lofi|lo-fi|lo\s+fi)\b',
      caseSensitive: false,
    );
    if (musicSignals.hasMatch(t)) return true;

    // Reject obviously non-music content.
    final nonSongSignals = RegExp(
      r'\b(episode|season|bonus\s+episode|podcast|interview|reaction|'
      'review|documentary|vlog|vlogging|gameplay|gaming|tutorial|'
      r'news|talk\s+show|comedy\s+show|sketch|shorts?\s+video|'
      r'debate|roast|press\s+conference|q\s*&\s*a|ama\b|'
      r'trailer|teaser|behind\s+the\s+scenes|bts\s+video|'
      r'#shorts)\b',
      caseSensitive: false,
    );
    if (nonSongSignals.hasMatch(t)) return false;

    // Active live-streams that are not concerts are likely not standalone songs.
    if (isLive) return false;

    // Default: accept (prefer false-negatives over false-positives).
    return true;
  }
}
