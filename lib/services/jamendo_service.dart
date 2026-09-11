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
import 'package:soundwave/config/jamendo_config.dart';
import 'package:soundwave/main.dart' show logger;

/// Jamendo REST API v3.0 client.
///
/// All stream URLs obtained via [getStreamUrl] are cached in-memory for up to
/// [_streamUrlCacheDuration] to avoid hammering the API, but are NEVER persisted
/// to disk because Jamendo stream URLs may expire.
///
/// Use the singleton [JamendoService.instance].
class JamendoService {
  JamendoService._();

  static final JamendoService instance = JamendoService._();

  static const Duration _timeout = Duration(seconds: 15);

  /// In-memory cache lifetime for stream URLs. Short enough that URLs don't
  /// expire between preload and actual play, long enough to avoid redundant
  /// API calls for songs that appear multiple times in a queue.
  static const Duration _streamUrlCacheDuration = Duration(minutes: 30);

  final _client = http.Client();

  /// In-memory cache: jamendoId → (streamUrl, cachedAt).
  /// NOT persisted to disk — Jamendo stream URLs can expire.
  final _streamUrlCache = <String, _CachedUrl>{};

  // ─── Private helpers ────────────────────────────────────────────────────────

  Uri _buildUri(String path, Map<String, String> params) {
    return Uri.parse('${JamendoConfig.baseUrl}/$path/').replace(
      queryParameters: {
        'client_id': JamendoConfig.clientId,
        'format': 'json',
        ...params,
      },
    );
  }

  Future<Map<String, dynamic>?> _get(
    String path,
    Map<String, String> params,
  ) async {
    try {
      if (JamendoConfig.clientId == 'YOUR_JAMENDO_CLIENT_ID' ||
          JamendoConfig.clientId.isEmpty) {
        logger.log(
          'Jamendo: client_id is not configured. '
          'Edit lib/config/jamendo_config.dart and set your real client_id.',
        );
        return null;
      }

      final uri = _buildUri(path, params);
      final response = await _client.get(uri).timeout(_timeout);

      if (response.statusCode == 429) {
        logger.log('Jamendo API rate limit exceeded (429). Retry later.');
        return null;
      }

      if (response.statusCode != 200) {
        logger.log('Jamendo API HTTP ${response.statusCode} for /$path');
        return null;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        logger.log('Jamendo API unexpected response type for /$path');
        return null;
      }

      final headers = data['headers'];
      if (headers is Map && headers['status'] == 'failed') {
        logger.log(
          'Jamendo API error: ${headers['error_message'] ?? 'unknown'}',
        );
        return null;
      }

      return data;
    } on TimeoutException {
      logger.log('Jamendo API timeout for /$path');
      return null;
    } on http.ClientException catch (e, st) {
      logger.log('Jamendo network error', error: e, stackTrace: st);
      return null;
    } catch (e, st) {
      logger.log('Jamendo API error for /$path', error: e, stackTrace: st);
      return null;
    }
  }

  // ─── Public API methods ──────────────────────────────────────────────────────

  /// Search for tracks by name, artist, or any text query.
  ///
  /// Returns a list of raw Jamendo API track objects. Convert them to the app's
  /// song map format using `returnJamendoSongLayout` in formatter.dart.
  Future<List<Map<String, dynamic>>> searchTracks(
    String query, {
    int limit = 20,
    String? tag,
  }) async {
    if (query.trim().isEmpty) return [];

    final params = <String, String>{
      'limit': limit.toString(),
      'namesearch': query.trim(),
      'include': 'musicinfo',
      'audioformat': 'mp32',
      'order': 'popularity_total',
    };

    if (tag != null && tag.isNotEmpty) {
      params['tags'] = tag;
    }

    final data = await _get('tracks', params);
    final results = data?['results'];
    if (results is! List) return [];
    return results.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch popular tracks on Jamendo.
  /// Used as a fallback when a specific artist or search query yields no results on Jamendo.
  Future<List<Map<String, dynamic>>> getPopularTracks({
    int limit = 20,
    String? tag,
  }) async {
    final params = <String, String>{
      'limit': limit.toString(),
      'include': 'musicinfo',
      'audioformat': 'mp32',
      'order': 'popularity_total',
    };

    if (tag != null && tag.isNotEmpty) {
      params['tags'] = tag;
    }

    final data = await _get('tracks', params);
    final results = data?['results'];
    if (results is! List) return [];
    return results.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch a single track by its Jamendo numeric ID.
  Future<Map<String, dynamic>?> getTrack(String jamendoId) async {
    final data = await _get('tracks', {
      'id': jamendoId,
      'include': 'musicinfo',
      'audioformat': 'mp32',
    });

    final results = data?['results'];
    if (results is! List || results.isEmpty) return null;
    final first = results.first;
    return first is Map<String, dynamic> ? first : null;
  }

  /// Fetch multiple tracks by their Jamendo numeric IDs.
  Future<List<Map<String, dynamic>>> getTracks(List<String> ids) async {
    if (ids.isEmpty) return [];

    final data = await _get('tracks', {
      'id': ids.join('+'),
      'include': 'musicinfo',
      'audioformat': 'mp32',
    });

    final results = data?['results'];
    if (results is! List) return [];
    return results.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch the direct audio streaming URL for a Jamendo track.
  ///
  /// Results are cached in-memory for [_streamUrlCacheDuration].
  /// Expired or missing cache entries trigger a fresh API call.
  ///
  /// Returns `null` if the track cannot be resolved, the API is unavailable,
  /// or the client_id is not configured.
  Future<String?> getStreamUrl(String jamendoId) async {
    // Check in-memory cache.
    final cached = _streamUrlCache[jamendoId];
    if (cached != null) {
      final age = DateTime.now().difference(cached.cachedAt);
      if (age < _streamUrlCacheDuration) {
        return cached.url;
      }
      _streamUrlCache.remove(jamendoId);
    }

    // Fetch fresh from API.
    final track = await getTrack(jamendoId);
    if (track == null) {
      logger.log('Jamendo: getStreamUrl — track not found for id $jamendoId');
      return null;
    }

    final audioUrl = track['audio']?.toString();
    if (audioUrl == null || audioUrl.isEmpty) {
      logger.log('Jamendo: no audio URL in API response for track $jamendoId');
      return null;
    }

    _streamUrlCache[jamendoId] = _CachedUrl(audioUrl, DateTime.now());
    return audioUrl;
  }

  /// Search albums by name.
  Future<List<Map<String, dynamic>>> getAlbums(
    String query, {
    int limit = 10,
  }) async {
    if (query.trim().isEmpty) return [];

    final data = await _get('albums', {
      'namesearch': query.trim(),
      'limit': limit.toString(),
    });

    final results = data?['results'];
    if (results is! List) return [];
    return results.whereType<Map<String, dynamic>>().toList();
  }

  /// Search artists by name.
  Future<List<Map<String, dynamic>>> getArtists(
    String query, {
    int limit = 10,
  }) async {
    if (query.trim().isEmpty) return [];

    final data = await _get('artists', {
      'namesearch': query.trim(),
      'limit': limit.toString(),
    });

    final results = data?['results'];
    if (results is! List) return [];
    return results.whereType<Map<String, dynamic>>().toList();
  }

  /// Invalidate the in-memory stream URL cache for a specific track.
  /// Call this when playback fails so the next attempt fetches a fresh URL.
  void invalidateStreamCache(String jamendoId) {
    _streamUrlCache.remove(jamendoId);
  }

  /// Clear the entire in-memory stream URL cache.
  void clearStreamCache() => _streamUrlCache.clear();
}

/// Internal cache entry.
class _CachedUrl {
  const _CachedUrl(this.url, this.cachedAt);
  final String url;
  final DateTime cachedAt;
}
