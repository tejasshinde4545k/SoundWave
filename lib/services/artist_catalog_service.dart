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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:soundwave/services/artist_image_resolver.dart';
import 'package:soundwave/services/artist_service.dart';
import 'package:soundwave/services/common_services.dart';
import 'package:soundwave/services/data_manager.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/utilities/app_utils.dart';
import 'package:soundwave/utilities/formatter.dart';

/// Service responsible for on-demand resolution of an artist's complete,
/// verified music catalog, filtering non-music items (podcasts, episodes, etc.)
/// and deduplicating multiple versions of the same track.
class ArtistCatalogService {
  ArtistCatalogService._();

  static final ArtistCatalogService instance = ArtistCatalogService._();

  // In-memory cache: artistKey -> List<Map<String, dynamic>>
  final Map<String, List<Map<String, dynamic>>> _memoryCache = {};

  @visibleForTesting
  void seedArtistSongsForTesting(String artist, List<Map<String, dynamic>> songs) {
    _memoryCache[artist.toLowerCase()] = songs;
  }

  /// Retrieves all verified songs for [artistName] on demand.
  /// Deduplicates multiple copies (Official Video, Audio, Lyrics) into the
  /// single best playable version and filters out non-music items.
  Future<List<Map<String, dynamic>>> getArtistSongs(
    String artistName, {
    String? artistId,
    bool forceRefresh = false,
    int maxSongs = 50,
  }) async {
    final cleanName = normalizeArtistDisplayTitle(artistName);
    if (cleanName.isEmpty || ArtistImageResolver.isRecordLabelOrChannel(cleanName)) {
      return [];
    }

    final key = cleanName.toLowerCase();

    // 1. Check memory cache
    if (!forceRefresh && _memoryCache.containsKey(key)) {
      return _memoryCache[key]!;
    }

    // 2. Check persistent Hive cache
    final persistentKey = 'artist_catalog_v2_$key';
    if (!forceRefresh) {
      try {
        final cached = await getData('cache', persistentKey);
        if (cached is List && cached.isNotEmpty) {
          final songs = asMapList(cached);
          _memoryCache[key] = songs;
          return songs;
        }
      } catch (_) {}
    }

    // 3. Fetch candidate tracks
    final candidatePool = <Map<String, dynamic>>[];
    final seenYtids = <String>{};

    void addCandidate(Map<String, dynamic> song) {
      final ytid = song['ytid']?.toString() ?? '';
      if (ytid.isNotEmpty && seenYtids.add(ytid)) {
        candidatePool.add(song);
      }
    }

    // A. Gather from YouTube Music artist profile if available
    try {
      final profile = await getArtistProfile(
        artistId ?? cleanName,
        preferredName: cleanName,
      );
      if (profile != null) {
        final topSongs = asMapList(profile['topSongs']);
        for (final entry in topSongs) {
          if (entry['song'] is Map) {
            addCandidate(Map<String, dynamic>.from(entry['song'] as Map));
          }
        }
      }
    } catch (_) {}

    // B. Query YouTube Music / search architecture with targeted queries
    final queries = [
      '$cleanName songs',
      '$cleanName official',
      cleanName,
    ];

    for (final q in queries) {
      try {
        final results = await fetchSongsList(q);
        for (final item in results) {
          if (item is Map) {
            addCandidate(Map<String, dynamic>.from(item));
          }
        }
        if (candidatePool.length >= 60) break;
      } catch (_) {}
    }

    // 4. Verify candidate tracks belong to the artist & reject non-music
    final verifiedCandidates = <Map<String, dynamic>>[];

    for (final song in candidatePool) {
      final title = song['title']?.toString() ?? '';
      final author = song['artist']?.toString() ?? '';

      // Reject non-music results (podcasts, episodes, interviews, reactions, trailers)
      if (!RecommendationEngine.isLikelySong(title, isLive: song['isLive'] == true)) {
        continue;
      }

      // Verify song actually belongs to the selected artist
      if (!_doesSongBelongToArtist(title, author, cleanName)) {
        continue;
      }

      verifiedCandidates.add(song);
    }

    // 5. Deduplicate multiple versions of the same song into the best version
    final deduplicatedSongs = _deduplicateSongVersions(verifiedCandidates, cleanName);

    // Limit to safe maximum
    final result = deduplicatedSongs.take(maxSongs).toList();

    // Cache results
    _memoryCache[key] = result;
    unawaited(() async {
      try {
        await addOrUpdateData<List>('cache', persistentKey, result);
      } catch (_) {}
    }());

    return result;
  }

  /// Verifies that a song candidate actually features or belongs to [artistName].
  bool _doesSongBelongToArtist(String title, String author, String artistName) {
    final lowerTitle = title.toLowerCase();
    final lowerAuthor = author.toLowerCase();
    final lowerArtist = artistName.toLowerCase().trim();

    // Direct contains check on title or author
    if (lowerTitle.contains(lowerArtist) || lowerAuthor.contains(lowerArtist)) {
      return true;
    }

    // Check individual name parts (for names with 2+ parts like "Arijit Singh")
    final nameParts = lowerArtist.split(RegExp(r'\s+')).where((p) => p.length > 2).toList();
    if (nameParts.length >= 2) {
      // Both first and last name must appear in title or author
      final hasAllParts = nameParts.every(
        (part) => lowerTitle.contains(part) || lowerAuthor.contains(part),
      );
      if (hasAllParts) return true;
    }

    return false;
  }

  /// Deduplicates song candidates by canonical song title and picks the best playable version.
  List<Map<String, dynamic>> _deduplicateSongVersions(
    List<Map<String, dynamic>> candidates,
    String artistName,
  ) {
    // Group candidates by canonical song title
    final groups = <String, List<Map<String, dynamic>>>{};

    for (final song in candidates) {
      final title = song['title']?.toString() ?? '';
      final key = _canonicalSongKey(title, artistName);
      if (key.isEmpty) continue;

      groups.putIfAbsent(key, () => []).add(song);
    }

    final bestSongs = <Map<String, dynamic>>[];

    for (final group in groups.values) {
      if (group.isEmpty) continue;
      // Sort group candidates to choose the best version
      group.sort((a, b) => _scoreSongVersion(b).compareTo(_scoreSongVersion(a)));
      final best = group.first;

      // Clean the display title
      final cleanTitle = _cleanSongDisplayTitle(best['title']?.toString() ?? '', artistName);

      bestSongs.add({
        ...best,
        'title': cleanTitle,
        'artist': artistName,
      });
    }

    return bestSongs;
  }

  /// Scores a candidate YouTube video version to select the best playable audio/video.
  double _scoreSongVersion(Map<String, dynamic> song) {
    var score = 0.0;
    final title = (song['title']?.toString() ?? '').toLowerCase();
    final artist = (song['artist']?.toString() ?? '').toLowerCase();

    // Official audio / official video priority
    if (title.contains('official audio') || title.contains('audio')) score += 25.0;
    if (title.contains('official music video') || title.contains('official video')) score += 22.0;
    if (title.contains('lyric video') || title.contains('lyrics')) score += 15.0;

    // Topic channel / verified author priority
    if (artist.endsWith('- topic') || artist.endsWith('topic')) score += 20.0;
    if (artist.contains('vevo')) score += 18.0;

    // Penalize remixes, reactions, slowed/reverb unless requested
    if (title.contains('reaction')) score -= 50.0;
    if (title.contains('remix')) score -= 5.0;
    if (title.contains('slowed') || title.contains('reverb')) score -= 15.0;
    if (title.contains('cover')) score -= 20.0;

    // Favor reasonable views/likes if available
    final views = int.tryParse(song['views']?.toString() ?? '0') ?? 0;
    if (views > 0) {
      score += math.min(15.0, math.log(views + 1.0) * 1.5);
    }

    return score;
  }

  /// Normalizes a song title into a canonical key for version deduplication.
  String _canonicalSongKey(String title, String artistName) {
    var clean = title.toLowerCase();

    // Remove artist name
    clean = clean.replaceAll(artistName.toLowerCase(), '');

    // Remove common video artifacts
    clean = clean
        .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
        .replaceAll(RegExp(r'\|.*'), '')
        .replaceAll(RegExp(r'\b(official|music|video|audio|lyrics?|full song|hd|4k|lyric|remastered|visualizer)\b'), '')
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return clean;
  }

  /// Cleans the display title of a song by removing YouTube video clutter.
  String _cleanSongDisplayTitle(String title, String artistName) {
    var clean = formatSongTitle(title);
    if (clean.contains('|')) {
      clean = clean.split('|')[0].trim();
    }
    return clean.isEmpty ? title : clean;
  }
}
