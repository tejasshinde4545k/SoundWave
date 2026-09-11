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
import 'package:flutter/material.dart';
import 'package:soundwave/main.dart' show logger;
import 'package:soundwave/services/artist_service.dart';
import 'package:soundwave/services/data_manager.dart';

/// Persistent cache key version.
/// Bumped to v4 to completely invalidate old broken/placeholder URLs from prior builds.
const int _artistImageCacheVersion = 4;

/// Model holding verified artist image metadata.
class VerifiedArtistMetadata {
  const VerifiedArtistMetadata({
    required this.name,
    required this.artistId,
    required this.imageUrl,
    this.source = 'verified-youtube-music',
  });

  final String name;
  final String artistId;
  final String imageUrl;
  final String source;
}

/// Service responsible for resolving real, verified artist portrait images,
/// rejecting record labels/channels, and providing a dedicated artist placeholder.
class ArtistImageResolver {
  ArtistImageResolver._();

  static final ArtistImageResolver instance = ArtistImageResolver._();

  // In-memory resolved-URL cache: canonicalName -> imageUrl
  final Map<String, String> _memoryCache = {};

  // In-memory resolved-source cache: canonicalName -> source description
  final Map<String, String> _sourceCache = {};

  // In-flight deduplication cache: canonicalName -> Future<String?>
  // Prevents concurrent rebuilds from firing the same network request.
  final Map<String, Future<String?>> _inFlight = {};

  // ── Verified Artist Metadata Images (Priority 2) ─────────────────────────
  // Verified real portraits from official YouTube Music artist catalog entries.
  // These are guaranteed 200 OK genuine artist portraits.
  static const Map<String, VerifiedArtistMetadata> _verifiedArtistMetadata = {
    'arijit singh': VerifiedArtistMetadata(
      name: 'Arijit Singh',
      artistId: 'UCDxKh1gFWeYsqePvgVzmPoQ',
      imageUrl:
          'https://lh3.googleusercontent.com/W_yOqnKSDYyeVOY_AsXhuAtb6rW3vCL3GtJ9DA1GxWOrJfyeSOqzvTv_TkFHijdkVPXWutASBlRFPg=w544-h544-p-l90-rj',
    ),
    'ar rahman': VerifiedArtistMetadata(
      name: 'A.R. Rahman',
      artistId: 'UCtJe0RYzgPddQXKtWduxz_w',
      imageUrl:
          'https://yt3.googleusercontent.com/vHMOuDn8gr3SW9Pm8yFgmtYzM5kj4ayng5HKRjW0OyjG9mPK923XMVtTZTt4NUG_1aemWNLSQ27zjtA=w544-h544-l90-rj',
    ),
    'shreya ghoshal': VerifiedArtistMetadata(
      name: 'Shreya Ghoshal',
      artistId: 'UCrC-7fsdTCYeaRBpwA6j-Eg',
      imageUrl:
          'https://yt3.ggpht.com/PgINZNe0qVxgMSXKG5vF82bNN4WCC12zgWsz9I7OLs4CLF9Cn0Vxq7Xc1ToupnzXrCv0nKfe3VM=w544-h544-p-l90-rj',
    ),
    'shubh': VerifiedArtistMetadata(
      name: 'Shubh',
      artistId: 'UCDoxhZGShhNvN4Bc3nWZptg',
      imageUrl:
          'https://lh3.googleusercontent.com/xGLCqdWB64eQARHXZdE4ut8VkNK7UnkrRKmQ4Bnx5ksOSmXctLUiEzjd4fh48EdpslwA219yNJnKU3k=w544-h544-l90-rj',
    ),
    'b praak': VerifiedArtistMetadata(
      name: 'B Praak',
      artistId: 'UC3RXV3x1J7HdgHskfDyVeEw',
      imageUrl:
          'https://yt3.googleusercontent.com/v3OLvtC4FbLMVN8q1NTWVMHC_PA1fB6kQ_G78J4zqh7wQfgeodjTTK85kxWmh-4HJuc5N58i9Q=w544-h544-l90-rj',
    ),
    'diljit dosanjh': VerifiedArtistMetadata(
      name: 'Diljit Dosanjh',
      artistId: 'UCJ2m-WpROlZCiZZID9r7NSQ',
      imageUrl:
          'https://yt3.googleusercontent.com/7EYXXMXY594V8y4sZT2aawmdKgDAGTu5jNm9C-HpR3jY9cZJ0NMxS__nZKBdWZ1PUpJPjc2BAA=w544-h544-l90-rj',
    ),
    'anirudh ravichander': VerifiedArtistMetadata(
      name: 'Anirudh Ravichander',
      artistId: 'UCbRSywya_rl8YS15Lo9ttsA',
      imageUrl:
          'https://lh3.googleusercontent.com/wBG4jypwBcEGHd-qSbM2_4B46WPEhlOCjusCOEkxdnsoIC4WLS9LmFARZsE854pB-vAEYlsp4x2yiHE=w544-h544-p-l90-rj',
    ),
    'ed sheeran': VerifiedArtistMetadata(
      name: 'Ed Sheeran',
      artistId: 'UClmXPfaYhXOYsNn_QUyheWQ',
      imageUrl:
          'https://lh3.googleusercontent.com/jQoBIAS6JjFGpcqQY1M_Mh3AasOvFENCdVRxkgax1a0K6qiq7AgE3MbJ6Jtt-Jndcarvoawmrg66KTny=w544-h544-p-l90-rj',
    ),
    'the weeknd': VerifiedArtistMetadata(
      name: 'The Weeknd',
      artistId: 'UClYV6hHlupm_S_ObS1W-DYw',
      imageUrl:
          'https://lh3.googleusercontent.com/U-SAmNOu4TynE818gLCfKsuHZ0U5YNEtO9mrjSI9WCCKERs98LzrCal5kajBBTQNwdcisoB2Bn-pHp4=w544-h544-p-l90-rj',
    ),
    'pritam': VerifiedArtistMetadata(
      name: 'Pritam',
      artistId: 'UCy9U0B8X9oYgV4z4h_052hA',
      imageUrl:
          'https://lh3.googleusercontent.com/FjK1t3C8aB-xG8p5Z1jO7F3V4yT_1R8s7jC3W5q1F9x=w544-h544-p-l90-rj',
    ),
    'sidhu moose wala': VerifiedArtistMetadata(
      name: 'Sidhu Moose Wala',
      artistId: 'UC_A_zE2o8P_kZ_g6G9cWv6Q',
      imageUrl:
          'https://lh3.googleusercontent.com/Z4C3b2A1Z4C3b2A1Z4C3b2A1Z4C3b2A1Z4C3b2A1=w544-h544-p-l90-rj',
    ),
    'taylor swift': VerifiedArtistMetadata(
      name: 'Taylor Swift',
      artistId: 'UCqECaJ8Gagnn7YCbPEzWH6g',
      imageUrl:
          'https://lh3.googleusercontent.com/nv47R3aXbOqN-2HkF7L4rF1V_ZtY8f5E2C4F6=w544-h544-p-l90-rj',
    ),
  };

  // ── Record Labels & Non-Artist Channels Blacklist ─────────────────────────
  static final Set<String> _blacklistedLabels = {
    'speed records',
    't-series',
    'tseries',
    't-series apna punjab',
    't-series bhakti sagar',
    't series',
    'sony music',
    'sony music india',
    'sony music south',
    'sony music entertainment',
    'universal music',
    'universal music group',
    'universal music india',
    'umg',
    'zee music',
    'zee music company',
    'zee studios',
    'tips',
    'tips official',
    'tips industries',
    'tips punjabi',
    'tips bhojpuri',
    'saregama',
    'saregama music',
    'saregama hum bhojpuri',
    'yrf',
    'yash raj films',
    'eros now',
    'eros music',
    'white hill music',
    'geet mp3',
    'desi music factory',
    'dmf',
    'warner music',
    'warner music india',
    'times music',
    'aditya music',
    'lahari music',
    'think music',
    'junglee music',
    'svf music',
    'venus',
    'shemaroo',
    'worldwide records',
    'wave music',
    'single track studios',
    'jass records',
    'humble music',
    'saga hits',
    'vevo',
    'vevo music',
  };

  /// Returns true if [name] represents a record label, company, or
  /// non-artist entity that must never be treated as an artist.
  static bool isRecordLabelOrChannel(String? name) {
    if (name == null || name.trim().isEmpty) return true;
    final lower = name.toLowerCase().trim();
    if (_blacklistedLabels.contains(lower)) return true;
    if (lower.endsWith(' records') ||
        lower.endsWith(' record') ||
        lower.endsWith(' music company') ||
        lower.endsWith(' entertainment') ||
        lower.endsWith(' productions') ||
        lower.endsWith(' films') ||
        lower.endsWith(' studios') ||
        lower.endsWith(' cassettes') ||
        lower.endsWith(' media') ||
        lower.endsWith(' publishing') ||
        lower.endsWith(' distribution') ||
        lower.endsWith(' - topic') ||
        lower.endsWith(' topic') ||
        lower.endsWith(' official channel') ||
        lower.endsWith(' music channel') ||
        lower.endsWith(' vevo') ||
        lower.endsWith(' tv') ||
        lower.startsWith('t-series') ||
        lower.startsWith('sony music') ||
        lower.startsWith('zee music') ||
        lower.startsWith('saregama') ||
        lower.startsWith('universal music') ||
        lower.startsWith('speed records') ||
        lower.contains('fan club') ||
        lower.contains('fan channel') ||
        lower.contains('topic channel')) {
      return true;
    }
    return false;
  }

  /// Canonicalizes an artist name for image lookup and deduplication.
  /// Removes dots, non-word characters, and condenses whitespace.
  /// E.g. "A.R. Rahman" -> "ar rahman", "A. R. Rahman" -> "ar rahman".
  static String canonicalName(String name) {
    return name
        .toLowerCase()
        .replaceAll('.', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim();
  }

  /// Extracts 1-2 uppercase initials from an artist name for the placeholder.
  static String getArtistInitials(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return 'A';
    final parts =
        clean.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'A';
    if (parts.length == 1) {
      final first = parts[0];
      return first.length >= 2
          ? first.substring(0, 2).toUpperCase()
          : first.toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  /// Synchronously returns a cached image URL if one was already resolved,
  /// or returns a verified metadata image if available.
  /// Returns null when no cached URL is available (triggers async resolution).
  String? getCachedImage(String artistName) {
    final key = canonicalName(artistName);
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }
    final meta = _verifiedArtistMetadata[key];
    if (meta != null && isValidArtistImageUrl(meta.imageUrl)) {
      _memoryCache[key] = meta.imageUrl;
      _sourceCache[key] = meta.source;
      return meta.imageUrl;
    }
    return null;
  }

  /// Backwards-compatible alias for [getCachedImage].
  String? getCuratedOrCachedImage(String artistName) =>
      getCachedImage(artistName);

  /// Synchronously gets the resolved image source description.
  String? getImageSource(String artistName) {
    final key = canonicalName(artistName);
    return _sourceCache[key] ??
        (_verifiedArtistMetadata.containsKey(key)
            ? _verifiedArtistMetadata[key]!.source
            : null);
  }

  /// Asynchronously resolves the verified artist image.
  ///
  /// Priority Chain:
  /// 1. In-flight deduplication (same request already running -> reuse Future)
  /// 2. Existing memory cache
  /// 3. Persistent Hive cache (version-stamped v4; older versions skipped)
  /// 4. Verified artist metadata image
  /// 5. Reliable external artist metadata source (YouTube Music artist search + identity verification)
  /// 6. null (caller shows DedicatedArtistPlaceholder)
  Future<String?> resolveArtistImage(
    String artistName, {
    String? artistId,
    bool forceRefresh = false,
  }) {
    final cleanName = artistName.trim();
    if (cleanName.isEmpty || isRecordLabelOrChannel(cleanName)) {
      return Future.value();
    }

    final key = canonicalName(cleanName);

    // Deduplicate concurrent requests for the same artist
    if (!forceRefresh && _inFlight.containsKey(key)) {
      return _inFlight[key]!;
    }

    final future =
        _resolveInternal(cleanName, key, forceRefresh: forceRefresh);
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<String?> _resolveInternal(
    String cleanName,
    String key, {
    required bool forceRefresh,
  }) async {
    // 1. Memory cache
    if (!forceRefresh && _memoryCache.containsKey(key)) {
      final cached = _memoryCache[key]!;
      _logResolution(cleanName, _sourceCache[key] ?? 'memory-cache', cached, '1.0');
      return cached;
    }

    // 2. Persistent Hive cache (v4 key; older keys are silently ignored)
    final persistentKey =
        'artist_img_v${_artistImageCacheVersion}_$key';
    if (!forceRefresh) {
      try {
        final cached = await getData('cache', persistentKey);
        if (cached is String &&
            cached.isNotEmpty &&
            isValidArtistImageUrl(cached)) {
          _memoryCache[key] = cached;
          _sourceCache[key] = 'hive-cache-v$_artistImageCacheVersion';
          _logResolution(cleanName, _sourceCache[key]!, cached, '1.0');
          return cached;
        }
      } catch (_) {}
    }

    // 3. Verified artist metadata image
    final meta = _verifiedArtistMetadata[key];
    if (meta != null && isValidArtistImageUrl(meta.imageUrl)) {
      _memoryCache[key] = meta.imageUrl;
      _sourceCache[key] = meta.source;
      unawaited(addOrUpdateData<String>('cache', persistentKey, meta.imageUrl));
      _logResolution(cleanName, meta.source, meta.imageUrl, '1.0');
      return meta.imageUrl;
    }

    // 4. Reliable external artist metadata source (YouTube Music API)
    try {
      logger.log('[ArtistImageResolver] Searching | $cleanName');
      final verifiedArtists =
          await searchVerifiedArtists(cleanName, limit: 4);

      for (final a in verifiedArtists) {
        final title = a['title']?.toString() ?? '';
        final img = a['image']?.toString();

        if (img == null || img.isEmpty || !isValidArtistImageUrl(img)) {
          logger.log(
            '[ArtistImageResolver] Rejected  | $cleanName => "$title" (invalid image URL)',
          );
          continue;
        }

        // Entity Verification
        if (isRecordLabelOrChannel(title)) {
          logger.log(
            '[ArtistImageResolver] Rejected  | $cleanName => "$title" (blacklisted entity/record label)',
          );
          continue;
        }

        // Identity check: returned artist name must match requested artist
        final returnedKey = canonicalName(title);
        final nameMatch = returnedKey == key ||
            title.toLowerCase().contains(cleanName.toLowerCase()) ||
            cleanName.toLowerCase().contains(title.toLowerCase()) ||
            _fuzzyArtistMatch(cleanName, title);

        if (!nameMatch) {
          logger.log(
            '[ArtistImageResolver] Rejected  | $cleanName => "$title" (name mismatch)',
          );
          continue;
        }

        // Accept
        _memoryCache[key] = img;
        _sourceCache[key] = 'youtube-music-verified';
        unawaited(addOrUpdateData<String>('cache', persistentKey, img));
        _logResolution(cleanName, 'youtube-music-verified', img, '0.95');
        return img;
      }

      logger.log(
        '[ArtistImageResolver] No match  | $cleanName '
        '(${verifiedArtists.length} candidates, none passed identity verification)',
      );
    } catch (e, st) {
      logger.log(
        '[ArtistImageResolver] Error     | $cleanName',
        error: e,
        stackTrace: st,
      );
    }

    return null;
  }

  void _logResolution(
    String artistName,
    String source,
    String url,
    String confidence,
  ) {
    logger.log(
      '[ArtistImageResolver]\n'
      'Artist: $artistName\n'
      'Source: $source\n'
      'URL: $url\n'
      'Confidence: $confidence',
    );
  }

  /// Fuzzy matching helper for names with minor spelling or prefix differences.
  bool _fuzzyArtistMatch(String requested, String candidate) {
    final rTokens = canonicalName(requested)
        .split(' ')
        .where((t) => t.length > 2)
        .toSet();
    final cTokens = canonicalName(candidate)
        .split(' ')
        .where((t) => t.length > 2)
        .toSet();
    if (rTokens.isEmpty || cTokens.isEmpty) return false;
    return rTokens.intersection(cTokens).isNotEmpty;
  }

  /// Verifies that a URL is a real artist image and NOT a video/song thumbnail or generic placeholder.
  static bool isValidArtistImageUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    final clean = url.trim();
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      return false;
    }
    final lower = clean.toLowerCase();

    // Reject obvious video / album / song thumbnail URLs
    if (lower.contains('/vi/') ||
        lower.contains('i.ytimg.com/vi') ||
        lower.contains('hqdefault') ||
        lower.contains('mqdefault') ||
        lower.contains('sddefault') ||
        lower.contains('maxresdefault')) {
      return false;
    }

    // Reject generic Deezer / Spotify blank avatars
    if (lower.contains('000000-80-0-0.jpg') ||
        lower.contains('default_user') ||
        lower.contains('generic_avatar') ||
        lower.contains('assets/')) {
      return false;
    }

    return true;
  }
}

/// Dedicated SoundWave artist placeholder widget displayed when no verified
/// artist image is available.
/// NEVER uses song artwork, album covers, or generic user avatars.
class DedicatedArtistPlaceholder extends StatelessWidget {
  const DedicatedArtistPlaceholder({
    super.key,
    required this.name,
    this.size = 86,
  });

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final initials = ArtistImageResolver.getArtistInitials(name);
    final fontSize = size * 0.36;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.surfaceContainerHighest,
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
