import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:soundwave/railway_api/api_client.dart';
import 'package:soundwave/railway_api/api_config.dart';
import 'package:soundwave/railway_api/api_errors.dart';
import 'package:soundwave/railway_api/models.dart';
import 'package:soundwave/railway_api/music_repository.dart';
import 'package:soundwave/railway_api/railway_music_api.dart';
import 'package:soundwave/services/music_source.dart';
import 'package:soundwave/utilities/formatter.dart';

class MockHttpClient extends http.BaseClient {
  MockHttpClient(this._handler);

  final Future<http.Response> Function(http.BaseRequest request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await _handler(request);
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
      reasonPhrase: res.reasonPhrase,
    );
  }
}

class FakeBox implements Box<dynamic> {
  final Map<dynamic, dynamic> _store = {};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _store.containsKey(key) ? _store[key] : defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    _store[key] = value;
  }

  @override
  bool containsKey(dynamic key) => _store.containsKey(key);

  @override
  Future<void> delete(dynamic key) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Railway Music API & Provider Tests', () {
    test('ApiConfig production base URL is exact', () {
      expect(
        ApiConfig.baseUrl,
        equals('https://gaana-api-production.up.railway.app'),
      );
      final client = ApiClient();
      final uri = client.buildUri('search/songs', {'q': 'churai'});
      expect(
        uri.toString(),
        equals('https://gaana-api-production.up.railway.app/api/search/songs?q=churai'),
      );
      expect(uri.path.contains('/api/api'), isFalse);
    });

    test('A. Railway HTTP 200 with songs', () async {
      final mock = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'data': [
              {
                'track_id': '22914963',
                'title': 'Dil Chori',
                'artists': 'Yo Yo Honey Singh, Simar Kaur',
                'album': 'Sonu Ke Titu Ki Sweety',
                'artworkUrl': 'https://example.com/art.jpg',
                'duration': '226',
                'seokey': 'dil-chori-5',
                'language': 'Hindi',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      final songs = await api.searchSongs('churai');

      expect(songs.length, equals(1));
      expect(songs.first.id, equals('22914963'));
      expect(songs.first.title, equals('Dil Chori'));
      expect(songs.first.language, equals('Hindi'));

      final layout = returnRailwaySongLayout(0, songs.first.toJson());
      expect(layout['provider'], equals(MusicProviderType.railway));
      expect(layout['source'], equals('railway'));
      expect(layout['ytid'], equals('railway:22914963'));
      expect(layout['railwayTrackId'], equals('22914963'));
    });

    test('B. Railway HTTP 200 with zero songs', () async {
      final mock = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'data': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      final songs = await api.searchSongs('emptyquery123');

      expect(songs, isEmpty);
    });

    test('C. Railway HTTP 500 throws RailwayServerError', () async {
      final mock = MockHttpClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      expect(
        () async => await api.searchSongs('test'),
        throwsA(isA<RailwayServerError>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('D. Railway HTTP 502 throws RailwayServerError', () async {
      final mock = MockHttpClient((request) async {
        return http.Response('Bad Gateway', 502);
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      expect(
        () async => await api.searchSongs('test'),
        throwsA(isA<RailwayServerError>().having((e) => e.statusCode, 'statusCode', 502)),
      );
    });

    test('E. Railway HTTP 503 throws RailwayServerError', () async {
      final mock = MockHttpClient((request) async {
        return http.Response('Service Unavailable', 503);
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      expect(
        () async => await api.searchSongs('test'),
        throwsA(isA<RailwayServerError>().having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('F. Railway HTTP 429 throws RailwayRateLimitError with retry-after', () async {
      final mock = MockHttpClient((request) async {
        return http.Response(
          'Rate limit exceeded',
          429,
          headers: {'retry-after': '60'},
        );
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      try {
        await api.searchSongs('test');
        fail('Should have thrown RailwayRateLimitError');
      } on RailwayRateLimitError catch (e) {
        expect(e.statusCode, equals(429));
        expect(e.retryAfter, equals('60'));
      }
    });

    test('G. Request timeout throws RailwayTimeoutError', () async {
      final mock = MockHttpClient((request) async {
        await Future.delayed(const Duration(milliseconds: 100));
        return http.Response('{}', 200);
      });

      final client = ApiClient(
        client: mock,
        timeout: const Duration(milliseconds: 10),
      );
      final api = RailwayMusicApi(client);

      expect(
        () async => await api.searchSongs('test'),
        throwsA(isA<RailwayTimeoutError>()),
      );
    });

    test('H. Invalid JSON throws RailwayInvalidResponseError', () async {
      final mock = MockHttpClient((request) async {
        return http.Response('<html><body>502 Bad Gateway</body></html>', 200);
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      expect(
        () async => await api.searchSongs('test'),
        throwsA(isA<RailwayInvalidResponseError>()),
      );
    });

    test('I. Valid JSON but malformed song handles gracefully', () async {
      final mock = MockHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'data': [
              {
                'track_id': '999',
                'title': null,
                'artists': null,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final api = RailwayMusicApi(ApiClient(client: mock));
      final songs = await api.searchSongs('test');
      expect(songs.length, equals(1));
      expect(songs.first.id, equals('999'));
      expect(songs.first.title, equals('Unknown song'));
      expect(songs.first.artists, equals('Unknown artist'));
    });

    test('J. Cache hit returns cached songs on network failure', () async {
      final fakeBox = FakeBox();
      final cachedList = [
        {
          'track_id': '101',
          'title': 'Cached Track',
          'artists': 'Cached Artist',
        }
      ];
      await fakeBox.put('railway:search:songs:churai', cachedList);

      final mock = MockHttpClient((request) async {
        return http.Response('Service Unavailable', 503);
      });

      final repo = MusicRepository(
        RailwayMusicApi(ApiClient(client: mock)),
        cacheBox: fakeBox,
      );

      final results = await repo.searchSongs('churai');
      expect(results.length, equals(1));
      expect(results.first.title, equals('Cached Track'));
    });

    test('K. Cache miss on network failure rethrows without returning empty list', () async {
      final fakeBox = FakeBox();
      final mock = MockHttpClient((request) async {
        return http.Response('Service Unavailable', 503);
      });

      final repo = MusicRepository(
        RailwayMusicApi(ApiClient(client: mock)),
        cacheBox: fakeBox,
      );

      expect(
        () async => await repo.searchSongs('churai'),
        throwsA(isA<RailwayServerError>()),
      );

      // Verify that failure did not write empty list to cache
      expect(fakeBox.get('railway:search:songs:churai'), isNull);
    });

    test('Assertion: HTTP FAILURE != EMPTY SEARCH RESULT', () async {
      final mockFail = MockHttpClient((request) async {
        return http.Response('503 Service Unavailable', 503);
      });
      final mockEmpty = MockHttpClient((request) async {
        return http.Response(jsonEncode({'success': true, 'data': []}), 200);
      });

      final apiFail = RailwayMusicApi(ApiClient(client: mockFail));
      final apiEmpty = RailwayMusicApi(ApiClient(client: mockEmpty));

      final emptyResult = await apiEmpty.searchSongs('nonexistent');
      expect(emptyResult, isEmpty);

      // A failure MUST throw and NOT return []
      Object? failureError;
      List<Song>? failureResult;
      try {
        failureResult = await apiFail.searchSongs('churai');
      } catch (e) {
        failureError = e;
      }

      expect(failureResult, isNull);
      expect(failureError, isNotNull);
      expect(failureError, isA<RailwayServerError>());
      expect(failureError != emptyResult, isTrue);
    });

    test('L. Provider switching changes source correctly', () async {
      final tempDir = await Directory.systemTemp.createTemp('hive_settings_test');
      Hive.init(tempDir.path);
      await Hive.openBox('settings');

      await setMusicSource(MusicSource.railway);
      expect(selectedMusicSource.value, equals(MusicSource.railway));

      await setMusicSource(MusicSource.jioSaavn);
      expect(selectedMusicSource.value, equals(MusicSource.jioSaavn));

      await setMusicSource(MusicSource.youtube);
      expect(selectedMusicSource.value, equals(MusicSource.youtube));

      await setMusicSource(MusicSource.jamendo);
      expect(selectedMusicSource.value, equals(MusicSource.jamendo));

      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
  });
}
