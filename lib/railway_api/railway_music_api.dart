// ignore_for_file: avoid_print
import 'package:soundwave/railway_api/api_client.dart';
import 'package:soundwave/railway_api/api_errors.dart';
import 'package:soundwave/railway_api/models.dart';

class RailwayMusicApi {
  RailwayMusicApi(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> health() async =>
      _map(await _client.get('health'));

  Future<SearchResult> search(String query, {int limit = 20}) async {
    final body = _map(await _client.get('search', queryParameters: {
      'q': query,
      'limit': '$limit',
    }));
    final data = _mapValue(body['data']);
    return SearchResult(
      songs: _list(data['songs'], Song.fromJson),
      albums: _list(data['albums'], Album.fromJson),
      artists: _list(data['artists'], Artist.fromJson),
      playlists: _list(data['playlists'], Playlist.fromJson),
    );
  }

  Future<List<Song>> searchSongs(String query, {int limit = 20}) =>
      _searchList('search/songs', query, limit, Song.fromJson);
  Future<List<Album>> searchAlbums(String query, {int limit = 20}) =>
      _searchList('search/albums', query, limit, Album.fromJson);
  Future<List<Artist>> searchArtists(String query, {int limit = 20}) =>
      _searchList('search/artists', query, limit, Artist.fromJson);
  Future<List<Playlist>> searchPlaylists(String query, {int limit = 20}) =>
      _searchList('search/playlists', query, limit, Playlist.fromJson);

  Future<List<Song>> trending({String? language, int limit = 40}) =>
      _browseSongs('trending', language: language, limit: limit);

  Future<List<Song>> newReleases({String? language, int page = 1}) async {
    final body = _map(await _client.get('new-releases', queryParameters: {
      if (language != null) 'language': language,
      'page': '$page',
    }));
    return _list(_mapValue(body['data'])['tracks'] ?? body['data'], Song.fromJson);
  }

  Future<Song> song(String seokey) async =>
      Song.fromJson(_detail(await _client.get('songs/$seokey')));
  Future<Album> album(String seokey) async =>
      Album.fromJson(_detail(await _client.get('albums/$seokey')));
  Future<Artist> artist(String seokey) async =>
      Artist.fromJson(_detail(await _client.get('artists/$seokey')));
  Future<Playlist> playlist(String seokey) async =>
      Playlist.fromJson(_detail(await _client.get('playlists/$seokey')));

  Future<Lyrics> lyrics(String seokey) async =>
      Lyrics.fromJson(_detail(await _client.get('lyrics/$seokey')));

  Future<StreamInfo> stream(String trackId, {String quality = 'high'}) async {
    final body = _map(await _client.get('stream/$trackId', queryParameters: {
      'quality': quality,
    }));
    final data = _mapValue(body['data']);
    final hlsUrl = data['hlsUrl'];
    if (hlsUrl is! String || hlsUrl.isEmpty) {
      throw const StreamUnavailableError();
    }
    return StreamInfo.fromJson(data);
  }

  Future<List<T>> _searchList<T>(
    String path,
    String query,
    int limit,
    T Function(Map<String, dynamic>) mapper,
  ) async {
    final body = _map(await _client.get(path, queryParameters: {
      'q': query,
      'limit': '$limit',
    }));
    final rawData = body['data'];
    final List rawList;
    if (rawData is List) {
      rawList = rawData;
    } else if (rawData is Map) {
      if (rawData['songs'] is List) {
        rawList = rawData['songs'] as List;
      } else if (rawData['tracks'] is List) {
        rawList = rawData['tracks'] as List;
      } else if (rawData['albums'] is List && path.contains('albums')) {
        rawList = rawData['albums'] as List;
      } else if (rawData['artists'] is List && path.contains('artists')) {
        rawList = rawData['artists'] as List;
      } else if (rawData['playlists'] is List && path.contains('playlists')) {
        rawList = rawData['playlists'] as List;
      } else {
        rawList = const [];
      }
    } else {
      rawList = const [];
    }

    print('[SEARCH]\nSEARCH_RAW_RESULT_COUNT: ${rawList.length}');

    final List<T> mapped;
    try {
      mapped = _list(rawList, mapper);
    } catch (e) {
      throw RailwayParseError('Failed to parse search items: $e');
    }

    print('[SEARCH]\nSEARCH_MAPPED_RESULT_COUNT: ${mapped.length}');
    return mapped;
  }

  Future<List<Song>> _browseSongs(
    String path, {
    String? language,
    required int limit,
  }) async {
    final body = _map(await _client.get(path, queryParameters: {
      if (language != null) 'language': language,
      'limit': '$limit',
    }));
    final data = body['data'];
    return _list(data is Map ? data['tracks'] : data, Song.fromJson);
  }

  Map<String, dynamic> _detail(dynamic value) {
    var result = _map(value);
    for (var i = 0; i < 2; i++) {
      if (result['data'] is Map<String, dynamic>) {
        result = result['data'] as Map<String, dynamic>;
      } else {
        break;
      }
    }
    return result;
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map<String, dynamic> ? value : <String, dynamic>{};
  Map<String, dynamic> _mapValue(dynamic value) => _map(value);
  List<T> _list<T>(dynamic value, T Function(Map<String, dynamic>) mapper) =>
      value is List
          ? value
              .whereType<Map>()
              .map((item) => mapper(Map<String, dynamic>.from(item)))
              .toList()
          : <T>[];
}
