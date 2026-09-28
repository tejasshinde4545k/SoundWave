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
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:soundwave/config/jiosaavn_config.dart';
import 'package:soundwave/main.dart' show logger;

/// JioSaavn API client using the open-source proxy:
///   https://github.com/sumitkolhe/jiosaavn-api  (public: https://saavn.dev)
///
/// **Verified endpoints (v0.1.0):**
///   GET /api/search/songs?query=<q>&limit=<n>&page=1
///   GET /api/songs?ids=<comma-separated-ids>
///
/// Stream URLs are embedded in the response under `downloadUrl` as a list of
/// quality-keyed objects:
///   [ { quality: "320kbps", url: "https://..." }, ... ]
///
/// Results are cached in-memory using a short TTL to prevent redundant calls.
/// Stream URLs are never persisted to disk because they expire.
///
/// Use the singleton [JioSaavnService.instance].
class JioSaavnService {
  JioSaavnService._();

  static final JioSaavnService instance = JioSaavnService._();

  static const Duration _timeout = Duration(seconds: 15);
  static const Duration _streamUrlCacheDuration = Duration(minutes: 30);

  final _client = http.Client();

  /// In-memory cache: jiosaavnSongId → (streamUrl, cachedAt).
  /// NOT persisted to disk — JioSaavn stream URLs expire.
  final _streamUrlCache = <String, _CachedUrl>{};

  /// The most recent error encountered by the service, if any.
  String? lastError;

  // ─── Private helpers ──────────────────────────────────────────────────────

  /// Performs a GET request to [path] with the given [queryParams].
  /// Returns the decoded JSON body, or null on any error.
  Future<Map<String, dynamic>?> _get(
    String path, {
    Map<String, String> queryParams = const {},
  }) async {
    final endpoint = JioSaavnConfig.baseUrl;
    try {
      final uri = Uri.parse(
        '$endpoint/$path',
      ).replace(queryParameters: queryParams);

      final response = await _client
          .get(
            uri,
            headers: {
              // A real browser User-Agent avoids 403s from the upstream JioSaavn
              // servers (fixed in jiosaavn-api v0.1.0, but keep for safety).
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 11; Pixel 5) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0.0.0 Mobile Safari/537.36',
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 429) {
        lastError = 'Rate limited (429)';
        logger.log('JioSaavn API: rate-limited (429). Backing off.');
        return null;
      }
      if (response.statusCode != 200) {
        lastError = 'HTTP ${response.statusCode}';
        logger.log('JioSaavn API: HTTP ${response.statusCode} for /$path');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        lastError = 'Unexpected response shape';
        logger.log('JioSaavn API: unexpected response shape for /$path');
        return null;
      }

      // The API wraps its payload in a `data` key at the top level.
      // Check for the `success` flag if present.
      final success = decoded['success'];
      if (success != null && success == false) {
        lastError = decoded['message']?.toString() ?? 'success=false';
        logger.log(
          'JioSaavn API: success=false for /$path '
          '(message: ${decoded['message'] ?? 'unknown'})',
        );
        return null;
      }

      lastError = null;
      return decoded;
    } on TimeoutException catch (e) {
      lastError = 'Timeout: $e';
      logger.log('JioSaavn API: timeout for /$path');
      return null;
    } on http.ClientException catch (e, st) {
      lastError = 'ClientException: $e';
      logger.log('JioSaavn API: network error', error: e, stackTrace: st);
      return null;
    } catch (e, st) {
      lastError = '$e';
      logger.log('JioSaavn API: error for /$path', error: e, stackTrace: st);
      return null;
    }
  }

  // ─── Public API ───────────────────────────────────────────────────────────

  /// Search for songs matching [query].
  ///
  /// Returns a list of raw song objects from the `data.results` array of the
  /// `/api/search/songs` endpoint.  Each object contains at minimum:
  ///   id, name, artists.primary, image, downloadUrl, duration.
  ///
  /// Returns an empty list on any error or if no results are found.
  Future<List<Map<String, dynamic>>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    if (query.trim().isEmpty) return [];

    final body = await _get(
      'api/search/songs',
      queryParams: {
        'query': query.trim(),
        'limit': limit.toString(),
        'page': page.toString(),
      },
    );

    final results = body?['data']?['results'];
    if (results is! List) return [];
    return results.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch one or more songs by their JioSaavn IDs.
  ///
  /// [ids] is a list of alphanumeric song IDs (e.g. `['3IoDK8qI']`).
  /// Returns a list of raw song objects from the `/api/songs` endpoint.
  Future<List<Map<String, dynamic>>> getSongsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];

    final body = await _get(
      'api/songs',
      queryParams: {'ids': ids.join(',')},
    );

    // The /api/songs response wraps results directly under 'data' as a list.
    final data = body?['data'];
    if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList();
    }
    return [];
  }

  /// Resolves the best available stream URL for [jiosaavnSongId].
  ///
  /// Results are cached for [_streamUrlCacheDuration].  If a cached entry is
  /// found and still fresh, it is returned without a network call.
  ///
  /// Returns null if the stream cannot be resolved.
  Future<String?> getStreamUrl(String jiosaavnSongId) async {
    // Check in-memory cache.
    final cached = _streamUrlCache[jiosaavnSongId];
    if (cached != null) {
      if (DateTime.now().difference(cached.cachedAt) < _streamUrlCacheDuration) {
        return cached.url;
      }
      _streamUrlCache.remove(jiosaavnSongId);
    }

    // Fetch from API.
    final songs = await getSongsByIds([jiosaavnSongId]);
    if (songs.isEmpty) {
      logger.log(
        'JioSaavn: getStreamUrl — no song found for id $jiosaavnSongId',
      );
      return null;
    }

    final url = _extractBestStreamUrl(songs.first);
    if (url == null || url.isEmpty) {
      logger.log(
        'JioSaavn: no stream URL in response for id $jiosaavnSongId',
      );
      return null;
    }

    _streamUrlCache[jiosaavnSongId] = _CachedUrl(url, DateTime.now());
    return url;
  }

  /// Invalidates the cached stream URL for [jiosaavnSongId].
  /// Call this when playback fails so the next attempt fetches a fresh URL.
  void invalidateStreamCache(String jiosaavnSongId) {
    _streamUrlCache.remove(jiosaavnSongId);
  }

  /// Clears the entire in-memory stream URL cache.
  void clearStreamCache() => _streamUrlCache.clear();

  // ─── Private helpers ──────────────────────────────────────────────────────

  /// Extracts the best stream URL from a raw song object.
  ///
  /// The API returns `downloadUrl` as a list of quality-keyed objects:
  ///   [ { "quality": "96kbps", "url": "..." }, { "quality": "320kbps", "url": "..." } ]
  ///
  /// We prefer [JioSaavnConfig.preferredQuality] and fall back through lower
  /// qualities, then return null if nothing is available.
  static String? _extractBestStreamUrl(Map<String, dynamic> song) {
    final downloadUrls = song['downloadUrl'];
    if (downloadUrls is! List || downloadUrls.isEmpty) return null;

    final qualityPreference = [
      JioSaavnConfig.preferredQuality,
      '160kbps',
      '96kbps',
      '48kbps',
      '12kbps',
    ];

    // Build a quality → url map.
    final urlMap = <String, String>{};
    for (final entry in downloadUrls) {
      if (entry is Map) {
        final q = entry['quality']?.toString() ?? '';
        final u = entry['url']?.toString() ?? '';
        if (q.isNotEmpty && u.isNotEmpty) {
          urlMap[q] = u;
        }
      }
    }

    for (final q in qualityPreference) {
      final url = urlMap[q];
      if (url != null && url.isNotEmpty) return url;
    }

    // Last resort: return the first non-empty URL.
    for (final entry in downloadUrls) {
      final url = entry['url']?.toString() ?? '';
      if (url.isNotEmpty) return url;
    }

    return null;
  }

  /// Extracts a single pre-resolved stream URL from a raw song object already
  /// returned by [searchSongs] or [getSongsByIds], without making another
  /// network call.  Returns null when no stream URL is available.
  static String? extractStreamUrlFromSong(Map<String, dynamic> song) =>
      _extractBestStreamUrl(song);
}

/// Internal in-memory cache entry.
class _CachedUrl {
  const _CachedUrl(this.url, this.cachedAt);
  final String url;
  final DateTime cachedAt;
}
