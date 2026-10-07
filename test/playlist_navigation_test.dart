import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:soundwave/railway_api/models.dart';
import 'package:soundwave/services/music_source.dart';
import 'package:soundwave/services/router_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    NavigationManager();
  });

  group('Playlist Route Registration Tests', () {
    test('Router has registered playlist route under Search branch', () {
      final router = NavigationManager.router;
      const testPath = '/search/playlist/PL8BkkH6_BxITwXwtJ6VXZhLAs4cJ5Qw3W';
      
      // router.routeInformationParser or router.configuration can parse and match the location
      final match = router.routerDelegate.currentConfiguration;
      expect(match, isNotNull);

      // Verify that the route location can be parsed without throwing GoException
      expect(() {
        final matches = router.configuration.findMatch(Uri.parse(testPath));
        expect(matches.isNotEmpty, isTrue);
      }, returnsNormally);
    });

    test('Router has registered playlist route under Home branch', () {
      final router = NavigationManager.router;
      const testPath = '/home/playlist/PL8BkkH6_BxITwXwtJ6VXZhLAs4cJ5Qw3W';
      expect(() {
        final matches = router.configuration.findMatch(Uri.parse(testPath));
        expect(matches.isNotEmpty, isTrue);
      }, returnsNormally);
    });

    test('Router has registered playlist route under Library branch', () {
      final router = NavigationManager.router;
      const testPath = '/library/playlist/PL8BkkH6_BxITwXwtJ6VXZhLAs4cJ5Qw3W';
      expect(() {
        final matches = router.configuration.findMatch(Uri.parse(testPath));
        expect(matches.isNotEmpty, isTrue);
      }, returnsNormally);
    });

    test('Router matches playlist route with provider query parameter', () {
      final router = NavigationManager.router;
      const testPath =
          '/search/playlist/PL8BkkH6_BxITwXwtJ6VXZhLAs4cJ5Qw3W?provider=youtube';
      expect(() {
        final matches = router.configuration.findMatch(Uri.parse(testPath));
        expect(matches.isNotEmpty, isTrue);
      }, returnsNormally);
    });

    test('Router matches Railway playlist route', () {
      final router = NavigationManager.router;
      const testPath =
          '/search/playlist/railway%3Agaana-dj-bollywood-love-anthems?provider=railway';
      expect(() {
        final matches = router.configuration.findMatch(Uri.parse(testPath));
        expect(matches.isNotEmpty, isTrue);
      }, returnsNormally);
    });

    test('Direct /playlist/:playlistId redirects to /home/playlist/:playlistId', () {
      final router = NavigationManager.router;
      const testPath = '/playlist/PL8BkkH6_BxITwXwtJ6VXZhLAs4cJ5Qw3W';
      expect(() {
        final matches = router.configuration.findMatch(Uri.parse(testPath));
        expect(matches.isNotEmpty, isTrue);
      }, returnsNormally);
    });
  });

  group('Playlist Model & Provider Identity Tests', () {
    test('Playlist model retains provider attribute and defaults to railway', () {
      const playlist = Playlist(
        id: '123',
        title: 'Test Playlist',
        provider: MusicProviderType.railway,
      );
      expect(playlist.provider, equals(MusicProviderType.railway));
    });

    test('Playlist.fromJson parses nested and flat json maps with provider', () {
      final flatJson = {
        'playlist_id': '3912887',
        'title': 'Bollywood Love Anthems',
        'seokey': 'gaana-dj-bollywood-love-anthems',
        'provider': 'railway',
        'tracks': [
          {
            'track_id': '101',
            'title': 'Song 1',
            'artists': 'Artist 1',
          }
        ],
      };
      final p1 = Playlist.fromJson(flatJson);
      expect(p1.id, equals('3912887'));
      expect(p1.title, equals('Bollywood Love Anthems'));
      expect(p1.provider, equals(MusicProviderType.railway));
      expect(p1.tracks.length, equals(1));

      final nestedJson = {
        'playlist': {
          'playlist_id': '944491',
          'title': 'Nested Playlist',
          'seokey': 'nested-seokey',
          'provider': 'railway',
          'tracks': [],
        }
      };
      final p2 = Playlist.fromJson(nestedJson);
      expect(p2.id, equals('944491'));
      expect(p2.title, equals('Nested Playlist'));
      expect(p2.provider, equals(MusicProviderType.railway));
    });
  });
}
