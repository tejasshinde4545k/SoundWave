// ignore_for_file: sort_constructors_first

import 'package:soundwave/services/music_source.dart';

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artists,
    this.albumId,
    this.albumTitle,
    this.artworkUrl,
    this.duration,
    this.seokey,
    this.language,
  });

  final String id;
  final String title;
  final String artists;
  final String? albumId;
  final String? albumTitle;
  final String? artworkUrl;
  final Duration? duration;
  final String? seokey;
  final String? language;

  factory Song.fromJson(Map<String, dynamic> rawJson) {
    final json = rawJson['song'] is Map
        ? Map<String, dynamic>.from(rawJson['song'] as Map)
        : rawJson;
    return Song(
      id: _string(json['track_id'] ?? json['id'] ?? json['seokey']),
      title: _string(json['title'] ?? json['name'], fallback: 'Unknown song'),
      artists: _string(json['artists'], fallback: 'Unknown artist'),
      albumId: _nullableString(json['album_id']),
      albumTitle: _nullableString(json['album']),
      artworkUrl: _nullableString(json['artworkUrl'] ?? json['artwork']),
      duration: _duration(json['duration']),
      seokey: _nullableString(json['seokey']),
      language: _nullableString(json['language']),
    );
  }

  Map<String, dynamic> toJson() => {
        'track_id': id,
        'title': title,
        'artists': artists,
        if (albumId != null) 'album_id': albumId,
        if (albumTitle != null) 'album': albumTitle,
        if (artworkUrl != null) 'artworkUrl': artworkUrl,
        if (duration != null) 'duration': duration!.inSeconds,
        if (seokey != null) 'seokey': seokey,
        if (language != null) 'language': language,
      };
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artists,
    this.artworkUrl,
    this.tracks = const [],
    this.seokey,
  });

  final String id;
  final String title;
  final String artists;
  final String? artworkUrl;
  final List<Song> tracks;
  final String? seokey;

  factory Album.fromJson(Map<String, dynamic> rawJson) {
    final json = rawJson['album'] is Map
        ? Map<String, dynamic>.from(rawJson['album'] as Map)
        : rawJson;
    return Album(
      id: _string(json['album_id'] ?? json['id'] ?? json['seokey']),
      title: _string(json['title'] ?? json['name'], fallback: 'Unknown album'),
      artists: _string(json['artists'], fallback: 'Unknown artist'),
      artworkUrl: _nullableString(json['artworkUrl'] ?? json['artwork']),
      tracks: _mapList(json['tracks'], Song.fromJson),
      seokey: _nullableString(json['seokey']),
    );
  }
}

class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.artworkUrl,
    this.seokey,
    this.topTracks = const [],
  });

  final String id;
  final String name;
  final String? artworkUrl;
  final String? seokey;
  final List<Song> topTracks;

  factory Artist.fromJson(Map<String, dynamic> rawJson) {
    final json = rawJson['artist'] is Map
        ? Map<String, dynamic>.from(rawJson['artist'] as Map)
        : rawJson;
    return Artist(
      id: _string(json['artist_id'] ?? json['id'] ?? json['seokey']),
      name: _string(json['name'] ?? json['title'], fallback: 'Unknown artist'),
      artworkUrl: _nullableString(json['artworkUrl'] ?? json['artwork']),
      seokey: _nullableString(json['seokey']),
      topTracks: _mapList(json['top_tracks'], Song.fromJson),
    );
  }
}

class Playlist {
  const Playlist({
    required this.id,
    required this.title,
    this.artists,
    this.artworkUrl,
    this.seokey,
    this.tracks = const [],
    this.provider = MusicProviderType.railway,
  });

  final String id;
  final String title;
  final String? artists;
  final String? artworkUrl;
  final String? seokey;
  final List<Song> tracks;
  final MusicProviderType provider;

  factory Playlist.fromJson(Map<String, dynamic> rawJson) {
    final json = rawJson['playlist'] is Map
        ? Map<String, dynamic>.from(rawJson['playlist'] as Map)
        : rawJson;
    return Playlist(
      id: _string(json['playlist_id'] ?? json['id'] ?? json['seokey']),
      title: _string(json['title'] ?? json['name'], fallback: 'Untitled playlist'),
      artists: _nullableString(json['artists']),
      artworkUrl: _nullableString(json['artworkUrl'] ?? json['artwork']),
      seokey: _nullableString(json['seokey']),
      tracks: _mapList(json['tracks'], Song.fromJson),
      provider: _parseProvider(json['provider']) ?? MusicProviderType.railway,
    );
  }
}

class Lyrics {
  const Lyrics({required this.text, this.synced});

  final String text;
  final String? synced;

  factory Lyrics.fromJson(Map<String, dynamic> json) => Lyrics(
        text: _string(json['lyrics'] ?? json['text'] ?? json['content']),
        synced: _nullableString(json['syncedLyrics'] ?? json['synced']),
      );
}

class StreamInfo {
  const StreamInfo({required this.hlsUrl, this.quality, this.bitRate});

  final String hlsUrl;
  final String? quality;
  final String? bitRate;

  factory StreamInfo.fromJson(Map<String, dynamic> json) => StreamInfo(
        hlsUrl: _string(json['hlsUrl']),
        quality: _nullableString(json['quality']),
        bitRate: _nullableString(json['bitRate']),
      );
}

class SearchResult {
  const SearchResult({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
  });

  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  final List<Playlist> playlists;
}

String _string(dynamic value, {String fallback = ''}) =>
    value?.toString().trim().isNotEmpty == true ? value.toString() : fallback;

String? _nullableString(dynamic value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

Duration? _duration(dynamic value) {
  final seconds = int.tryParse(value?.toString() ?? '');
  return seconds == null ? null : Duration(seconds: seconds);
}

List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) mapper) =>
    value is List
        ? value.whereType<Map<String, dynamic>>().map(mapper).toList()
        : const [];

MusicProviderType? _parseProvider(dynamic val) {
  if (val == null) return null;
  final s = val.toString().toLowerCase();
  for (final p in MusicProviderType.values) {
    if (p.name.toLowerCase() == s) return p;
  }
  return null;
}
