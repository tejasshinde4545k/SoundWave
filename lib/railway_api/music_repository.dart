import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:soundwave/railway_api/models.dart';
import 'package:soundwave/railway_api/railway_music_api.dart';

class MusicRepository {
  MusicRepository(this._api, {Box<dynamic>? cacheBox}) {
    _cacheBox = cacheBox;
  }

  final RailwayMusicApi _api;
  Box<dynamic>? _cacheBox;

  static const String _providerPrefix = 'railway';

  Future<List<Song>> searchSongs(String query) async =>
      _cachedList('$_providerPrefix:search:songs:$query', () => _api.searchSongs(query), Song.fromJson);
  Future<List<Album>> searchAlbums(String query) async =>
      _cachedList('$_providerPrefix:search:albums:$query', () => _api.searchAlbums(query), Album.fromJson);
  Future<List<Artist>> searchArtists(String query) async =>
      _cachedList('$_providerPrefix:search:artists:$query', () => _api.searchArtists(query), Artist.fromJson);
  Future<List<Playlist>> searchPlaylists(String query) async =>
      _cachedList('$_providerPrefix:search:playlists:$query', () => _api.searchPlaylists(query), Playlist.fromJson);

  Future<SearchResult> search(String query) => _api.search(query);
  Future<List<Song>> trending() =>
      _cachedList('$_providerPrefix:trending', _api.trending, Song.fromJson);
  Future<List<Song>> newReleases() =>
      _cachedList('$_providerPrefix:new-releases', _api.newReleases, Song.fromJson);
  Future<Song> song(String seokey) => _api.song(seokey);
  Future<Album> album(String seokey) => _api.album(seokey);
  Future<Artist> artist(String seokey) => _api.artist(seokey);
  Future<Playlist> playlist(String seokey) => _api.playlist(seokey);
  Future<Lyrics> lyrics(String seokey) => _api.lyrics(seokey);

  Future<StreamInfo> freshStream(String trackId) => _api.stream(trackId);

  Future<List<T>> _cachedList<T>(
    String key,
    Future<List<T>> Function() fetch,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    try {
      final result = await fetch();
      if (result.isNotEmpty) {
        final box = await _openCache();
        await box?.put(key, result.map(_toMap).toList());
      }
      return result;
    } catch (_) {
      final box = await _openCache();
      final cached = box?.get(key);
      if (cached is List && cached.isNotEmpty) {
        final parsed = cached
            .whereType<Map>()
            .map((item) => fromJson(Map<String, dynamic>.from(item)))
            .toList();
        if (parsed.isNotEmpty) {
          return parsed;
        }
      }
      rethrow;
    }
  }

  Map<String, dynamic> _toMap<T>(T item) {
    if (item is Song) return item.toJson();
    if (item is Album) return {'album_id': item.id, 'title': item.title};
    if (item is Artist) return {'artist_id': item.id, 'name': item.name};
    if (item is Playlist) return {'playlist_id': item.id, 'title': item.title};
    return jsonDecode(jsonEncode(item)) as Map<String, dynamic>;
  }

  Future<Box<dynamic>?> _openCache() async {
    if (_cacheBox != null) return _cacheBox;
    try {
      _cacheBox = await Hive.openBox<dynamic>('railway_music_cache');
      return _cacheBox;
    } catch (_) {
      return null;
    }
  }
}
