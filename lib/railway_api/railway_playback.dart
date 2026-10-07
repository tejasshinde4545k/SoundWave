import 'package:just_audio/just_audio.dart';
import 'package:soundwave/railway_api/api_errors.dart';
import 'package:soundwave/railway_api/models.dart';
import 'package:soundwave/railway_api/music_repository.dart';

class MusicQueue {
  final List<Song> _songs = [];

  List<Song> get songs => List.unmodifiable(_songs);

  void add(Song song) => _songs.add(song);
  void remove(Song song) => _songs.remove(song);
  void clear() => _songs.clear();
}

/// Resolves a fresh HLS master playlist for each play request.
///
/// The existing audio service owns background playback; this class only
/// supplies it with an expiring source and does not create a second service.
class RailwayPlayback {
  RailwayPlayback({
    required this._repository,
    required this._player,
  });

  final MusicRepository _repository;
  final AudioPlayer _player;

  Future<void> play(Song song) async {
    try {
      final stream = await _repository.freshStream(song.id);
      await _player.setUrl(stream.hlsUrl);
      await _player.play();
    } catch (_) {
      try {
        final refreshed = await _repository.freshStream(song.id);
        await _player.setUrl(refreshed.hlsUrl);
        await _player.play();
      } catch (_) {
        throw const PlaybackError();
      }
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  Future<void> stop() => _player.stop();
}
