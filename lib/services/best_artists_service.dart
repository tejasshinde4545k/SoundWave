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

import 'dart:math' as math;

import 'package:hive/hive.dart';
import 'package:soundwave/main.dart' show logger;
import 'package:soundwave/services/artist_image_resolver.dart';
import 'package:soundwave/services/common_services.dart'
    show userLikedSongsList, userRecentlyPlayed;
import 'package:soundwave/services/music_region_service.dart';
import 'package:soundwave/services/playlists_manager.dart'
    show isArtistPlaylist, userLikedPlaylists;

/// Typed artist representation supporting explicit separation of artist identity
/// and artist portrait image data.
class SoundWaveArtistModel {
  const SoundWaveArtistModel({
    required this.artistId,
    required this.artistName,
    this.artistImageUrl,
    this.artistImageSource,
  });

  factory SoundWaveArtistModel.fromMap(Map<dynamic, dynamic> map) {
    return SoundWaveArtistModel(
      artistId: map['ytid']?.toString() ?? map['artistId']?.toString() ?? '',
      artistName: map['title']?.toString() ?? map['artistName']?.toString() ?? '',
      artistImageUrl: map['image']?.toString() ?? map['artistImageUrl']?.toString(),
      artistImageSource: map['artistImageSource']?.toString(),
    );
  }

  final String artistId;
  final String artistName;
  final String? artistImageUrl;
  final String? artistImageSource;

  Map<String, dynamic> toMap() => {
    'ytid': artistId,
    'title': artistName,
    'image': artistImageUrl,
    'artistImageSource': artistImageSource ?? 'unresolved',
    'isArtist': true,
    'source': 'youtube-artist',
  };
}

/// Definition of a country-level popular artist candidate.
class CountryArtistCandidate {
  const CountryArtistCandidate({
    required this.name,
    required this.languageCode,
    required this.popularityScore,
    this.primaryGenre = 'Music',
    this.imageUrl,
    this.artistId,
  });

  final String name;
  final String languageCode;
  final double popularityScore;
  final String primaryGenre;
  final String? imageUrl;
  final String? artistId;
}

/// Service that computes the hybrid personalized + country-popularity
/// "Best Artists" ranking for the SoundWave Home screen.
class BestArtistsService {
  BestArtistsService._();

  /// Singleton instance.
  static final BestArtistsService instance = BestArtistsService._();

  // In-memory cache: cacheKey -> List<Map<String, dynamic>>
  final Map<String, List<Map<String, dynamic>>> _memoryCache = {};

  // ── India Country Artist Pool ──────────────────────────────────────────────
  // Major Indian artists across Hindi, Punjabi, Marathi, Tamil, Telugu,
  // Bengali, Kannada, Malayalam, Gujarati, and Bhojpuri.
  static const List<CountryArtistCandidate> indiaArtistPool = [
    // Hindi
    CountryArtistCandidate(
      name: 'Arijit Singh',
      languageCode: 'hi',
      popularityScore: 98,
      primaryGenre: 'Bollywood',
      artistId: 'UCDxKh1gFWeYsqePvgVzmPoQ',
      imageUrl:
          'https://lh3.googleusercontent.com/W_yOqnKSDYyeVOY_AsXhuAtb6rW3vCL3GtJ9DA1GxWOrJfyeSOqzvTv_TkFHijdkVPXWutASBlRFPg=w544-h544-p-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Shreya Ghoshal',
      languageCode: 'hi',
      popularityScore: 95,
      primaryGenre: 'Bollywood',
      artistId: 'UCrC-7fsdTCYeaRBpwA6j-Eg',
      imageUrl:
          'https://yt3.ggpht.com/PgINZNe0qVxgMSXKG5vF82bNN4WCC12zgWsz9I7OLs4CLF9Cn0Vxq7Xc1ToupnzXrCv0nKfe3VM=w544-h544-p-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'A.R. Rahman',
      languageCode: 'hi',
      popularityScore: 96,
      primaryGenre: 'Soundtrack',
      artistId: 'UCtJe0RYzgPddQXKtWduxz_w',
      imageUrl:
          'https://yt3.googleusercontent.com/vHMOuDn8gr3SW9Pm8yFgmtYzM5kj4ayng5HKRjW0OyjG9mPK923XMVtTZTt4NUG_1aemWNLSQ27zjtA=w544-h544-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Pritam',
      languageCode: 'hi',
      popularityScore: 94,
      primaryGenre: 'Bollywood',
    ),
    CountryArtistCandidate(
      name: 'Sonu Nigam',
      languageCode: 'hi',
      popularityScore: 92,
      primaryGenre: 'Bollywood',
    ),
    CountryArtistCandidate(
      name: 'Badshah',
      languageCode: 'hi',
      popularityScore: 88,
      primaryGenre: 'Desi Hip-Hop',
    ),
    CountryArtistCandidate(
      name: 'Neha Kakkar',
      languageCode: 'hi',
      popularityScore: 88,
      primaryGenre: 'Bollywood',
    ),
    CountryArtistCandidate(
      name: 'Jubin Nautiyal',
      languageCode: 'hi',
      popularityScore: 87,
      primaryGenre: 'Bollywood',
    ),
    CountryArtistCandidate(
      name: 'Anuv Jain',
      languageCode: 'hi',
      popularityScore: 85,
      primaryGenre: 'Indie',
    ),
    CountryArtistCandidate(
      name: 'KK',
      languageCode: 'hi',
      popularityScore: 89,
      primaryGenre: 'Bollywood',
    ),
    CountryArtistCandidate(
      name: 'Darshan Raval',
      languageCode: 'hi',
      popularityScore: 85,
      primaryGenre: 'Pop',
    ),

    // Punjabi
    CountryArtistCandidate(
      name: 'Diljit Dosanjh',
      languageCode: 'pa',
      popularityScore: 94,
      primaryGenre: 'Punjabi',
      artistId: 'UCJ2m-WpROlZCiZZID9r7NSQ',
      imageUrl:
          'https://yt3.googleusercontent.com/7EYXXMXY594V8y4sZT2aawmdKgDAGTu5jNm9C-HpR3jY9cZJ0NMxS__nZKBdWZ1PUpJPjc2BAA=w544-h544-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Sidhu Moose Wala',
      languageCode: 'pa',
      popularityScore: 93,
      primaryGenre: 'Punjabi Hip-Hop',
    ),
    CountryArtistCandidate(
      name: 'Karan Aujla',
      languageCode: 'pa',
      popularityScore: 91,
      primaryGenre: 'Punjabi',
    ),
    CountryArtistCandidate(
      name: 'AP Dhillon',
      languageCode: 'pa',
      popularityScore: 89,
      primaryGenre: 'Punjabi Pop',
    ),
    CountryArtistCandidate(
      name: 'B Praak',
      languageCode: 'pa',
      popularityScore: 88,
      primaryGenre: 'Punjabi',
      artistId: 'UC3RXV3x1J7HdgHskfDyVeEw',
      imageUrl:
          'https://yt3.googleusercontent.com/v3OLvtC4FbLMVN8q1NTWVMHC_PA1fB6kQ_G78J4zqh7wQfgeodjTTK85kxWmh-4HJuc5N58i9Q=w544-h544-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Shubh',
      languageCode: 'pa',
      popularityScore: 88,
      primaryGenre: 'Punjabi',
      artistId: 'UCDoxhZGShhNvN4Bc3nWZptg',
      imageUrl:
          'https://lh3.googleusercontent.com/xGLCqdWB64eQARHXZdE4ut8VkNK7UnkrRKmQ4Bnx5ksOSmXctLUiEzjd4fh48EdpslwA219yNJnKU3k=w544-h544-l90-rj',
    ),

    // Marathi
    CountryArtistCandidate(
      name: 'Ajay-Atul',
      languageCode: 'mr',
      popularityScore: 90,
      primaryGenre: 'Marathi',
    ),
    CountryArtistCandidate(
      name: 'Avdhoot Gupte',
      languageCode: 'mr',
      popularityScore: 82,
      primaryGenre: 'Marathi',
    ),
    CountryArtistCandidate(
      name: 'Swapnil Bandodkar',
      languageCode: 'mr',
      popularityScore: 80,
      primaryGenre: 'Marathi',
    ),
    CountryArtistCandidate(
      name: 'Arya Ambekar',
      languageCode: 'mr',
      popularityScore: 79,
      primaryGenre: 'Marathi',
    ),

    // Tamil
    CountryArtistCandidate(
      name: 'Anirudh Ravichander',
      languageCode: 'ta',
      popularityScore: 95,
      primaryGenre: 'Kollywood',
      artistId: 'UCbRSywya_rl8YS15Lo9ttsA',
      imageUrl:
          'https://lh3.googleusercontent.com/wBG4jypwBcEGHd-qSbM2_4B46WPEhlOCjusCOEkxdnsoIC4WLS9LmFARZsE854pB-vAEYlsp4x2yiHE=w544-h544-p-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Sid Sriram',
      languageCode: 'ta',
      popularityScore: 90,
      primaryGenre: 'Carnatic / Pop',
    ),
    CountryArtistCandidate(
      name: 'Yuvan Shankar Raja',
      languageCode: 'ta',
      popularityScore: 88,
      primaryGenre: 'Kollywood',
    ),
    CountryArtistCandidate(
      name: 'Ilaiyaraaja',
      languageCode: 'ta',
      popularityScore: 91,
      primaryGenre: 'Soundtrack',
    ),

    // Telugu
    CountryArtistCandidate(
      name: 'Devi Sri Prasad (DSP)',
      languageCode: 'te',
      popularityScore: 90,
      primaryGenre: 'Tollywood',
    ),
    CountryArtistCandidate(
      name: 'S. Thaman',
      languageCode: 'te',
      popularityScore: 89,
      primaryGenre: 'Tollywood',
    ),
    CountryArtistCandidate(
      name: 'M.M. Keeravani',
      languageCode: 'te',
      popularityScore: 88,
      primaryGenre: 'Tollywood',
    ),

    // Bengali
    CountryArtistCandidate(
      name: 'Anupam Roy',
      languageCode: 'bn',
      popularityScore: 86,
      primaryGenre: 'Bengali',
    ),
    CountryArtistCandidate(
      name: 'Rupam Islam',
      languageCode: 'bn',
      popularityScore: 82,
      primaryGenre: 'Bengali Rock',
    ),

    // Kannada
    CountryArtistCandidate(
      name: 'Sanjith Hegde',
      languageCode: 'kn',
      popularityScore: 84,
      primaryGenre: 'Kannada',
    ),
    CountryArtistCandidate(
      name: 'Ravi Basrur',
      languageCode: 'kn',
      popularityScore: 85,
      primaryGenre: 'Kannada',
    ),

    // Malayalam
    CountryArtistCandidate(
      name: 'Sushin Shyam',
      languageCode: 'ml',
      popularityScore: 87,
      primaryGenre: 'Malayalam',
    ),
    CountryArtistCandidate(
      name: 'Hesham Abdul Wahab',
      languageCode: 'ml',
      popularityScore: 85,
      primaryGenre: 'Malayalam',
    ),

    // Gujarati
    CountryArtistCandidate(
      name: 'Kinjal Dave',
      languageCode: 'gu',
      popularityScore: 82,
      primaryGenre: 'Gujarati Folk',
    ),
    CountryArtistCandidate(
      name: 'Geeta Rabari',
      languageCode: 'gu',
      popularityScore: 82,
      primaryGenre: 'Gujarati',
    ),

    // Bhojpuri
    CountryArtistCandidate(
      name: 'Pawan Singh',
      languageCode: 'bho',
      popularityScore: 84,
      primaryGenre: 'Bhojpuri',
    ),
  ];

  // ── Global Country Artist Pool ─────────────────────────────────────────────
  static const List<CountryArtistCandidate> globalArtistPool = [
    CountryArtistCandidate(
      name: 'Taylor Swift',
      languageCode: 'en',
      popularityScore: 98,
      primaryGenre: 'Pop',
    ),
    CountryArtistCandidate(
      name: 'The Weeknd',
      languageCode: 'en',
      popularityScore: 96,
      primaryGenre: 'R&B / Pop',
      artistId: 'UClYV6hHlupm_S_ObS1W-DYw',
      imageUrl:
          'https://lh3.googleusercontent.com/U-SAmNOu4TynE818gLCfKsuHZ0U5YNEtO9mrjSI9WCCKERs98LzrCal5kajBBTQNwdcisoB2Bn-pHp4=w544-h544-p-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Drake',
      languageCode: 'en',
      popularityScore: 95,
      primaryGenre: 'Hip-Hop',
    ),
    CountryArtistCandidate(
      name: 'Billie Eilish',
      languageCode: 'en',
      popularityScore: 93,
      primaryGenre: 'Alt-Pop',
    ),
    CountryArtistCandidate(
      name: 'Ed Sheeran',
      languageCode: 'en',
      popularityScore: 94,
      primaryGenre: 'Pop',
      artistId: 'UClmXPfaYhXOYsNn_QUyheWQ',
      imageUrl:
          'https://lh3.googleusercontent.com/jQoBIAS6JjFGpcqQY1M_Mh3AasOvFENCdVRxkgax1a0K6qiq7AgE3MbJ6Jtt-Jndcarvoawmrg66KTny=w544-h544-p-l90-rj',
    ),
    CountryArtistCandidate(
      name: 'Ariana Grande',
      languageCode: 'en',
      popularityScore: 92,
      primaryGenre: 'Pop',
    ),
    CountryArtistCandidate(
      name: 'Bruno Mars',
      languageCode: 'en',
      popularityScore: 93,
      primaryGenre: 'Pop / Funk',
    ),
    CountryArtistCandidate(
      name: 'Coldplay',
      languageCode: 'en',
      popularityScore: 91,
      primaryGenre: 'Rock / Pop',
    ),
    CountryArtistCandidate(
      name: 'Kendrick Lamar',
      languageCode: 'en',
      popularityScore: 91,
      primaryGenre: 'Hip-Hop',
    ),
    CountryArtistCandidate(
      name: 'Dua Lipa',
      languageCode: 'en',
      popularityScore: 90,
      primaryGenre: 'Pop',
    ),
    CountryArtistCandidate(
      name: 'Eminem',
      languageCode: 'en',
      popularityScore: 92,
      primaryGenre: 'Hip-Hop',
    ),
  ];

  // ── Public Best Artists Resolver ───────────────────────────────────────────

  /// Computes and returns the ranked hybrid list of Best Artists.
  Future<List<Map<String, dynamic>>> getBestArtists({
    String? regionCode,
    UserMusicProfile? userProfileOverride,
    List<dynamic>? recentlyPlayedOverride,
    List<dynamic>? likedSongsOverride,
    List<Map>? likedPlaylistsOverride,
    bool forceRefresh = false,
    int limit = 15,
  }) async {
    final effectiveRegion =
        regionCode ?? MusicRegionService.instance.getActiveRegionCode();
    final cacheKey = 'best_artists_$effectiveRegion';

    if (!forceRefresh && _memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey]!;
    }

    final recent = recentlyPlayedOverride ?? userRecentlyPlayed.value;
    final liked = likedSongsOverride ?? userLikedSongsList.value;
    final followedPlaylists =
        likedPlaylistsOverride ?? userLikedPlaylists.value;

    final profile = userProfileOverride ??
        MusicRegionService.instance.analyzeUserProfile(
          recentlyPlayed: recent,
          likedSongs: liked,
        );

    final ranked = computeRankedArtists(
      regionCode: effectiveRegion,
      userProfile: profile,
      recentlyPlayed: recent,
      likedSongs: liked,
      followedPlaylists: followedPlaylists,
      limit: limit,
    );

    // Resolve real artist images concurrently (not sequentially) to keep
    // the Home screen fast. Only artists that still have no image after
    // the synchronous pass go to the network.
    final resolveTasks = <Future<void>>[];
    for (final artist in ranked) {
      final name = artist['title']?.toString() ?? '';
      final existingImage = artist['image']?.toString();
      final needsResolution =
          existingImage == null || existingImage.isEmpty;
      if (needsResolution) {
        resolveTasks.add(() async {
          final img =
              await ArtistImageResolver.instance.resolveArtistImage(name);
          if (img != null && img.isNotEmpty) {
            artist['image'] = img;
            artist['artistImageSource'] =
                ArtistImageResolver.instance.getImageSource(name) ??
                    'youtube-music-verified';
          }
        }());
      }
    }
    if (resolveTasks.isNotEmpty) {
      await Future.wait(resolveTasks);
    }

    // Temporary debug logging for every Best Artist as required:
    for (final artist in ranked) {
      final aName = artist['title']?.toString() ?? '';
      final aId = artist['ytid']?.toString() ?? '';
      final aImg = artist['image']?.toString();
      final aSource = artist['artistImageSource']?.toString() ??
          (aImg != null ? 'verified-metadata' : 'none');
      final aStatus =
          (aImg != null && aImg.isNotEmpty) ? 'resolved' : 'fallback-initials';
      logger.log(
        '[BestArtists]\n'
        'Artist: $aName\n'
        'Artist ID: $aId\n'
        'Image URL: $aImg\n'
        'Image source: $aSource\n'
        'Image status: $aStatus',
      );
    }

    // On a forced refresh, clear the old entry before writing the new one
    // so there's no window where stale data can be re-read.
    if (forceRefresh) _memoryCache.remove(cacheKey);
    _memoryCache[cacheKey] = ranked;
    _saveToPersistentCache(cacheKey, ranked);

    return ranked;
  }

  /// Synchronously computes the ranked list of artists based on inputs.
  /// Pure function for deterministic testing and instant rendering.
  List<Map<String, dynamic>> computeRankedArtists({
    required String regionCode,
    required UserMusicProfile userProfile,
    List<dynamic> recentlyPlayed = const [],
    List<dynamic> likedSongs = const [],
    List<Map> followedPlaylists = const [],
    int limit = 15,
  }) {
    final artistStats = <String, _ArtistScoreAccumulator>{};
    final artistArtworkMap = <String, String>{};

    // Helper to get or create an accumulator by canonical name
    _ArtistScoreAccumulator? getAccumulator(String rawName) {
      final clean = rawName.trim();
      if (clean.isEmpty || ArtistImageResolver.isRecordLabelOrChannel(clean)) {
        return null;
      }
      final canonical = _normalizeArtistName(clean);
      if (!artistStats.containsKey(canonical)) {
        artistStats[canonical] = _ArtistScoreAccumulator(
          displayName: clean,
          canonicalName: canonical,
        );
      }
      return artistStats[canonical];
    }

    // 1. Process Recently Played Songs
    final recentCount = recentlyPlayed.length;
    for (var i = 0; i < recentCount; i++) {
      final item = recentlyPlayed[i];
      if (item is! Map) continue;
      final rawArtist = item['artist']?.toString() ?? '';
      if (rawArtist.trim().isEmpty ||
          ArtistImageResolver.isRecordLabelOrChannel(rawArtist)) {
        continue;
      }

      final acc = getAccumulator(rawArtist);
      if (acc == null) continue;
      acc.recentPlayCount++;
      // Earlier in list = more recent
      if (i < 5) acc.isRecentTop5 = true;

      // NEVER use song image for artist artwork!
      // Instead, resolve real artist image from curated or cached portraits.
      final artistImg = ArtistImageResolver.instance
          .getCuratedOrCachedImage(acc.displayName);
      if (artistImg != null &&
          !artistArtworkMap.containsKey(acc.canonicalName)) {
        artistArtworkMap[acc.canonicalName] = artistImg;
      }
    }

    // 2. Process Liked Songs
    for (final item in likedSongs) {
      if (item is! Map) continue;
      final rawArtist = item['artist']?.toString() ?? '';
      if (rawArtist.trim().isEmpty ||
          ArtistImageResolver.isRecordLabelOrChannel(rawArtist)) {
        continue;
      }

      final acc = getAccumulator(rawArtist);
      if (acc == null) continue;
      acc.likedSongCount++;

      // NEVER use song image for artist artwork!
      final artistImg = ArtistImageResolver.instance
          .getCuratedOrCachedImage(acc.displayName);
      if (artistImg != null &&
          !artistArtworkMap.containsKey(acc.canonicalName)) {
        artistArtworkMap[acc.canonicalName] = artistImg;
      }
    }

    // 3. Process Followed / Liked Artists
    for (final p in followedPlaylists) {
      if (!isArtistPlaylist(p)) continue;
      final rawName = p['title']?.toString() ?? '';
      if (rawName.trim().isEmpty ||
          ArtistImageResolver.isRecordLabelOrChannel(rawName)) {
        continue;
      }

      final acc = getAccumulator(rawName);
      if (acc == null) continue;
      acc.isFollowed = true;

      final artistImg = ArtistImageResolver.instance
          .getCuratedOrCachedImage(acc.displayName);
      if (artistImg != null) {
        artistArtworkMap[acc.canonicalName] = artistImg;
      }
    }

    // 4. Inject Country Popularity Pool
    final countryPool =
        (regionCode == 'IN') ? indiaArtistPool : globalArtistPool;

    for (final candidate in countryPool) {
      if (ArtistImageResolver.isRecordLabelOrChannel(candidate.name)) continue;
      final acc = getAccumulator(candidate.name);
      if (acc == null) continue;
      acc
        ..countryPopularity = candidate.popularityScore
        ..languageCode = candidate.languageCode
        ..isCountryCandidate = true;
      if (candidate.artistId != null) {
        acc.artistId = candidate.artistId;
      }

      final curatedImg = candidate.imageUrl ??
          ArtistImageResolver.instance.getCuratedOrCachedImage(candidate.name);

      if (curatedImg != null &&
          curatedImg.isNotEmpty &&
          !artistArtworkMap.containsKey(acc.canonicalName)) {
        artistArtworkMap[acc.canonicalName] = curatedImg;
      }
    }

    // 5. Calculate Final Hybrid Scores
    final scoredArtists = <Map<String, dynamic>>[];

    for (final acc in artistStats.values) {
      var score = 0.0;

      // A. Personal Listening Score (Strongest Signal: up to 60 pts)
      // Logarithmic scaling so heavy users don't break normalization
      final totalUserInteractions =
          acc.recentPlayCount + (acc.likedSongCount * 2);
      if (totalUserInteractions > 0) {
        // Base log score + linear bonus
        final logPart = math.log(totalUserInteractions + 1.0) * 12.0;
        final linearPart = math.min(25, totalUserInteractions * 2.0);
        score += math.min(60.0, logPart + linearPart);
      }

      // B. Liked Artist / Followed Bonus (+25 pts)
      if (acc.isFollowed) {
        score += 25.0;
      }

      // C. Recent listening bonus (+10 pts)
      if (acc.isRecentTop5) {
        score += 10.0;
      }

      // D. UserMusicProfile Artist Affinity (+15 pts)
      if (userProfile.hasArtist(acc.displayName)) {
        score += 15.0;
      }

      // E. Country Popularity Score (scaled to max 35 pts)
      if (acc.isCountryCandidate) {
        // e.g. Arijit Singh (98/100) -> ~34.3 pts
        score += (acc.countryPopularity / 100.0) * 35.0;
      }

      // F. Regional Language Bonus (from MusicRegionService)
      if (regionCode == 'IN' && acc.languageCode != null) {
        final langAffinity =
            userProfile.getAffinityForLanguage(acc.languageCode!);
        if (langAffinity > 0.15) {
          // Boost artists in the specific regional language user listens to
          score += 25.0 * (1.0 + langAffinity);
        } else if (userProfile.isColdStart) {
          // Cold start baseline
          if (acc.languageCode == 'hi') score += 10.0;
          if (acc.languageCode == 'pa') score += 6.0;
          if (acc.languageCode == 'mr') score += 5.0;
        }
      }

      // G. Country Discovery Guarantee
      // Ensures popular artists like Arijit Singh remain discoverable
      // even if the user has never listened to them.
      if (acc.isCountryCandidate && totalUserInteractions == 0) {
        score += 12.0;
      }

      final artistImg = artistArtworkMap[acc.canonicalName] ??
          ArtistImageResolver.instance.getCuratedOrCachedImage(acc.displayName);

      final source = artistImg != null
          ? (ArtistImageResolver.instance.getImageSource(acc.displayName) ??
              'verified-metadata')
          : 'unresolved';

      scoredArtists.add({
        'title': acc.displayName,
        'image': artistImg,
        'ytid': acc.artistId ?? acc.displayName,
        'isArtist': true,
        'source': 'youtube-artist',
        'artistImageSource': source,
        'score': score,
        'hasUserHistory': totalUserInteractions > 0 || acc.isFollowed,
      });
    }

    // Sort descending by calculated hybrid score
    scoredArtists.sort((a, b) {
      final sA = a['score'] as double;
      final sB = b['score'] as double;
      return sB.compareTo(sA);
    });

    // 6. Balanced Candidate Mixing (Diversity & Echo Chamber Prevention)
    // If user has history, ensure at least 30-40% country discovery artists
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addArtist(Map<String, dynamic> a) {
      final name = a['title']?.toString() ?? '';
      if (ArtistImageResolver.isRecordLabelOrChannel(name)) return;
      final key = _normalizeArtistName(name);
      if (seen.add(key)) {
        result.add(a);
      }
    }

    if (userProfile.isColdStart || recentlyPlayed.isEmpty) {
      // 100% Country & Regional Popularity for new users
      for (final a in scoredArtists) {
        addArtist(a);
        if (result.length >= limit) break;
      }
    } else {
      // Personalized users: take top personalized, blend in top country discovery
      final personalizedList =
          scoredArtists.where((a) => a['hasUserHistory'] == true).toList();
      final discoveryList =
          scoredArtists.where((a) => a['hasUserHistory'] != true).toList();

      var pIndex = 0;
      var dIndex = 0;

      while (result.length < limit &&
          (pIndex < personalizedList.length || dIndex < discoveryList.length)) {
        // Add up to 2 personalized artists
        for (var i = 0; i < 2 && pIndex < personalizedList.length; i++) {
          addArtist(personalizedList[pIndex++]);
          if (result.length >= limit) break;
        }
        // Add 1 country discovery artist
        if (dIndex < discoveryList.length && result.length < limit) {
          addArtist(discoveryList[dIndex++]);
        }
      }

      // If still slots remaining, fill from general scored list
      for (final a in scoredArtists) {
        if (result.length >= limit) break;
        addArtist(a);
      }
    }

    return result;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _normalizeArtistName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void _saveToPersistentCache(String key, List<Map<String, dynamic>> artists) {
    try {
      Hive.box('userNoBackup').put('ba_$key', artists);
    } catch (_) {}
  }
}

class _ArtistScoreAccumulator {
  _ArtistScoreAccumulator({
    required this.displayName,
    required this.canonicalName,
  });

  final String displayName;
  final String canonicalName;
  String? artistId;
  int recentPlayCount = 0;
  int likedSongCount = 0;
  bool isRecentTop5 = false;
  bool isFollowed = false;
  bool isCountryCandidate = false;
  double countryPopularity = 0;
  String? languageCode;
}
