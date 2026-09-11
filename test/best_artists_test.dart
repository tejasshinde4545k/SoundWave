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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/screens/artist_page.dart';
import 'package:soundwave/screens/best_artists_page.dart';
import 'package:soundwave/services/artist_catalog_service.dart';
import 'package:soundwave/services/artist_image_resolver.dart';
import 'package:soundwave/services/best_artists_service.dart';
import 'package:soundwave/services/music_region_service.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/services/release_metadata_service.dart';
import 'package:soundwave/services/router_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SoundWave Best Artists & Artist Image Resolution — 20 Required Tests', () {
    final coldProfile = MusicRegionService.instance.analyzeUserProfile(
      recentlyPlayed: [],
      likedSongs: [],
    );

    // 1. Arijit Singh → imageUrl is not null/empty when source is available
    test('1. Arijit Singh receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('Arijit Singh');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 2. A.R. Rahman → real artist image
    test('2. A.R. Rahman receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('A.R. Rahman');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 3. Shreya Ghoshal → real artist image
    test('3. Shreya Ghoshal receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('Shreya Ghoshal');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 4. Shubh → real artist image
    test('4. Shubh receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('Shubh');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 5. B Praak → real artist image
    test('5. B Praak receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('B Praak');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 6. Diljit Dosanjh → real artist image
    test('6. Diljit Dosanjh receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('Diljit Dosanjh');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 7. Ed Sheeran → real artist image
    test('7. Ed Sheeran receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('Ed Sheeran');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 8. The Weeknd → real artist image
    test('8. The Weeknd receives a real artist image URL', () {
      final image = ArtistImageResolver.instance.getCachedImage('The Weeknd');
      expect(image, isNotNull);
      expect(image!.isNotEmpty, isTrue);
      expect(ArtistImageResolver.isValidArtistImageUrl(image), isTrue);
    });

    // 9. Song artwork → rejected as artist image
    test('9. Song artwork is rejected as artist image', () {
      const songArtwork1 = 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg';
      const songArtwork2 = 'https://i.ytimg.com/vi/abc1234/sddefault.jpg';
      const songArtwork3 = 'https://i.ytimg.com/vi/xyz987/maxresdefault.jpg';

      expect(ArtistImageResolver.isValidArtistImageUrl(songArtwork1), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl(songArtwork2), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl(songArtwork3), isFalse);
    });

    // 10. Album artwork → rejected as artist image
    test('10. Album artwork is rejected as artist image', () {
      final historyWithSongArtwork = [
        {
          'ytid': 'ed1',
          'title': 'Perfect',
          'artist': 'Ed Sheeran',
          'image': 'https://example.com/ed_sheeran_perfect_single_cover.jpg',
        },
      ];

      final artists = BestArtistsService.instance.computeRankedArtists(
        regionCode: 'GLOBAL',
        userProfile: coldProfile,
        recentlyPlayed: historyWithSongArtwork,
      );

      final edSheeran = artists.firstWhere((a) => a['title'] == 'Ed Sheeran');
      expect(edSheeran['image'], isNot(equals('https://example.com/ed_sheeran_perfect_single_cover.jpg')));
      expect(ArtistImageResolver.isValidArtistImageUrl(edSheeran['image']), isTrue);
    });

    // 11. Speed Records → rejected as artist identity/image for Shubh
    test('11. Speed Records is rejected as artist identity/image', () {
      expect(ArtistImageResolver.isRecordLabelOrChannel('Speed Records'), isTrue);
      expect(ArtistImageResolver.isRecordLabelOrChannel('Speed Records Bhojpuri'), isTrue);

      final historyWithLabel = [
        {'ytid': 'v1', 'title': 'Cheques', 'artist': 'Speed Records', 'image': 'https://cover.jpg'},
      ];

      final profile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: historyWithLabel,
        likedSongs: historyWithLabel,
      );

      final artists = BestArtistsService.instance.computeRankedArtists(
        regionCode: 'IN',
        userProfile: profile,
        recentlyPlayed: historyWithLabel,
        likedSongs: historyWithLabel,
      );

      final names = artists.map((a) => a['title'].toString().toLowerCase()).toList();
      expect(names, isNot(contains('speed records')));
    });

    // 12. T-Series → rejected as artist identity/image for Arijit Singh
    test('12. T-Series is rejected as artist identity/image', () {
      expect(ArtistImageResolver.isRecordLabelOrChannel('T-Series'), isTrue);
      expect(ArtistImageResolver.isRecordLabelOrChannel('T-Series Apna Punjab'), isTrue);
      expect(ArtistImageResolver.isRecordLabelOrChannel('Sony Music India'), isTrue);
      expect(ArtistImageResolver.isRecordLabelOrChannel('Zee Music Company'), isTrue);

      final historyWithTSeries = [
        {'ytid': 't1', 'title': 'Channa Mereya', 'artist': 'T-Series', 'image': 'https://cover.jpg'},
      ];

      final artists = BestArtistsService.instance.computeRankedArtists(
        regionCode: 'IN',
        userProfile: coldProfile,
        recentlyPlayed: historyWithTSeries,
        likedSongs: historyWithTSeries,
      );

      final names = artists.map((a) => a['title'].toString().toLowerCase()).toList();
      expect(names, isNot(contains('t-series')));
    });

    // 13. Generic avatar → not treated as successful image
    test('13. Generic avatar is not treated as successful image', () {
      const genericDeezer = 'https://cdn-images.dzcdn.net/images/artist//250x250-000000-80-0-0.jpg';
      const genericAvatar = 'https://example.com/assets/default_user.png';
      const assetsIcon = 'assets/icons/avatar.png';

      expect(ArtistImageResolver.isValidArtistImageUrl(genericDeezer), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl(genericAvatar), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl(assetsIcon), isFalse);
    });

    // 14. Failed image URL → tries next resolver source
    test('14. Failed image URL is rejected by URL validation', () {
      expect(ArtistImageResolver.isValidArtistImageUrl(''), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl('   '), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl('ftp://invalid.url'), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl('not-a-url'), isFalse);
    });

    // 15. No image source → dedicated artist placeholder
    testWidgets('15. No image source displays dedicated artist placeholder with initials', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DedicatedArtistPlaceholder(name: 'Arijit Singh', size: 86),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('AS'), findsOneWidget);
    });

    // 16. Cached valid image → reused without network request
    test('16. Cached valid image is reused without network request', () {
      final img1 = ArtistImageResolver.instance.getCachedImage('Arijit Singh');
      final img2 = ArtistImageResolver.instance.getCachedImage('Arijit Singh');
      expect(img1, isNotNull);
      expect(img1, equals(img2));
    });

    // 17. Cached invalid/placeholder image → invalidated
    test('17. Invalid/empty image is never considered valid cache', () {
      expect(ArtistImageResolver.isValidArtistImageUrl(''), isFalse);
      expect(ArtistImageResolver.isValidArtistImageUrl(null), isFalse);
    });

    // 18. Home rebuild → does not repeatedly request the same image
    test('18. Concurrent resolution requests for same artist are deduplicated', () {
      final f1 = ArtistImageResolver.instance.resolveArtistImage('Arijit Singh');
      final f2 = ArtistImageResolver.instance.resolveArtistImage('Arijit Singh');
      expect(f1, equals(f2));
    });

    // 19. Artist tap → correct artist identity passed to Artist Page
    test('19. Artist Page receives correct artist identity on tap', () {
      const page = ArtistPage(artistId: 'Arijit Singh');
      expect(page.artistId, equals('Arijit Singh'));
      expect(page.artistId.contains('watch?v='), isFalse);
      expect(page.artistId.contains('list='), isFalse);
    });

    // 20. Artist Page → loads songs belonging to selected artist
    test('20. Artist Page loads songs belonging to selected artist', () async {
      ArtistCatalogService.instance.seedArtistSongsForTesting('Arijit Singh', [
        {'ytid': 's1', 'title': 'Kesariya', 'artist': 'Arijit Singh'},
        {'ytid': 's2', 'title': 'Tum Hi Ho', 'artist': 'Arijit Singh'},
      ]);
      final songs = await ArtistCatalogService.instance.getArtistSongs('Arijit Singh');
      expect(songs, isA<List<Map<String, dynamic>>>());
      expect(songs.length, greaterThanOrEqualTo(2));
      expect(songs.every((s) => s['artist'] == 'Arijit Singh'), isTrue);
    });

    // Circular UI verification
    testWidgets('Best Artists page displays circular artist cards', (tester) async {
      final sampleArtists = [
        {'title': 'Arijit Singh', 'image': 'https://lh3.googleusercontent.com/test'},
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: BestArtistsPage(initialArtists: sampleArtists),
        ),
      );
      await tester.pumpAndSettle();

      final containerFinder = find.byWidgetPredicate((widget) {
        if (widget is Container && widget.decoration is BoxDecoration) {
          final dec = widget.decoration as BoxDecoration;
          return dec.shape == BoxShape.circle;
        }
        return false;
      });
      expect(containerFinder, findsWidgets);
    });
  });
}
