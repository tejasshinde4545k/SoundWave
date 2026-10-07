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

import 'package:soundwave/services/music_source.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const _noiseTerms =
    'official music video|official lyric video|official lyrics video|'
    'official video|official 4k video|official audio|lyric video|'
    'lyrics video|official hd video|lyric visualizer|lyric vizualizer|'
    'official visualizer|official vizualizer|official visualiser|official vizualiser|lyrics|lyric|official song clip|'
    'official|karaoke';

// Bracket groups that contain a noise term anywhere inside: (Official Video)
final _bracketedNoisePattern = RegExp(
  r'[\(\[][^\)\]]*(?:' + _noiseTerms + r')[^\)\]]*[\)\]]',
  caseSensitive: false,
);

// Same noise phrases unbracketed at the end of a title, e.g. after | is stripped.
final _trailingNoisePattern = RegExp(
  r'\s*[-–—]?\s*\b(?:' + _noiseTerms + r'|audio)\b\s*$',
  caseSensitive: false,
);

String formatSongTitle(String title) {
  // Remove bracketed groups first to avoid false matches on real title words.
  var t = title.replaceAll(_bracketedNoisePattern, '');

  // Strip lone brackets, pipes, and decode HTML entities.
  t = t
      .replaceAll(RegExp(r'[\[\]()|]'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .trimLeft();

  // Strip trailing unbracketed noise; loop to handle stacked suffixes.
  String prev;
  do {
    prev = t;
    t = t.replaceAll(_trailingNoisePattern, '');
  } while (t != prev);

  return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
}

Map<String, dynamic> returnSongLayout(
  int index,
  Video song, {
  String? playlistImage,
}) {
  final sep = song.title.indexOf(' - ');
  final hasExplicitArtist = sep != -1;
  final artist = hasExplicitArtist ? song.title.substring(0, sep) : '';
  final rawTitle = hasExplicitArtist
      ? song.title.substring(sep + 3)
      : song.title;
  final title = formatSongTitle(rawTitle);

  return {
    'id': index,
    'ytid': song.id.toString(),
    'title': title.isEmpty ? rawTitle.trim() : title,
    'artist': artist, // empty when not explicitly in the title
    'artistId': song.channelId.toString(),
    'videoAuthor': song.author, // channel/uploader — never treated as artist
    'artistVerified': hasExplicitArtist,
    'image': playlistImage ?? song.thumbnails.standardResUrl,
    'lowResImage': playlistImage ?? song.thumbnails.lowResUrl,
    'highResImage': playlistImage ?? song.thumbnails.maxResUrl,
    'duration': song.duration?.inSeconds,
    'isLive': song.isLive,
    'provider': 'youtube',
  };
}

String? getSongId(String url) => VideoId.parseVideoId(url);

String formatDuration(int audioDurationInSeconds) {
  final duration = Duration(seconds: audioDurationInSeconds);

  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  return [
    if (hours > 0) hours.toString().padLeft(2, '0'),
    minutes.toString().padLeft(2, '0'),
    seconds.toString().padLeft(2, '0'),
  ].join(':');
}

// ─── Jamendo helpers ──────────────────────────────────────────────────────────

/// The prefix that identifies a Jamendo song in the app-wide `ytid` field.
/// Example: ytid = 'jamendo:1234567'
const String jamendoIdPrefix = 'jamendo:';

/// Returns true if [id] looks like a Jamendo compound ID (starts with prefix).
bool isJamendoId(String? id) => id?.startsWith(jamendoIdPrefix) ?? false;

/// Extracts the raw Jamendo numeric ID from a compound ytid.
/// Returns null if [ytid] is not a Jamendo ID.
String? extractJamendoId(String? ytid) {
  if (!isJamendoId(ytid)) return null;
  return ytid!.substring(jamendoIdPrefix.length);
}

/// Converts a raw Jamendo API track object into the app's standard song map.
///
/// The resulting map is compatible with every existing function that consumes
/// song maps (queue, liked songs, recently played, SongBar, MediaItem, etc.)
/// because it uses the same keys — just with `ytid = 'jamendo:<id>'`.
///
/// The optional [preResolvedAudioUrl] is the `audio` field from the same API
/// response; storing it avoids a second API round-trip at play time.
Map<String, dynamic> returnJamendoSongLayout(
  int index,
  Map<String, dynamic> track, {
  String? preResolvedAudioUrl,
}) {
  final jamendoId = track['id']?.toString() ?? '';
  // Prefer the higher-resolution album artwork when available.
  final albumImage = track['album_image']?.toString() ?? '';
  final smallImage = track['image']?.toString() ?? '';
  final highRes = albumImage.isNotEmpty ? albumImage : smallImage;
  final lowRes = smallImage.isNotEmpty ? smallImage : highRes;

  // Use the audio field from the track response as the pre-resolved stream URL
  // so the player can start immediately without an extra API call.
  final audioUrl = preResolvedAudioUrl ?? track['audio']?.toString();

  return {
    'id': index,
    'ytid': '$jamendoIdPrefix$jamendoId',
    'title': track['name']?.toString() ?? '',
    'artist': track['artist_name']?.toString() ?? '',
    'artistId': track['artist_id']?.toString() ?? '',
    'videoAuthor': track['artist_name']?.toString() ?? '',
    'album': track['album_name']?.toString() ?? '',
    'image': highRes,
    'lowResImage': lowRes,
    'highResImage': highRes,
    'duration': track['duration'] != null
        ? int.tryParse(track['duration'].toString())
        : null,
    'isLive': false,
    // 'source' is an extra field used only for UI (source badge).
    // It does NOT affect playback — the 'ytid' prefix is the authoritative
    // discriminator everywhere.
    'source': 'jamendo',
    'provider': 'jamendo',
    // Pre-cached stream URL from the search response — avoids an extra API
    // call when the user immediately taps a freshly searched result.
    // This field is optional; if absent, JamendoService.getStreamUrl() is
    // called at play time.
    if (audioUrl != null && audioUrl.isNotEmpty) 'jamendoAudioUrl': audioUrl,
  };
}

// ─── Railway helpers ─────────────────────────────────────────────────────────

/// The prefix that identifies a Railway song in the app-wide `ytid` field.
const String railwayIdPrefix = 'railway:';

bool isRailwayId(String? id) => id?.startsWith(railwayIdPrefix) ?? false;

String? extractRailwayId(String? ytid) {
  if (!isRailwayId(ytid)) return null;
  return ytid!.substring(railwayIdPrefix.length);
}

Map<String, dynamic> returnRailwaySongLayout(
  int index,
  Map<String, dynamic> song,
) {
  final trackId = song['track_id']?.toString() ?? song['id']?.toString() ?? '';
  final artwork = song['artworkUrl']?.toString() ?? '';
  return {
    'id': index,
    'ytid': '$railwayIdPrefix$trackId',
    'title': song['title']?.toString() ?? '',
    'artist': song['artists']?.toString() ?? '',
    'album': song['album']?.toString() ?? song['albumTitle']?.toString() ?? '',
    'image': artwork,
    'lowResImage': artwork,
    'highResImage': artwork,
    'duration': int.tryParse(song['duration']?.toString() ?? ''),
    'isLive': false,
    'source': 'railway',
    'provider': MusicProviderType.railway,
    'railwayTrackId': trackId,
    if (song['language'] != null) 'language': song['language']?.toString(),
    if (song['seokey'] != null) 'seokey': song['seokey']?.toString(),
  };
}

// ─── JioSaavn helpers ────────────────────────────────────────────────────────

/// The prefix that identifies a JioSaavn song in the app-wide `ytid` field.
/// Example: ytid = 'jiosaavn:3IoDK8qI'
const String jiosaavnIdPrefix = 'jiosaavn:';

/// Returns true if [id] looks like a JioSaavn compound ID (starts with prefix).
bool isJioSaavnId(String? id) => id?.startsWith(jiosaavnIdPrefix) ?? false;

/// Extracts the raw JioSaavn alphanumeric ID from a compound ytid.
/// Returns null if [ytid] is not a JioSaavn ID.
String? extractJioSaavnId(String? ytid) {
  if (!isJioSaavnId(ytid)) return null;
  return ytid!.substring(jiosaavnIdPrefix.length);
}

/// Converts a raw JioSaavn API song object (from /api/search/songs or
/// /api/songs) into the app's standard song map.
///
/// Response shape (saavn.dev / sumitkolhe/jiosaavn-api v0.1.0):
///   {
///     id: string,
///     name: string,
///     artists: { primary: [{name, ...}], ...},
///     image: [{quality, url}, ...],
///     downloadUrl: [{quality, url}, ...],
///     duration: number (seconds),
///     album: {id, name},
///   }
///
/// The optional [preResolvedStreamUrl] short-circuits the stream URL lookup
/// when the search response already contains a usable download URL.
Map<String, dynamic> returnJioSaavnSongLayout(
  int index,
  Map<String, dynamic> song, {
  String? preResolvedStreamUrl,
}) {
  final id = song['id']?.toString() ?? '';

  // Primary artist name — pick the first primary artist if available.
  final primaryArtists = song['artists']?['primary'];
  final String artistName;
  if (primaryArtists is List && primaryArtists.isNotEmpty) {
    artistName = primaryArtists.first?['name']?.toString() ?? '';
  } else {
    artistName =
        song['primaryArtists']?.toString() ?? song['artist']?.toString() ?? '';
  }

  // Image: pick the highest available resolution from the list.
  final imageList = song['image'];
  var highRes = '';
  var lowRes = '';
  if (imageList is List && imageList.isNotEmpty) {
    highRes =
        imageList.last['url']?.toString() ??
        imageList.first['url']?.toString() ??
        '';
    lowRes = imageList.first['url']?.toString() ?? highRes;
  }

  // Duration (seconds).
  final durationSec = song['duration'] != null
      ? int.tryParse(song['duration'].toString())
      : null;

  // Album name.
  final albumName = (song['album'] is Map)
      ? (song['album']['name']?.toString() ?? '')
      : (song['album']?.toString() ?? '');

  return {
    'id': index,
    'ytid': '$jiosaavnIdPrefix$id',
    'title': song['name']?.toString() ?? '',
    'artist': artistName,
    'album': albumName,
    'image': highRes,
    'lowResImage': lowRes,
    'highResImage': highRes,
    'duration': durationSec,
    'isLive': false,
    // Identifies the provider for debugging and queue trace output.
    // Does NOT affect playback — `ytid` prefix is authoritative.
    'source': 'jiosaavn',
    'provider': 'jiosaavn',
    // Pre-cached stream URL — avoids an extra API round-trip at play time.
    // This field is optional; if absent, JioSaavnService.getStreamUrl() is
    // called at play time via _getPlaybackUrl() in audio_service.dart.
    if ((preResolvedStreamUrl ?? '').isNotEmpty)
      'jiosaavnAudioUrl': preResolvedStreamUrl,
  };
}
