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
        // Cache raw candidates with their source base scores intact so that
        // rankCandidates can distinguish a strong related-video match (50)
        // from a weaker search result (30/20) on cache hit.
        RecommendationCache.instance.put(ytid, rawCandidates);
      }
    }

    var effectiveRegion = regionCode ?? 'GLOBAL';
    if (regionCode == null) {
      try {
        effectiveRegion = MusicRegionService.instance.getActiveRegionCode();
      } catch (_) {}
    }

    var profile =
        userProfile ??
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
      contextSong: currentSong,
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
    Map<String, dynamic>? contextSong,
    Set<String> excludeIds = const {},
    int limit = 15,
    Set<String> recentlyPlayedIds = const {},
    Set<String> likedIds = const {},
    String? regionCode,
    UserMusicProfile? userProfile,
  }) {
    final effectiveRegion = regionCode?.toUpperCase() ?? 'GLOBAL';
    final profile = userProfile ??
        const UserMusicProfile(
          isColdStart: true,
          totalSampledSongs: 0,
          topArtists: {},
          languageAffinities: {},
          isEnglishHeavy: false,
          isKPopHeavy: false,
          isIndianHeavy: false,
        );

    final scores = <String, double>{};
    final songMap = <String, Map<String, dynamic>>{};
    final seenYtids = <String>{};

    String? contextKey;
    if (contextSong != null) {
      contextKey = canonicalSongKey(
        contextSong['title']?.toString() ?? '',
        contextSong['artist']?.toString() ?? '',
      );
    }

    for (final c in candidates) {
      final id = c['ytid']?.toString() ?? '';
      if (id.isEmpty ||
          id.startsWith('jamendo:') ||
          excludeIds.contains(id) ||
          seenYtids.contains(id)) {
        continue;
      }
      final title = c['title']?.toString() ?? '';
      if (!isLikelySong(title, isLive: _isLiveCandidate(c))) continue;
      if (contextSong != null &&
          !isValidQueueCandidate(candidate: c, contextSong: contextSong)) {
        continue;
      }

      final artist = c['artist']?.toString() ?? '';
      final canonicalKey = canonicalSongKey(title, artist);

      // Skip if this candidate is just a re-upload/alt-spelling of the
      // song already playing, under a different YouTube ID.
      if (contextKey != null && canonicalKey == contextKey) {
        seenYtids.add(id);
        continue;
      }

      seenYtids.add(id);

      final base = (c[_scoreKey] as double?) ?? 50.0;
      var score = (scores[canonicalKey] ?? 0.0) + base;

      if (recentlyPlayedIds.contains(id)) score -= _recentPenalty;
      if (likedIds.contains(id)) score += _likedBonus;

      // Personal artist match bonus
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

      // Keep the highest-scoring representative of this canonical song —
      // e.g. if both a related-video hit and a search hit resolve to the
      // same underlying track, keep whichever scored higher.
      final existing = scores[canonicalKey];
      if (existing == null || score > existing) {
        scores[canonicalKey] = score;
        songMap[canonicalKey] = c;
      }
    }

    debugPrint(
      '[SoundWave Recommendation] AFTER DUPLICATE & FILTER: ${scores.length}',
    );

    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final result = sorted.take(limit).map((e) {
      return Map<String, dynamic>.from(songMap[e.key]!)..remove(_scoreKey);
    }).toList();

    debugPrint(
      '[SoundWave Recommendation] FINAL RANKED CANDIDATES: ${result.length}',
    );
    return result;
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _fetchAllCandidates(
    Map<String, dynamic> currentSong,
    Set<String> excludeIds,
  ) async {
    final ytid = currentSong['ytid']?.toString() ?? '';
    final artist = currentSong['artist']?.toString().trim() ?? '';

    // All three sources fire concurrently to minimise wall-clock time.
    // NOTE: We intentionally do NOT search "$artist $title" here because that
    // query floods results with re-uploads/variants of the same song
    // (e.g. "Shayad Lyrics", "Shayad Reprise", "Shayad Slowed+Reverb").
    // Instead we use "$artist songs" (broad artist catalog) and
    // "$artist popular songs" (top hits) to find genuinely different tracks.
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
      if (artist.isNotEmpty)
        _fetchSearch(
          '$artist popular songs',
          excludeIds,
          _titleBase,
          _maxTitleResults,
        )
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
      '[SoundWave Recommendation] POPULAR CANDIDATES: ${results[2].length}',
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
        if (!isLikelySong(v.title, isLive: v.isLive)) continue;
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
        if (!isLikelySong(title, isLive: _isLiveCandidate(item))) continue;
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
  // ── isLive normalization ────────────────────────────────────────────────────

  /// Returns the live-stream flag from a candidate map, normalizing across
  /// different key formats that may come from different data sources.
  static bool _isLiveCandidate(Map candidate) {
    final raw = candidate['isLive'] ?? candidate['is_live'] ?? candidate['live'];
    if (raw is bool) return raw;
    if (raw is int) return raw == 1;
    if (raw is String) return raw.toLowerCase() == 'true';
    return false;
  }

  // ── Queue relevance gate ─────────────────────────────────────────────────────

  /// Returns true when [candidateTitle] is a variant/re-upload of [contextTitle].
  ///
  /// "Shayad" → rejects "Shayad Lyrics", "Shayad Reprise", "Shayad Slowed", etc.
  /// This is the primary guard against the same-song variant contamination bug.
  static bool _isSameSongVariant(String candidateTitle, String contextTitle) {
    if (contextTitle.isEmpty) return false;

    // Strip common suffixes / qualifiers from both sides to get core titles.
    final variantSuffixRe = RegExp(
      r'\s*[\(\[\|·•-].*$|'
      r'\b(official|audio|video|lyrics?|lyric|full|hd|4k|remix|cover|'
      'acoustic|reprise|slowed|reverb|lofi|lo.fi|extended|remastered|'
      'unplugged|instrumental|karaoke|version|feat.?|ft.?|'
      'lockdown|quarantine|studio|live|concert|performance|'
      'recreation|slow|sped.?up|nightcore|'
      r'piano|violin|guitar|flute|tribute)\b.*$',
      caseSensitive: false,
    );

    String coreTitle(String t) {
      var s = t.toLowerCase().trim();
      s = s.replaceFirst(variantSuffixRe, '').trim();
      // Remove any remaining non-alphanumeric clutter
      s = s.replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      return s;
    }

    final coreCtx = coreTitle(contextTitle);
    final coreCand = coreTitle(candidateTitle);

    if (coreCtx.isEmpty || coreCand.isEmpty) return false;

    if (coreCand == coreCtx) return true;

    // Variant when one starts with the other on a word boundary,
    // provided the prefix is substantial (not a single short generic word).
    if (coreCand.startsWith('$coreCtx ') && coreCtx.length >= 4) return true;
    if (coreCtx.startsWith('$coreCand ') && coreCand.length >= 8) return true;

    return false;
  }

  /// Final gate before a search/recommendation-sourced candidate may enter
  /// the live queue. isLikelySong() only asks "is this a song?" — this asks
  /// Final gate before a search/recommendation-sourced candidate may enter
  /// the live queue.
  ///
  /// A candidate is rejected when:
  ///   1. Same canonical song identity
  ///   2. Same YouTube ID
  ///   3. Obvious version of the same underlying song (Shayad variant protection)
  ///   4. Non-music content / not likely a song
  ///
  /// Genuinely different songs (including different devotional songs) are ACCEPTED.
  static bool isValidQueueCandidate({
    required Map<String, dynamic> candidate,
    required Map<String, dynamic> contextSong,
  }) {
    final title = candidate['title']?.toString() ?? '';
    final ytid = candidate['ytid']?.toString() ?? '';
    final artist = candidate['artist']?.toString() ?? '';

    final ctxTitle = contextSong['title']?.toString() ?? '';
    final ctxYtid = contextSong['ytid']?.toString() ?? '';
    final ctxArtist = contextSong['artist']?.toString() ?? '';

    final candKey = canonicalSongKey(title, artist);
    final ctxKey = canonicalSongKey(ctxTitle, ctxArtist);

    void logDecision(String decision, String reason) {
      debugPrint(
        '[RECOMMENDATION FILTER]\n'
        'TITLE=$title\n'
        'ARTIST=$artist\n'
        'YTID=$ytid\n'
        'CANONICAL_KEY=$candKey\n'
        'CONTEXT_KEY=$ctxKey\n'
        'DECISION=$decision\n'
        'REASON=$reason',
      );
    }

    if (title.isEmpty || ytid.isEmpty) {
      logDecision('REJECT', 'empty_title_or_id');
      return false;
    }

    final nonMusicExtra = RegExp(
      r'\b(responds?\s+to|reacts?\s+to|statement\s+on|spokesperson|'
      r'press\s+release|breaking|update\s+on|coverage|analysis|'
      r'exclusive|full\s+speech|address(es)?\s+to)\b',
      caseSensitive: false,
    );
    if (nonMusicExtra.hasMatch(title) ||
        !isLikelySong(title, isLive: _isLiveCandidate(candidate))) {
      logDecision('REJECT', 'non_music_content');
      return false;
    }

    // 1. Same YouTube ID
    if (ctxYtid.isNotEmpty && ytid == ctxYtid) {
      logDecision('REJECT', 'same_youtube_id');
      return false;
    }

    // 2. Same canonical song identity
    if (ctxKey.isNotEmpty && candKey == ctxKey) {
      logDecision('REJECT', 'same_canonical_identity');
      return false;
    }

    // 3. Obvious version of the same underlying song (Shayad variant protection)
    if (_isSameSongVariant(title, ctxTitle)) {
      debugPrint(
        '[QUEUE TRACE] REJECTED same-song-variant: "$title" vs context "$ctxTitle"',
      );
      logDecision('REJECT', 'same_song_variant');
      return false;
    }

    logDecision('ACCEPT', 'valid_different_song');
    return true;
  }

  // ── Canonical dedup key ──────────────────────────────────────────────────────

  /// Normalizes a title/artist pair into a stable key so that re-uploads,
  /// alternate spellings, and minor typos of the same song collapse to one
  /// entry instead of appearing as separate queue items (e.g. "Shayad" vs
  /// "Sayad" vs "Shaayad" by the same artist).
  static String canonicalSongKey(String title, String artist) {
    String normalize(String s) {
      var t = s.toLowerCase();
      t = t.replaceAll(
        RegExp(
          r'\b(official|audio|video|lyrics?|full|hd|4k|remix|cover|'
          r'acoustic|version|feat\.?|ft\.?)\b',
          caseSensitive: false,
        ),
        '',
      );
      t = t.replaceAll(RegExp(r'[^\w\s]'), '');
      t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      return t;
    }

    String foldPhonetic(String s) {
      // Only fold when long enough that collapsing doubled letters / common
      // digraphs won't accidentally merge two genuinely different short words.
      if (s.length < 5) return s;
      return s
          .replaceAll(RegExp(r'(.)\1+'), r'$1')
          .replaceAll('ph', 'f')
          .replaceAll('sh', 's')
          .replaceAll('ay', 'ai');
    }

    final normTitle = normalize(title);
    final normArtist = normalize(artist);

    return '${foldPhonetic(normTitle)}::${foldPhonetic(normArtist)}';
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
