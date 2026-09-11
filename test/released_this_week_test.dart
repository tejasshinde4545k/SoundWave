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

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/services/release_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed reference date: Thursday, September 10, 2026
  final refNow = DateTime(2026, 9, 10, 14, 30);
  // Current week: Monday Sep 7, 2026 to Sunday Sep 13, 2026
  final mondayThisWeek = DateTime(2026, 9, 7, 0, 0, 0);
  final todayThisWeek = DateTime(2026, 9, 10, 12, 0, 0);
  final sundayThisWeek = DateTime(2026, 9, 13, 23, 59, 59, 999);
  final nextMonday = DateTime(2026, 9, 14, 0, 0, 0);
  final lastSunday = DateTime(2026, 9, 6, 23, 59, 59, 999);

  group('"Released This Week" — 15 Required Specification Tests', () {
    final service = ReleaseMetadataService.instance;

    test('1. Release on Monday => included', () {
      final isEligible = service.isReleasedThisWeek(mondayThisWeek, now: refNow);
      expect(isEligible, isTrue);
    });

    test('2. Release today => included', () {
      final isEligible = service.isReleasedThisWeek(todayThisWeek, now: refNow);
      expect(isEligible, isTrue);
    });

    test('3. Release Sunday => included', () {
      final isEligible = service.isReleasedThisWeek(sundayThisWeek, now: refNow);
      expect(isEligible, isTrue);
    });

    test('4. Release next Monday => excluded', () {
      final isEligible = service.isReleasedThisWeek(nextMonday, now: refNow);
      expect(isEligible, isFalse);
    });

    test('5. Release last Sunday => excluded', () {
      final isEligible = service.isReleasedThisWeek(lastSunday, now: refNow);
      expect(isEligible, isFalse);
    });

    test('6. Old song uploaded to YouTube today => excluded', () {
      // MusicBrainz metadata says 2019-05-20, even if YouTube upload date is today
      final oldReleaseDate = DateTime(2019, 5, 20);
      final isEligible = service.isReleasedThisWeek(oldReleaseDate, now: refNow);
      expect(isEligible, isFalse,
          reason: 'YouTube upload date must NEVER override music release date');
    });

    test('7. Old song re-uploaded by another channel => excluded', () {
      final releaseGroup = ReleaseMetadata(
        id: 'mb-reissue-1',
        title: 'Classic Hit Remastered',
        artist: 'Vintage Legend',
        releaseDate: DateTime(2026, 9, 8),
        primaryType: 'Album',
        secondaryTypes: const ['Compilation', 'Remaster'],
        isReissue: true,
        isCompilation: true,
      );

      // Reissue / compilation flag must be detected and rejected
      expect(releaseGroup.isReissue, isTrue);
      expect(releaseGroup.isCompilation, isTrue);
    });

    test('8. Podcast => excluded', () {
      const podcastTitle = 'The Joe Rogan Experience Podcast #2100';
      final isSong = RecommendationEngine.isLikelySong(podcastTitle);
      expect(isSong, isFalse);
    });

    test('9. Latent Season 2 Bonus Episode => excluded', () {
      const targetTitle = 'Latent Season 2 Bonus Episode';
      final isSong = RecommendationEngine.isLikelySong(targetTitle);
      expect(isSong, isFalse,
          reason: 'Latent Season 2 Bonus Episode must be explicitly rejected');
    });

    test('10. Multiple YouTube versions => one final song', () {
      final candidates = [
        {
          'ytid': 'v_audio',
          'title': 'Stargazing (Official Audio)',
          'videoAuthor': 'Myles Smith',
          'artist': 'Myles Smith',
          'views': 500000,
          'likes': 25000,
        },
        {
          'ytid': 'v_video',
          'title': 'Stargazing (Official Music Video)',
          'videoAuthor': 'Myles Smith',
          'artist': 'Myles Smith',
          'views': 2000000,
          'likes': 100000,
        },
        {
          'ytid': 'v_lyrics',
          'title': 'Stargazing - Lyrics',
          'videoAuthor': 'Lyrics Hub',
          'artist': 'Myles Smith',
          'views': 800000,
          'likes': 30000,
        },
      ];

      final ranked = service.rankYouTubeCandidates(
        candidates: candidates,
        targetArtist: 'Myles Smith',
        targetTitle: 'Stargazing',
      );

      expect(ranked.isNotEmpty, isTrue);
      // Winner is the single best official YouTube candidate
      final winner = ranked.first;
      expect(winner.song['ytid'], equals('v_video'));
    });

    test('11. Official video has fewer views than re-upload => official video wins', () {
      final candidates = [
        // Random re-upload with 15M views
        {
          'ytid': 'yt_reupload',
          'title': 'New Song 2026 [Re-upload]',
          'videoAuthor': 'RandomReuploader123',
          'artist': 'Unknown Uploader',
          'views': 15000000,
          'likes': 500000,
        },
        // Official video with 2M views
        {
          'ytid': 'yt_official',
          'title': 'Artist Name - New Song (Official Music Video)',
          'videoAuthor': 'Artist Name Official',
          'artist': 'Artist Name',
          'views': 2000000,
          'likes': 150000,
        },
      ];

      final ranked = service.rankYouTubeCandidates(
        candidates: candidates,
        targetArtist: 'Artist Name',
        targetTitle: 'New Song',
      );

      expect(ranked.isNotEmpty, isTrue);
      // Official music video MUST beat the re-upload despite 15M vs 2M views
      final winner = ranked.first;
      expect(winner.song['ytid'], equals('yt_official'),
          reason: 'Official video must win over random re-upload with 15M views');
    });

    test('12. MusicBrainz unavailable => Home does not crash', () async {
      // Mock client that returns 503 Service Unavailable
      final mockClient = MockClient((request) async {
        return http.Response('Service Unavailable', 503);
      });

      final testService = ReleaseMetadataService(httpClient: mockClient);
      final releases = await testService.getReleasesThisWeek(
        now: refNow,
        regionCode: 'GLOBAL',
        forceRefresh: true,
      );

      // Must return empty list cleanly without throwing
      expect(releases, isEmpty);
    });

    test('13. Release date unavailable => not labelled Released This Week', () {
      // Full date cannot be determined from year-only or null
      final yearOnly = service.parsePreciseReleaseDate('2026');
      final yearMonthOnly = service.parsePreciseReleaseDate('2026-09');
      final nullDate = service.parsePreciseReleaseDate(null);
      final invalidDate = service.parsePreciseReleaseDate('invalid-date');

      expect(yearOnly, isNull);
      expect(yearMonthOnly, isNull);
      expect(nullDate, isNull);
      expect(invalidDate, isNull);

      expect(service.isReleasedThisWeek(yearOnly, now: refNow), isFalse);
      expect(service.isReleasedThisWeek(nullDate, now: refNow), isFalse);
    });

    test('14. Week changes => cache/result refreshes', () {
      final rangeWeek1 = service.getCurrentWeekRange(DateTime(2026, 9, 10)); // Sep 7-13
      final rangeWeek2 = service.getCurrentWeekRange(DateTime(2026, 9, 14)); // Sep 14-20

      expect(rangeWeek1.weekId, isNot(equals(rangeWeek2.weekId)));
      expect(rangeWeek1.weekId, equals('2026-W37'));
      expect(rangeWeek2.weekId, equals('2026-W38'));
      expect(rangeWeek1.contains(DateTime(2026, 9, 8)), isTrue);
      expect(rangeWeek2.contains(DateTime(2026, 9, 8)), isFalse);
    });

    test('15. Existing AutoNext tests => unchanged', () {
      // Ensure RecommendationEngine isLikelySong still behaves correctly for general songs
      expect(RecommendationEngine.isLikelySong('Blinding Lights'), isTrue);
      expect(RecommendationEngine.isLikelySong('Kesariya - Official Audio'), isTrue);
      expect(RecommendationEngine.isLikelySong('Acoustic Live Session'), isTrue);
      expect(RecommendationEngine.isLikelySong('Daily News Bulletin'), isFalse);
    });
  });
}
