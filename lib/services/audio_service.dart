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

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:soundwave/main.dart';
import 'package:soundwave/models/position_data.dart';
import 'package:soundwave/services/common_services.dart';
import 'package:soundwave/services/data_manager.dart';
import 'package:soundwave/services/jamendo_service.dart';
import 'package:soundwave/services/listening_stats_service.dart';
import 'package:soundwave/services/proxy_manager.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/services/settings_manager.dart';
import 'package:soundwave/utilities/formatter.dart'
    show
        isJamendoId,
        extractJamendoId,
        returnSongLayout,
        returnJamendoSongLayout;
import 'package:soundwave/utilities/map_utils.dart';
import 'package:soundwave/utilities/mediaitem.dart';
import 'package:soundwave/utilities/queue_entry_utils.dart';

class MusifyAudioHandler extends BaseAudioHandler {
  MusifyAudioHandler() {
    _androidEqualizer = AndroidEqualizer();
    audioPlayer = AudioPlayer(
      audioPipeline: AudioPipeline(androidAudioEffects: [_androidEqualizer]),
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          maxBufferDuration: Duration(seconds: 60),
          bufferForPlaybackDuration: Duration(milliseconds: 500),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 3),
        ),
      ),
    );

    _setupEventSubscriptions();
    _updatePlaybackState();

    audioPlayer.setAndroidAudioAttributes(
      const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
    );

    _initialize();
  }

  late final AndroidEqualizer _androidEqualizer;
  late final AudioPlayer audioPlayer;
  bool _equalizerInitialized = false;
  Future<bool>? _equalizerInitFuture;
  DateTime _equalizerRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _sleepTimer;
  Timer? _debounceTimer;
  bool sleepTimerExpired = false;
  bool sleepTimerEndOfSong = false;

  final List<Map> _queueList = [];
  final List<Map> _originalQueueList = [];
  final List<Map> _historyList = [];
  final BehaviorSubject<List<Map>> _queueMapStream =
      BehaviorSubject<List<Map>>.seeded([]);
  final QueueEntryIdManager _queueEntryIds = QueueEntryIdManager();
  int _currentQueueIndex = 0;
  int _currentLoadingIndex = -1;
  int _currentLoadingTransitionId = -1;
  bool _isUpdatingState = false;
  bool _pendingPlaybackStateUpdate = false;
  int _songTransitionCounter = 0;

  bool _isAdvancingQueue = false;
  bool _isHandlingSongCompletion = false;
  bool _singleSongAutoNext = false;

  // ── Recommendation refill state ─────────────────────────────────────────────
  bool _isRefillInProgress = false;
  int _recommendationGeneration = 0;

  /// Holds the Future of the currently-running background refill so that
  /// `_advanceToNextOrFallback()` can await it if the queue becomes
  /// exhausted before the prefetch completes.
  Future<void>? _currentRefillFuture;

  bool get _autoNextEnabled =>
      playNextSongAutomatically.value || _singleSongAutoNext;

  String? _lastError;
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 3;

  static const int _maxHistorySize = 50;
  static const int _queueLookahead = 3;

  /// Start a background refill when fewer than this many upcoming songs remain.
  static const int _refillThreshold = 5;

  /// Target number of upcoming YouTube songs to maintain in the queue.
  static const int _targetUpcomingSongs = 10;
  static const int _maxConcurrentPreloads = 2;
  static const Duration _errorRetryDelay = Duration(seconds: 2);
  static const Duration _songTransitionTimeout = Duration(seconds: 30);
  static const Duration _debounceInterval = Duration(milliseconds: 150);
  static const Duration _positionDataThreshold = Duration(milliseconds: 250);
  static const Duration _playbackStateHeartbeat = Duration(seconds: 1);

  static const String _recentMediaIdPrefix = 'recent:';

  int _activePreloadCount = 0;
  final Set<String> _preloadingYtIds = <String>{};
  final Set<String> _preloadedYtIds = <String>{};

  late final Stream<PositionData> _positionDataStream =
      Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
        audioPlayer.positionStream,
        audioPlayer.bufferedPositionStream,
        audioPlayer.durationStream,
        (position, bufferedPosition, duration) =>
            PositionData(position, bufferedPosition, duration ?? Duration.zero),
      ).distinct((prev, curr) {
        return (prev.position - curr.position).abs() < _positionDataThreshold &&
            prev.duration == curr.duration &&
            (prev.bufferedPosition - curr.bufferedPosition).abs() <
                _positionDataThreshold;
      }).asBroadcastStream();

  Stream<PositionData> get positionDataStream => _positionDataStream;

  late final Stream<PlaybackState> _playbackStateStream = playbackState
      .distinct((prev, curr) {
        final prevPositionBucket =
            prev.updatePosition.inMilliseconds ~/
            _positionDataThreshold.inMilliseconds;
        final currPositionBucket =
            curr.updatePosition.inMilliseconds ~/
            _positionDataThreshold.inMilliseconds;
        return prev.playing == curr.playing &&
            prev.processingState == curr.processingState &&
            prev.queueIndex == curr.queueIndex &&
            prev.speed == curr.speed &&
            prevPositionBucket == currPositionBucket;
      })
      .asBroadcastStream();

  Stream<PlaybackState> get playbackStateStream => _playbackStateStream;

  List<MediaControl> _controls(bool playing) {
    final canSkipNext = hasNext;
    final canSkipPrevious = hasPrevious;

    return [
      if (canSkipPrevious) MediaControl.skipToPrevious else MediaControl.rewind,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.stop,
      if (canSkipNext) MediaControl.skipToNext else MediaControl.fastForward,
    ];
  }

  final _processingStateMap = {
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void _logStreamError(String message, Object error, StackTrace stackTrace) {
    logger.log(message, error: error, stackTrace: stackTrace);
  }

  void _setupEventSubscriptions() {
    audioPlayer.playbackEventStream
        .throttleTime(const Duration(milliseconds: 100))
        .listen(
          (event) {
            _updatePlaybackState();
          },
          onError: (error, stackTrace) {
            _logStreamError('Playback event stream error', error, stackTrace);
          },
        );

    audioPlayer.processingStateStream.distinct().listen(
      _handleProcessingStateChange,
      onError: (error, stackTrace) {
        _logStreamError('Processing state stream error', error, stackTrace);
      },
    );

    audioPlayer.durationStream.listen(
      (duration) {
        if (_currentQueueIndex < _queueList.length && duration != null) {
          _updateCurrentMediaItemWithDuration(duration);
        }
      },
      onError: (error, stackTrace) {
        _logStreamError('Duration stream error', error, stackTrace);
      },
    );

    audioPlayer.playerStateStream
        .distinct()
        .throttleTime(const Duration(milliseconds: 100))
        .listen(
          (state) {
            listeningStatsService.handlePlayerStateForListeningStats(
              state,
              currentSong: currentSong,
            );
            if (state.processingState == ProcessingState.idle &&
                !state.playing &&
                _lastError != null) {
              Future.microtask(_handlePlaybackError);
            }
            _debouncedStateUpdate();
          },
          onError: (error, stackTrace) {
            _logStreamError('Player state stream error', error, stackTrace);
          },
        );

    Rx.combineLatest2(
          audioPlayer.currentIndexStream.distinct(),
          audioPlayer.sequenceStateStream.distinct(),
          (index, sequence) => {'index': index, 'sequence': sequence},
        )
        .throttleTime(const Duration(milliseconds: 100))
        .listen(
          (_) => _debouncedStateUpdate(),
          onError: (error, stackTrace) {
            _logStreamError('Current index stream error', error, stackTrace);
          },
        );
  }

  void _debouncedStateUpdate() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceInterval, () {
      if (!_isUpdatingState) {
        _updatePlaybackState();
      }
    });
  }

  void _hydrateQueueEntryIds() {
    _queueEntryIds
      ..ensureIds(_queueList)
      ..ensureIds(_originalQueueList);
  }

  MediaItem _getMediaItemForQueue(Map song) {
    return mapToMediaItem(song).copyWith(id: _queueEntryIds.ensureId(song));
  }

  List<MediaItem> _buildQueueMediaItems() =>
      _queueList.map(_getMediaItemForQueue).toList(growable: false);

  bool _shouldUpdateDuration(Duration? currentDuration, Duration nextDuration) {
    return currentDuration == null ||
        !durationEquals(currentDuration, nextDuration);
  }

  bool _isCurrentMediaItemMatchingSong(
    MediaItem? currentItem,
    MediaItem currentQueueMediaItem,
    String? currentSongYtid,
  ) {
    if (currentItem == null) return false;

    if (currentItem.id == currentQueueMediaItem.id) {
      return true;
    }

    return currentSongYtid != null &&
        currentSongYtid.isNotEmpty &&
        currentItem.extras?['ytid']?.toString() == currentSongYtid;
  }

  void _updateCurrentMediaItemWithDuration(Duration duration) {
    try {
      final queueIndex = _currentQueueIndex;
      if (queueIndex < 0 || queueIndex >= _queueList.length) return;

      final currentSong = _queueList[queueIndex];
      final currentMediaItem = _getMediaItemForQueue(currentSong);
      final currentSongYtid = currentSong['ytid']?.toString();
      final currentItem = mediaItem.valueOrNull;
      final isMatchingCurrentItem = _isCurrentMediaItemMatchingSong(
        currentItem,
        currentMediaItem,
        currentSongYtid,
      );

      if (currentItem != null &&
          isMatchingCurrentItem &&
          _shouldUpdateDuration(currentItem.duration, duration)) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      } else if (!isMatchingCurrentItem) {
        mediaItem.add(currentMediaItem.copyWith(duration: duration));
      }

      listeningStatsService.updateListeningSessionDuration(
        currentSongYtid,
        duration,
      );

      final existingQueue = queue.valueOrNull;
      if (existingQueue != null && queueIndex < existingQueue.length) {
        final queueItem = existingQueue[queueIndex];
        if (_shouldUpdateDuration(queueItem.duration, duration)) {
          final updatedQueue = List<MediaItem>.from(existingQueue);
          updatedQueue[queueIndex] = queueItem.copyWith(duration: duration);
          queue.add(updatedQueue);
        }
        return;
      }

      final rebuiltQueue = _buildQueueMediaItems();
      if (queueIndex < rebuiltQueue.length) {
        rebuiltQueue[queueIndex] = rebuiltQueue[queueIndex].copyWith(
          duration: duration,
        );
      }
      queue.add(rebuiltQueue);
    } catch (e, stackTrace) {
      logger.log(
        'Error updating media item with duration',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void resetListeningStatsSession({
    bool countCurrentTick = false,
    bool flushStats = true,
  }) {
    listeningStatsService.finishListeningSession(
      countCurrentTick: countCurrentTick,
      flushStats: flushStats,
    );
  }

  void startListeningStatsSessionIfNeeded() {
    listeningStatsService.startListeningSessionIfNeeded(
      currentSong: currentSong,
      isPlaying: audioPlayer.playing,
    );
  }

  Future<void> _initialize() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Always set loop mode to off - we handle all repeating through _handleSongCompletion
      // This ensures ProcessingState.completed is always fired for song transitions
      await audioPlayer.setLoopMode(LoopMode.off);

      // Apply stored shuffle mode to audio player
      await audioPlayer.setShuffleModeEnabled(shuffleNotifier.value);

      // Initialize equalizer once at startup
      unawaited(_ensureEqualizerConfigured());
    } catch (e, stackTrace) {
      logger.log(
        'Error initializing audio session',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _ensureEqualizerConfigured({bool force = false}) async {
    if (_equalizerInitialized) return true;

    final now = DateTime.now();
    if (!force && now.isBefore(_equalizerRetryNotBefore)) {
      return false;
    }

    if (!force && audioPlayer.audioSource == null) {
      return false;
    }

    final inFlight = _equalizerInitFuture;
    if (inFlight != null) {
      return inFlight;
    }

    _equalizerInitFuture = _configureEqualizer();
    try {
      return await _equalizerInitFuture!;
    } finally {
      _equalizerInitFuture = null;
    }
  }

  Future<bool> _configureEqualizer() async {
    try {
      final params = await _androidEqualizer.parameters.timeout(
        const Duration(seconds: 3),
      );

      final savedGains = equalizerBandGains.value;
      if (savedGains.isNotEmpty) {
        for (var i = 0; i < params.bands.length && i < savedGains.length; i++) {
          final clamped = savedGains[i].clamp(
            params.minDecibels,
            params.maxDecibels,
          );
          await params.bands[i].setGain(clamped);
        }
      }

      await _androidEqualizer.setEnabled(equalizerEnabled.value);
      _equalizerInitialized = true;
      _equalizerRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);
      return true;
    } catch (e, stackTrace) {
      _equalizerRetryNotBefore = DateTime.now().add(
        const Duration(seconds: 10),
      );
      logger.log(
        'Equalizer initialization deferred',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<AndroidEqualizerParameters?> getEqualizerParameters() async {
    final initialized = await _ensureEqualizerConfigured();
    if (!initialized) return null;
    try {
      return await _androidEqualizer.parameters.timeout(
        const Duration(seconds: 2),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to get equalizer parameters',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    final initialized = await _ensureEqualizerConfigured(force: true);
    if (!initialized) return;
    try {
      await _androidEqualizer.setEnabled(enabled);
      equalizerEnabled.value = enabled;
      unawaited(addOrUpdateData<bool>('settings', 'equalizerEnabled', enabled));
    } catch (e, stackTrace) {
      logger.log(
        'Failed to set equalizer enabled state',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> setEqualizerBandGain(int index, double gain) async {
    final initialized = await _ensureEqualizerConfigured(force: true);
    if (!initialized) return;

    try {
      final params = await _androidEqualizer.parameters;
      if (index < 0 || index >= params.bands.length) {
        return;
      }

      final clamped = gain.clamp(params.minDecibels, params.maxDecibels);
      await params.bands[index].setGain(clamped);

      final gains = params.bands.map((band) => band.gain).toList();
      equalizerBandGains.value = gains;
      unawaited(
        addOrUpdateData<List<double>>('settings', 'equalizerBandGains', gains),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to set equalizer band gain',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> resetEqualizerBands() async {
    final initialized = await _ensureEqualizerConfigured(force: true);
    if (!initialized) return;

    try {
      final params = await _androidEqualizer.parameters;
      for (final band in params.bands) {
        await band.setGain(0);
      }
      final gains = List<double>.filled(params.bands.length, 0);
      equalizerBandGains.value = gains;
      unawaited(
        addOrUpdateData<List<double>>('settings', 'equalizerBandGains', gains),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to reset equalizer bands',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _hasSignificantPositionChange(
    Duration currentPosition,
    Duration lastUpdatePosition,
    DateTime lastUpdateTime,
    DateTime now,
    double speed,
  ) {
    final expectedPosition =
        lastUpdatePosition + (now.difference(lastUpdateTime)) * speed;
    return (currentPosition - expectedPosition).abs() >
        const Duration(milliseconds: 500);
  }

  void _updatePlaybackState() {
    if (_isUpdatingState) {
      _pendingPlaybackStateUpdate = true;
      return;
    }

    _isUpdatingState = true;

    try {
      final now = DateTime.now();
      final currentPosition = audioPlayer.position;
      final isPlaying = audioPlayer.playing;
      final currentState = playbackState.valueOrNull;
      final newProcessingState =
          _processingStateMap[audioPlayer.processingState] ??
          AudioProcessingState.idle;
      final bufferedPosition = audioPlayer.bufferedPosition;

      final shouldEmitProgressTick =
          currentState != null &&
          isPlaying &&
          now.difference(currentState.updateTime) >= _playbackStateHeartbeat;
      final hasBufferedPositionChange =
          currentState == null ||
          (bufferedPosition - currentState.bufferedPosition).abs() >=
              const Duration(seconds: 1);

      final shouldUpdate =
          currentState == null ||
          currentState.playing != isPlaying ||
          currentState.processingState != newProcessingState ||
          currentState.queueIndex != _currentQueueIndex ||
          currentState.speed != audioPlayer.speed ||
          shouldEmitProgressTick ||
          hasBufferedPositionChange ||
          (_hasSignificantPositionChange(
            currentPosition,
            currentState.updatePosition,
            currentState.updateTime,
            now,
            currentState.speed,
          ));

      if (shouldUpdate) {
        playbackState.add(
          PlaybackState(
            controls: _controls(isPlaying),
            systemActions: const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            androidCompactActionIndices: const [0, 1, 3],
            processingState: newProcessingState,
            playing: isPlaying,
            updatePosition: currentPosition,
            bufferedPosition: bufferedPosition,
            speed: audioPlayer.speed,
            queueIndex:
                _currentQueueIndex >= 0 &&
                    _currentQueueIndex < _queueList.length
                ? _currentQueueIndex
                : null,
            updateTime: now,
          ),
        );
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error updating playback state',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _isUpdatingState = false;
      if (_pendingPlaybackStateUpdate) {
        _pendingPlaybackStateUpdate = false;
        _updatePlaybackState();
      }
    }
  }

  void _handleProcessingStateChange(ProcessingState state) {
    try {
      debugPrint('[SoundWave AutoNext] PROCESSING STATE: $state');

      if (state == ProcessingState.completed) {
        debugPrint('[SoundWave AutoNext] PROCESSING STATE: completed');
        if (sleepTimerEndOfSong) {
          sleepTimerExpired = true;
          sleepTimerEndOfSong = false;
          stop();
          sleepTimerNotifier.value = null;
          return;
        }

        listeningStatsService.finishListeningSession(
          countCurrentTick: true,
          wasPlaying: true,
        );

        if (sleepTimerExpired) return;

        if (_isHandlingSongCompletion) {
          debugPrint(
            '[SoundWave AutoNext] Already handling song completion, ignoring duplicate event',
          );
          return;
        }

        _isHandlingSongCompletion = true;

        Future.microtask(() async {
          try {
            await _handleSongCompletion();
          } catch (e, stackTrace) {
            logger.log(
              'Error handling song completion in auto-next',
              error: e,
              stackTrace: stackTrace,
            );
          } finally {
            _isHandlingSongCompletion = false;
          }
        });
      } else if (state == ProcessingState.ready) {
        _isHandlingSongCompletion = false;
        sleepTimerExpired = false;
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error handling processing state change',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _canRetryPlayback() =>
      hasNext ||
      (repeatNotifier.value == AudioServiceRepeatMode.all &&
          _queueList.isNotEmpty) ||
      _autoNextEnabled;

  void _handlePlaybackError() {
    _consecutiveErrors++;
    logger.log(
      'Playback error occurred. Consecutive errors: $_consecutiveErrors',
      error: _lastError,
    );

    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      logger.log('Max consecutive errors reached. Stopping playback.');
      stop();
      return;
    }

    if (_canRetryPlayback()) {
      Future.delayed(_errorRetryDelay, skipToNext);
    } else {
      _lastError = null;
    }
  }

  Future<void> _handleSongCompletion() async {
    try {
      if (_currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length) {
        _addToHistory(_queueList[_currentQueueIndex]);
      }

      final repeatMode = repeatNotifier.value;
      debugPrint('[SoundWave AutoNext] REPEAT MODE: $repeatMode');

      if (repeatMode == AudioServiceRepeatMode.one) {
        debugPrint('[SoundWave AutoNext] Repeat ONE -> playAgain()');
        await playAgain();
      } else {
        debugPrint(
          '[SoundWave AutoNext] Advancing via _advanceToNextOrFallback()',
        );
        await _advanceToNextOrFallback();
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error handling song completion',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Checks whether the upcoming queue depth is below [_refillThreshold] and,
  /// if so, starts a background YouTube recommendation refill without blocking
  /// playback. Multiple concurrent calls are no-ops (guarded by
  /// [_isRefillInProgress]).
  void _scheduleQueueRefillIfNeeded() {
    if (!_autoNextEnabled || offlineMode.value || _isRefillInProgress) return;

    final upcomingCount = _queueList.length - _currentQueueIndex - 1;
    debugPrint('[SoundWave Recommendation] UPCOMING COUNT: $upcomingCount');

    if (upcomingCount < _refillThreshold) {
      debugPrint(
        '[SoundWave Recommendation] Queue depth below threshold — scheduling refill',
      );
      final future = _refillRecommendationQueue();
      _currentRefillFuture = future;
      unawaited(future);
    }
  }

  /// Fetches multiple YouTube recommendations via [RecommendationEngine] and
  /// appends valid, non-duplicate candidates to [_queueList].
  ///
  /// Jamendo is never involved here. Guarded against:
  ///   • concurrent runs   — [_isRefillInProgress] flag
  ///   • stale requests    — [_recommendationGeneration] cancellation token
  ///   • duplicate IDs     — per-item exclusion check before append
  Future<void> _refillRecommendationQueue() async {
    if (_isRefillInProgress) {
      debugPrint(
        '[SoundWave Recommendation] Refill already in progress, skipping',
      );
      return;
    }
    if (!_autoNextEnabled || offlineMode.value) return;

    final baseSong = _getLastPlayedYouTubeSong() ?? currentSong;
    if (baseSong == null) return;

    final baseYtid = baseSong['ytid']?.toString() ?? '';
    if (baseYtid.isEmpty || isJamendoId(baseYtid)) return;

    _isRefillInProgress = true;
    final generation = ++_recommendationGeneration;

    try {
      final upcomingCount = _queueList.length - _currentQueueIndex - 1;
      debugPrint(
        '[SoundWave Recommendation] QUEUE LENGTH: ${_queueList.length}',
      );
      debugPrint('[SoundWave Recommendation] UPCOMING COUNT: $upcomingCount');
      debugPrint(
        '[SoundWave Recommendation] GENERATING YOUTUBE RECOMMENDATIONS',
      );

      final needed = (_targetUpcomingSongs - upcomingCount).clamp(
        1,
        _targetUpcomingSongs,
      );

      // Build exclusion set: current song + already queued + recent history.
      final excludeIds = <String>{
        baseYtid,
        for (final s in _queueList)
          if ((s['ytid']?.toString() ?? '').isNotEmpty) s['ytid']!.toString(),
        for (final s in _historyList.take(20))
          if ((s['ytid']?.toString() ?? '').isNotEmpty) s['ytid']!.toString(),
      };

      final likedIds = {
        for (final s in userLikedSongsList.value.whereType<Map>())
          if ((s['ytid']?.toString() ?? '').isNotEmpty) s['ytid']!.toString(),
      };

      final recentIds = {
        for (final s in userRecentlyPlayed.value.whereType<Map>().take(30))
          if ((s['ytid']?.toString() ?? '').isNotEmpty) s['ytid']!.toString(),
      };

      final recommendations = await RecommendationEngine.instance
          .getRecommendations(
            Map<String, dynamic>.from(baseSong),
            excludeIds,
            limit: needed,
            likedIds: likedIds,
            recentlyPlayedIds: recentIds,
          );

      // Stale-request guard: abort if context changed during async fetch.
      if (generation != _recommendationGeneration) {
        debugPrint('[SoundWave Recommendation] Stale refill cancelled');
        return;
      }

      if (recommendations.isEmpty) {
        debugPrint(
          '[SoundWave Recommendation] No YouTube recommendations found',
        );
        return;
      }

      var added = 0;
      for (final rec in recommendations) {
        // Cancel mid-loop if context changed.
        if (generation != _recommendationGeneration) break;

        final recId = rec['ytid']?.toString() ?? '';
        if (recId.isEmpty) continue;
        // Re-check exclusion — queue may have changed during the async fetch.
        if (_queueList.any((s) => s['ytid']?.toString() == recId)) continue;

        final queueSong = _queueEntryIds.createSong(rec);
        queueSong['isAutoPicked'] = true;
        _queueList.add(queueSong);
        added++;
      }

      if (added > 0) {
        _updateQueueMediaItems();
        debugPrint('[SoundWave Recommendation] ADDING TO QUEUE: $added');
        debugPrint(
          '[SoundWave Recommendation] QUEUE LENGTH AFTER REFILL: ${_queueList.length}',
        );
      }
    } catch (e, st) {
      logger.log(
        'Error in _refillRecommendationQueue',
        error: e,
        stackTrace: st,
      );
    } finally {
      _isRefillInProgress = false;
    }
  }

  void _addToHistory(Map song) {
    try {
      _historyList.insert(0, cloneMap(song));

      if (_historyList.length > _maxHistorySize) {
        _historyList.removeRange(_maxHistorySize, _historyList.length);
      }
    } catch (e, stackTrace) {
      logger.log('Error adding to history', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> addToQueue(Map song, {bool playNext = false}) async {
    try {
      if (song['ytid'] == null || song['ytid'].toString().isEmpty) {
        logger.log('Invalid song data for queue');
        return;
      }

      int insertIndex;

      if (playNext) {
        insertIndex = _currentQueueIndex + 1;
        if (insertIndex < 0) insertIndex = 0;
        if (insertIndex > _queueList.length) {
          insertIndex = _queueList.length;
        }
      } else {
        insertIndex = _queueList.length;
      }

      final queueSong = _queueEntryIds.createSong(song);
      queueSong['isManuallyAdded'] = true;
      _queueList.insert(insertIndex, queueSong);

      if (_currentQueueIndex < 0) {
        _currentQueueIndex = 0;
      }

      _updateQueueMediaItems();
      _cleanupOldPreloadedSongs();

      if (!audioPlayer.playing && _queueList.length == 1) {
        await _playFromQueue(0);
      }
    } catch (e, stackTrace) {
      logger.log('Error adding to queue', error: e, stackTrace: stackTrace);
    }
  }

  void _cleanupOldPreloadedSongs() {
    Future.microtask(() async {
      try {
        final queueYtIds = _queueList
            .map((song) => song['ytid']?.toString())
            .where((ytid) => ytid != null)
            .toSet();

        final oldPreloadedSongs = _preloadedYtIds
            .where((ytid) => !queueYtIds.contains(ytid))
            .toList();

        for (final ytid in oldPreloadedSongs) {
          _preloadedYtIds.remove(ytid);
        }

        final stalePreloadingEntries = _preloadingYtIds
            .where((ytid) => !queueYtIds.contains(ytid))
            .toList();

        for (final ytid in stalePreloadingEntries) {
          _preloadingYtIds.remove(ytid);
        }

        if (oldPreloadedSongs.isNotEmpty || stalePreloadingEntries.isNotEmpty) {
          logger.log(
            'Cleaned up ${oldPreloadedSongs.length + stalePreloadingEntries.length} old preload entries',
          );
        }
      } catch (e, stackTrace) {
        logger.log(
          'Error cleaning up preloaded songs',
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> addPlaylistToQueue(
    List<Map> songs, {
    bool replace = false,
    int? startIndex,
  }) async {
    try {
      final manuallyAddedSongs = replace ? _getUnplayedManualSongs() : <Map>[];
      if (replace) {
        // Cancel any in-flight recommendation refill from previous playback.
        _recommendationGeneration++;
        _isRefillInProgress = false;
        _currentRefillFuture = null;
        _singleSongAutoNext = songs.length == 1 && startIndex == null;
        if (_singleSongAutoNext) {
          debugPrint('[SoundWave AutoNext] SINGLE SONG AUTO-NEXT ENABLED');
        }
        _queueList.clear();
        _originalQueueList.clear();
        _currentQueueIndex = 0;
        _currentLoadingIndex = -1;
        _currentLoadingTransitionId = -1;
        _resetPreloadingState();
        shuffleNotifier.value = false;
        unawaited(Hive.box('settings').put('shuffleEnabled', false));
        await audioPlayer.setShuffleModeEnabled(false);
      }

      int? targetQueueIndex;

      for (var i = 0; i < songs.length; i++) {
        final song = songs[i];
        if (song['ytid'] != null && song['ytid'].toString().isNotEmpty) {
          _queueList.add(_queueEntryIds.createSong(song));

          if (replace && startIndex == i) {
            targetQueueIndex = _queueList.length - 1;
          }
        }
      }

      if (replace && manuallyAddedSongs.isNotEmpty) {
        // Always insert after the starting song index
        final insertIndex = (targetQueueIndex ?? 0) + 1;
        final safeInsertIndex = insertIndex > _queueList.length
            ? _queueList.length
            : insertIndex;
        _queueList.insertAll(safeInsertIndex, manuallyAddedSongs);
      }

      _hydrateQueueEntryIds();
      _updateQueueMediaItems();

      if (targetQueueIndex != null) {
        await _playFromQueue(targetQueueIndex);
      } else if (startIndex != null &&
          startIndex < _queueList.length &&
          !replace) {
        await _playFromQueue(startIndex);
      } else if (replace && _queueList.isNotEmpty) {
        await _playFromQueue(0);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error adding playlist to queue',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> removeFromQueue(int index) async {
    try {
      if (index < 0 || index >= _queueList.length) return;

      final removedSong = _queueList[index];
      final removedQueueEntryId = _queueEntryIds.ensureId(removedSong);
      _queueList.removeAt(index);

      if (shuffleNotifier.value && _originalQueueList.isNotEmpty) {
        _originalQueueList.removeWhere(
          (s) => _queueEntryIds.ensureId(s) == removedQueueEntryId,
        );
      }

      if (index == _currentLoadingIndex) {
        _currentLoadingIndex = -1;
        _currentLoadingTransitionId = -1;
      } else if (index < _currentLoadingIndex) {
        _currentLoadingIndex--;
      }

      if (index < _currentQueueIndex) {
        _currentQueueIndex--;
      } else if (index == _currentQueueIndex) {
        if (_queueList.isEmpty) {
          await stop();
        } else {
          if (_currentQueueIndex >= _queueList.length) {
            _currentQueueIndex = _queueList.length - 1;
          }
          await _playFromQueue(_currentQueueIndex);
        }
      }

      _hydrateQueueEntryIds();
      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log('Error removing from queue', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    try {
      _queueEntryIds.ensureIds(_queueList);

      if (oldIndex < 0 ||
          oldIndex >= _queueList.length ||
          newIndex < 0 ||
          newIndex > _queueList.length - 1) {
        return;
      }

      final song = _queueList.removeAt(oldIndex);
      _queueList.insert(newIndex, song);

      if (oldIndex == _currentQueueIndex) {
        _currentQueueIndex = newIndex;
      } else if (oldIndex < _currentQueueIndex &&
          newIndex >= _currentQueueIndex) {
        _currentQueueIndex--;
      } else if (oldIndex > _currentQueueIndex &&
          newIndex <= _currentQueueIndex) {
        _currentQueueIndex++;
      }

      // Also update _currentLoadingIndex if the currently-loading song is being reordered
      if (oldIndex == _currentLoadingIndex) {
        _currentLoadingIndex = newIndex;
      } else if (oldIndex < _currentLoadingIndex &&
          newIndex >= _currentLoadingIndex) {
        _currentLoadingIndex--;
      } else if (oldIndex > _currentLoadingIndex &&
          newIndex <= _currentLoadingIndex) {
        _currentLoadingIndex++;
      }

      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log('Error reordering queue', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> reorderQueueById(String queueEntryId, int targetIndex) async {
    try {
      _queueEntryIds.ensureIds(_queueList);

      final oldIndex = _queueList.indexWhere(
        (s) => _queueEntryIds.ensureId(s) == queueEntryId,
      );
      if (oldIndex == -1) return;

      // Clamp target index to valid range (allow insert at end)
      if (targetIndex < 0) targetIndex = 0;
      if (targetIndex > _queueList.length) targetIndex = _queueList.length;

      final song = _queueList.removeAt(oldIndex);
      var newIndex = targetIndex;
      if (newIndex > _queueList.length) newIndex = _queueList.length;
      _queueList.insert(newIndex, song);

      if (oldIndex == _currentQueueIndex) {
        _currentQueueIndex = newIndex;
      } else if (oldIndex < _currentQueueIndex &&
          newIndex >= _currentQueueIndex) {
        _currentQueueIndex--;
      } else if (oldIndex > _currentQueueIndex &&
          newIndex <= _currentQueueIndex) {
        _currentQueueIndex++;
      }

      if (oldIndex == _currentLoadingIndex) {
        _currentLoadingIndex = newIndex;
      } else if (oldIndex < _currentLoadingIndex &&
          newIndex >= _currentLoadingIndex) {
        _currentLoadingIndex--;
      } else if (oldIndex > _currentLoadingIndex &&
          newIndex <= _currentLoadingIndex) {
        _currentLoadingIndex++;
      }

      _updateQueueMediaItems();
    } catch (e, stackTrace) {
      logger.log(
        'Error reordering queue by id',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void clearQueue() {
    try {
      final currentSong =
          _currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length
          ? cloneMap(_queueList[_currentQueueIndex])
          : null;

      // Cancel any in-flight recommendation refill.
      _recommendationGeneration++;
      _isRefillInProgress = false;
      _currentRefillFuture = null;
      _queueList.clear();
      _originalQueueList.clear();

      if (currentSong != null) {
        _queueList.add(currentSong);
        _originalQueueList.add(cloneMap(currentSong));
      }

      _currentQueueIndex = 0;
      _currentLoadingIndex = -1;
      _currentLoadingTransitionId = -1;
      _resetPreloadingState();
      _updateQueueMediaItems();
      _updatePlaybackState();
    } catch (e, stackTrace) {
      logger.log('Error clearing queue', error: e, stackTrace: stackTrace);
    }
  }

  void _updateQueueMediaItems() {
    try {
      _queueEntryIds.ensureIds(_queueList);

      final mediaItems = _buildQueueMediaItems();
      queue.add(mediaItems);

      _queueMapStream.add(List.unmodifiable(_queueList));

      if (_currentQueueIndex < mediaItems.length) {
        final currentMediaItem = mediaItems[_currentQueueIndex];
        mediaItem.add(currentMediaItem);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error updating queue media items',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void _emitOptimisticLoadingState({
    Map? song,
    int? queueIndex,
    bool includeMediaItem = false,
    String? mediaId,
  }) {
    try {
      if (includeMediaItem && song != null) {
        var immediateMediaItem = mapToMediaItem(song);
        if (mediaId != null) {
          immediateMediaItem = immediateMediaItem.copyWith(id: mediaId);
        }
        Future.microtask(() {
          mediaItem.add(immediateMediaItem);
        });
      }

      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            MediaControl.pause,
            MediaControl.stop,
            MediaControl.skipToNext,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
          androidCompactActionIndices: const [0, 1, 3],
          processingState: AudioProcessingState.loading,
          queueIndex:
              queueIndex ??
              (_currentQueueIndex < _queueList.length
                  ? _currentQueueIndex
                  : null),
          updateTime: DateTime.now(),
        ),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Error emitting optimistic loading state',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _playFromQueue(
    int index, {
    bool suppressAutoRetry = false,
  }) async {
    if (index < 0 || index >= _queueList.length) {
      logger.log('Invalid queue index: $index');
      return false;
    }

    // If this exact song is already actively loading, avoid redundant duplicate load
    if (_currentLoadingIndex == index) {
      debugPrint(
        '[SoundWave AutoNext] Song at index $index is already loading, skipping duplicate request',
      );
      return false;
    }

    // Start new transition
    _songTransitionCounter++;
    final currentTransitionId = _songTransitionCounter;
    _currentLoadingIndex = index;
    _currentLoadingTransitionId = currentTransitionId;

    try {
      final previousQueueIndex = _currentQueueIndex;
      final previousMediaItem = mediaItem.valueOrNull;
      _currentQueueIndex = index;

      final currentSong = _queueList[_currentQueueIndex];
      final currentMediaItem = _getMediaItemForQueue(currentSong);
      final uniqueId = currentMediaItem.id;

      await Future.microtask(() {
        mediaItem.add(currentMediaItem);
      });

      _emitOptimisticLoadingState(
        queueIndex: _currentQueueIndex,
        mediaId: uniqueId,
      );

      final success = await playSong(
        _queueList[index],
        mediaId: uniqueId,
        transitionId: currentTransitionId,
      );

      // Only process result if this is still the current transition
      if (currentTransitionId == _currentLoadingTransitionId) {
        if (success) {
          _consecutiveErrors = 0;
          _preloadUpcomingSongs();
          // Trigger background recommendation refill if the queue is running low.
          _scheduleQueueRefillIfNeeded();
          return true;
        } else {
          debugPrint(
            '[SoundWave AutoNext] Playback failed for index $index, reverting queue index',
          );
          _currentQueueIndex = previousQueueIndex;
          if (previousMediaItem != null) {
            mediaItem.add(previousMediaItem);
          }
          _updatePlaybackState();
          if (!suppressAutoRetry) {
            _handlePlaybackError();
          } else {
            _lastError = null;
          }
          return false;
        }
      }
      return false;
    } catch (e, stackTrace) {
      logger.log('Error playing from queue', error: e, stackTrace: stackTrace);
      if (!suppressAutoRetry) {
        _handlePlaybackError();
      } else {
        _lastError = null;
      }
      return false;
    } finally {
      // Only reset if this is still the transition that started it
      if (currentTransitionId == _currentLoadingTransitionId) {
        _currentLoadingIndex = -1;
        _currentLoadingTransitionId = -1;
      }
    }
  }

  void _preloadUpcomingSongs() {
    // Don't attempt to preload while offline mode is enabled
    if (offlineMode.value) return;

    Future.microtask(() async {
      try {
        final songsToPreload = <Map>[];

        for (var i = 1; i <= _queueLookahead; i++) {
          final nextIndex = _currentQueueIndex + i;
          if (nextIndex < _queueList.length) {
            final nextSong = _queueList[nextIndex];
            final ytid = nextSong['ytid'];

            if (ytid != null &&
                !isSongAlreadyOffline(ytid) &&
                !_preloadedYtIds.contains(ytid) &&
                !_preloadingYtIds.contains(ytid)) {
              songsToPreload.add(nextSong);
            }
          }
        }

        await _preloadSongsSequentially(songsToPreload);
      } catch (e, stackTrace) {
        logger.log(
          'Error in _preloadUpcomingSongs',
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> _preloadSongsSequentially(List<Map> songsToPreload) async {
    for (final song in songsToPreload) {
      while (_activePreloadCount >= _maxConcurrentPreloads) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final ytid = song['ytid'];
      if (ytid == null || _preloadingYtIds.contains(ytid)) {
        continue;
      }

      unawaited(_preloadSingleSongControlled(song));
    }
  }

  Future<void> _preloadSingleSongControlled(Map nextSong) async {
    final ytid = nextSong['ytid'];
    if (ytid == null) return;

    _preloadingYtIds.add(ytid);
    _activePreloadCount++;
    String? preloadUrl;

    try {
      // Don't attempt to fetch remote streams while offline mode is enabled
      if (offlineMode.value) {
        logger.log('Offline mode enabled; skipping preload for $ytid');
        preloadUrl = null;
      } else {
        // fetchSongStreamUrl handles caching, freshness checks, and validation
        preloadUrl = await fetchSongStreamUrl(ytid, nextSong['isLive'] ?? false)
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                logger.log('Preload timeout for song $ytid');
                return null;
              },
            );
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error preloading song $ytid',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _preloadingYtIds.remove(ytid);
      if (_activePreloadCount > 0) {
        _activePreloadCount--;
      }
      if (preloadUrl != null && preloadUrl.isNotEmpty) {
        _preloadedYtIds.add(ytid);
      }
    }
  }

  Stream<List<Map>> get queueAsMapStream => _queueMapStream.stream;
  int get currentQueueIndex => _currentQueueIndex;
  Map? get currentSong =>
      _currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length
      ? _queueList[_currentQueueIndex]
      : null;

  bool get hasNext =>
      _currentQueueIndex < _queueList.length - 1 || _autoNextEnabled;

  bool get hasPrevious => _currentQueueIndex > 0 || _historyList.isNotEmpty;

  String _recentMediaId(String ytid) => '$_recentMediaIdPrefix$ytid';

  String? _ytidFromMediaId(String mediaId) {
    if (mediaId.startsWith(_recentMediaIdPrefix)) {
      return mediaId.substring(_recentMediaIdPrefix.length);
    }
    return mediaId.isEmpty ? null : mediaId;
  }

  String? _songYtid(Map song) {
    final ytid = song['ytid']?.toString();
    return ytid == null || ytid.isEmpty ? null : ytid;
  }

  Map? _firstPlayableSong(Iterable songs) {
    for (final song in songs.whereType<Map>()) {
      if (_songYtid(song) != null) {
        return song;
      }
    }
    return null;
  }

  Map? _findSongInList(Iterable songs, String ytid) {
    for (final song in songs.whereType<Map>()) {
      if (_songYtid(song) == ytid) {
        return song;
      }
    }
    return null;
  }

  Map? _findSongByYtid(String? ytid) {
    if (ytid == null || ytid.isEmpty) return null;

    final activeSong = currentSong;
    if (activeSong?['ytid']?.toString() == ytid) {
      return activeSong;
    }

    for (final source in [
      _queueList,
      userRecentlyPlayed.value,
      userOfflineSongs.value,
      userLikedSongsList.value,
    ]) {
      final song = _findSongInList(source, ytid);
      if (song != null) return song;
    }

    return null;
  }

  Map? _latestResumableSong() {
    final activeSong = currentSong;
    if (activeSong != null && _songYtid(activeSong) != null) {
      return activeSong;
    }

    final activeMediaItem = mediaItem.valueOrNull;
    final activeYtid = activeMediaItem?.extras?['ytid']?.toString();
    final activeMediaSong = _findSongByYtid(activeYtid);
    if (activeMediaSong != null) return activeMediaSong;
    if (activeYtid != null &&
        activeYtid.isNotEmpty &&
        activeMediaItem != null) {
      return mediaItemToMap(activeMediaItem);
    }

    return _firstPlayableSong(userRecentlyPlayed.value) ??
        _firstPlayableSong(userOfflineSongs.value) ??
        _firstPlayableSong(userLikedSongsList.value);
  }

  Map<String, dynamic>? _normaliseResumableSong(Map song) {
    final ytid = _songYtid(song);
    if (ytid == null) return null;

    final normalised = cloneMap(song);
    normalised['id'] = ytid;
    normalised['ytid'] = ytid;
    normalised['highResImage'] ??=
        normalised['image'] ?? normalised['lowResImage'] ?? '';
    normalised['lowResImage'] ??= normalised['highResImage'];
    normalised['isLive'] ??= false;
    return normalised;
  }

  MediaItem? _mediaItemForResumption(Map song) {
    final normalisedSong = _normaliseResumableSong(song);
    if (normalisedSong == null) return null;

    final ytid = normalisedSong['ytid'].toString();
    final artist = normalisedSong['artist']?.toString().trim() ?? '';
    return mapToMediaItem(normalisedSong).copyWith(
      id: _recentMediaId(ytid),
      displayTitle: normalisedSong['title']?.toString(),
      displaySubtitle: artist.isEmpty ? 'SoundWave' : artist,
    );
  }

  Future<void> _playResumableSong(Map song) async {
    final normalisedSong = _normaliseResumableSong(song);
    if (normalisedSong == null) return;

    await playPlaylistSong(
      playlist: {
        'title': 'SoundWave',
        'source': 'system-recent',
        'list': [normalisedSong],
      },
      songIndex: 0,
    );
  }

  static const _rootLiked = 'liked_songs';
  static const _rootOffline = 'offline_songs';
  static const _rootRecent = 'recently_played';
  static const _rootQueue = 'current_queue';

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == AudioService.recentRootId) {
      final recentSong = _latestResumableSong();
      final recentItem = recentSong == null
          ? null
          : _mediaItemForResumption(recentSong);
      return recentItem == null ? [] : [recentItem];
    }

    if (parentMediaId == AudioService.browsableRootId) {
      return [
        const MediaItem(
          id: _rootQueue,
          title: 'Now Playing Queue',
          playable: false,
          extras: {'isBrowsable': true},
        ),
        const MediaItem(
          id: _rootLiked,
          title: 'Liked Songs',
          playable: false,
          extras: {'isBrowsable': true},
        ),
        const MediaItem(
          id: _rootOffline,
          title: 'Downloaded',
          playable: false,
          extras: {'isBrowsable': true},
        ),
        const MediaItem(
          id: _rootRecent,
          title: 'Recently Played',
          playable: false,
          extras: {'isBrowsable': true},
        ),
      ];
    }

    switch (parentMediaId) {
      case _rootQueue:
        return _queueList.map(_getMediaItemForQueue).toList();
      case _rootLiked:
        return userLikedSongsList.value
            .whereType<Map>()
            .map((s) => mapToMediaItem(s).copyWith(playable: true))
            .toList();
      case _rootOffline:
        return userOfflineSongs.value
            .whereType<Map>()
            .map((s) => mapToMediaItem(s).copyWith(playable: true))
            .toList();
      case _rootRecent:
        return userRecentlyPlayed.value
            .whereType<Map>()
            .map((s) => mapToMediaItem(s).copyWith(playable: true))
            .toList();
      default:
        return [];
    }
  }

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (query.trim().isEmpty) {
      // "Play music" with no specifics
      if (_queueList.isNotEmpty) {
        await play();
        return;
      }
      final recentSong = _latestResumableSong();
      if (recentSong != null) await _playResumableSong(recentSong);
      return;
    }

    final q = query.trim().toLowerCase();
    final candidates = [
      ..._queueList,
      ...userLikedSongsList.value.whereType<Map>(),
      ...userOfflineSongs.value.whereType<Map>(),
      ...userRecentlyPlayed.value.whereType<Map>(),
    ];

    final match = candidates.firstWhere((s) {
      final title = s['title']?.toString().toLowerCase() ?? '';
      final artist = s['artist']?.toString().toLowerCase() ?? '';
      return title.contains(q) || artist.contains(q);
    }, orElse: () => const {});

    if (match.isNotEmpty) {
      await _playResumableSong(match);
    } else {
      logger.log('playFromSearch: no local match for "$query"');
    }
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final song = _findSongByYtid(_ytidFromMediaId(mediaId));
    return song == null ? null : _mediaItemForResumption(song);
  }

  @override
  Future<void> prepareFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final item = await getMediaItem(mediaId);
    if (item == null) return;

    mediaItem.add(item);
    queue.add([item]);
    playbackState.add(
      PlaybackState(
        controls: _controls(false),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: AudioProcessingState.ready,
        queueIndex: 0,
        updateTime: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final song = _findSongByYtid(_ytidFromMediaId(mediaId));
    if (song == null) {
      logger.log('No resumable song found for media id: $mediaId');
      return;
    }
    await _playResumableSong(song);
  }

  @override
  Future<void> onTaskRemoved() async {
    try {
      await stop();
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e, stackTrace) {
      logger.log('Error in onTaskRemoved', error: e, stackTrace: stackTrace);
    }
    await super.onTaskRemoved();
  }

  @override
  Future<void> play() async {
    try {
      if (audioPlayer.audioSource == null) {
        final recentSong = _latestResumableSong();
        if (recentSong != null) {
          await _playResumableSong(recentSong);
          return;
        }
      }
      // Do NOT await play(): its future only completes when playback pauses/
      // stops/finishes (just_audio semantics), which would defer the resume
      // below until the song ended - losing the whole session.
      unawaited(
        audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
          logger.log(
            'Error starting playback',
            error: e,
            stackTrace: stackTrace,
          );
          _lastError = e.toString();
        }),
      );
      listeningStatsService.resumeListeningSession(currentSong: currentSong);
    } catch (e, stackTrace) {
      logger.log('Error in play()', error: e, stackTrace: stackTrace);
      _lastError = e.toString();
    }
  }

  @override
  Future<void> pause() async {
    try {
      listeningStatsService.recordListeningSessionProgress(
        wasPlaying: audioPlayer.playing,
      );
      unawaited(listeningStatsService.flush());
      await audioPlayer.pause();
    } catch (e, stackTrace) {
      logger.log('Error in pause()', error: e, stackTrace: stackTrace);
    }
  }

  @override
  Future<void> stop() async {
    _debounceTimer?.cancel();
    _isAdvancingQueue = false;
    _isHandlingSongCompletion = false;
    _singleSongAutoNext = false;
    // Cancel any in-flight recommendation refill.
    _recommendationGeneration++;
    _isRefillInProgress = false;
    _currentRefillFuture = null;
    _currentLoadingIndex = -1;
    _currentLoadingTransitionId = -1;
    _lastError = null;
    _consecutiveErrors = 0;
    try {
      listeningStatsService.finishListeningSession(
        countCurrentTick: true,
        wasPlaying: audioPlayer.playing,
      );
      await audioPlayer.stop();
      _resetPreloadingState();
    } catch (e, stackTrace) {
      logger.log('Error in stop()', error: e, stackTrace: stackTrace);
    }
    await super.stop();
  }

  /// Returns unplayed manually added songs after the current queue index.
  List<Map> _getUnplayedManualSongs() {
    return _queueList
        .skip(_currentQueueIndex >= 0 ? _currentQueueIndex + 1 : 0)
        .where(
          (song) =>
              song['isManuallyAdded'] == true && song['isAutoPicked'] != true,
        )
        .toList();
  }

  void _resetPreloadingState() {
    _activePreloadCount = 0;
    _preloadingYtIds.clear();
    _preloadedYtIds.clear();
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      listeningStatsService.recordListeningSessionProgress(
        wasPlaying: audioPlayer.playing,
      );
      await audioPlayer.seek(position);
      unawaited(listeningStatsService.flush());
    } catch (e, stackTrace) {
      logger.log('Error in seek()', error: e, stackTrace: stackTrace);
    }
  }

  @override
  Future<void> fastForward() {
    final target = audioPlayer.position + const Duration(seconds: 15);
    final trackDuration = audioPlayer.duration;
    final clamped = (trackDuration != null && target > trackDuration)
        ? trackDuration
        : target;
    return seek(clamped);
  }

  @override
  Future<void> rewind() {
    final target = audioPlayer.position - const Duration(seconds: 15);
    final clamped = target < Duration.zero ? Duration.zero : target;
    return seek(clamped);
  }

  Future<bool> _resolveOfflineAndSetPaths(Map songData) async {
    try {
      final ytid = songData['ytid']?.toString();
      if (ytid != null && ytid.isNotEmpty) {
        final offlineSong = getOfflineSongByYtid(ytid);
        if (offlineSong.isNotEmpty) {
          final audioPath = offlineSong['audioPath']?.toString();
          if (audioPath != null && audioPath.isNotEmpty) {
            final f = File(audioPath);
            if (await f.exists()) {
              songData['audioPath'] = audioPath;
              if (offlineSong['artworkPath'] != null) {
                songData['artworkPath'] = offlineSong['artworkPath'];
              }
              return true;
            }
          }
        }
      }
    } catch (e, st) {
      logger.log(
        'Error while checking offline songs',
        error: e,
        stackTrace: st,
      );
    }

    // Fallback: prefer an existing local `audioPath` on the passed song
    // object if the file exists.
    try {
      final path = songData['audioPath']?.toString();
      if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (await f.exists()) return true;
      }
    } catch (_) {}

    return false;
  }

  /// Check if the given transitionId is stale (outdated by a newer request).
  bool _isStaleTransition(int? transitionId) {
    return transitionId != null && transitionId != _currentLoadingTransitionId;
  }

  Future<bool> playSong(Map song, {String? mediaId, int? transitionId}) async {
    try {
      final songData = cloneMap(song);

      if (songData['ytid'] == null || songData['ytid'].toString().isEmpty) {
        logger.log('Invalid song data: missing ytid');
        return false;
      }

      // If called directly from outside _playFromQueue, cancel any running refill.
      if (transitionId == null) {
        _recommendationGeneration++;
        _isRefillInProgress = false;
        _currentRefillFuture = null;
      }

      _lastError = null;
      if (audioPlayer.playing) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: audioPlayer.playing,
        );
        await audioPlayer.pause();
      }

      debugPrint(
        '[SoundWave AutoNext] STREAM URL RESOLUTION: starting for ${songData['ytid']}',
      );
      final playback = await _resolvePlaybackSource(songData);

      // Abort if a newer song was requested while we were fetching the stream URL.
      // This is the primary guard against the race condition where a slow streaming
      // load overrides a song the user already switched to.
      if (_isStaleTransition(transitionId)) {
        logger.log(
          'Song load superseded by newer request, aborting: ${songData['ytid']}',
        );
        return false;
      }

      if (playback == null) {
        debugPrint('[SoundWave AutoNext] STREAM RESOLVED: failed');
        _lastError = 'Failed to get song URL';
        return false;
      }

      debugPrint(
        '[SoundWave AutoNext] STREAM RESOLVED: yes (isOffline: ${playback.isOffline})',
      );

      _emitOptimisticLoadingState(
        song: songData,
        includeMediaItem: true,
        mediaId: mediaId,
      );

      final audioSource = await buildAudioSource(
        songData,
        playback.songUrl,
        playback.isOffline,
      );

      // Check again after building the audio source (SponsorBlock fetch can also be slow).
      if (_isStaleTransition(transitionId)) {
        logger.log(
          'Song load superseded after building audio source, aborting: ${songData['ytid']}',
        );
        return false;
      }

      if (audioSource == null) {
        logger.log('Failed to build audio source for ${songData['ytid']}');
        _lastError = 'Failed to build audio source';
        return false;
      }

      return await _setAudioSourceAndPlay(
        songData,
        audioSource,
        playback.songUrl,
        playback.isOffline,
        mediaId: mediaId,
        transitionId: transitionId,
      );
    } catch (e, stackTrace) {
      logger.log('Error playing song', error: e, stackTrace: stackTrace);
      _lastError = e.toString();
      return false;
    }
  }

  Future<_PlaybackSource?> _resolvePlaybackSource(Map songData) async {
    final isOffline = await _resolveOfflineAndSetPaths(songData);
    if (!isOffline && offlineMode.value) {
      logger.log(
        'Offline mode enabled and no local file found for ${songData['ytid']}',
      );
      return null;
    }

    final songUrl = await _getPlaybackUrl(songData, isOffline);

    if (songUrl == null || songUrl.isEmpty) {
      if (!isOffline) {
        logger.log('Failed to get song URL for ${songData['ytid']}');
        return null;
      }

      // If offline mode is enabled, do NOT fall back to online streams.
      // This prevents network requests while the user explicitly requested
      // offline-only operation.
      try {
        if (offlineMode.value) {
          logger.log(
            'Offline mode enabled and offline file missing for ${songData['ytid']}. Not falling back to online.',
          );
          return null;
        }
      } catch (_) {
        // If offlineMode isn't available for some reason, continue with fallback.
      }

      logger.log(
        'Offline file missing for ${songData['ytid']}, switching to online',
      );

      final onlineUrl = await fetchSongStreamUrl(
        songData['ytid'],
        songData['isLive'] ?? false,
      );

      if (onlineUrl == null || onlineUrl.isEmpty) {
        logger.log('Failed to get song URL for ${songData['ytid']}');
        return null;
      }

      return _PlaybackSource(songUrl: onlineUrl, isOffline: false);
    }

    return _PlaybackSource(songUrl: songUrl, isOffline: isOffline);
  }

  Future<String?> _getPlaybackUrl(Map song, bool isOffline) async {
    if (isOffline) {
      return _getOfflineSongUrl(song);
    }

    final ytid = song['ytid']?.toString() ?? '';

    // Fast-path for Jamendo songs: use the pre-resolved audio URL that was
    // embedded in the song map at search time (avoids an extra API call).
    // The JamendoService in-memory cache is also checked via fetchSongStreamUrl
    // if the pre-resolved URL is absent or empty.
    if (isJamendoId(ytid)) {
      final preResolved = song['jamendoAudioUrl']?.toString();
      if (preResolved != null && preResolved.isNotEmpty) {
        return preResolved;
      }
    }

    return fetchSongStreamUrl(ytid, song['isLive'] ?? false);
  }

  Future<String?> _getOfflineSongUrl(Map song) async {
    final audioPath = song['audioPath']?.toString();
    if (audioPath == null || audioPath.isEmpty) {
      logger.log('Missing audioPath for offline song: ${song['ytid']}');
      return null;
    }

    final file = File(audioPath);
    if (await file.exists()) {
      return audioPath;
    }

    logger.log('Offline audio file not found: $audioPath');

    final offlineSong = userOfflineSongs.value.firstWhere(
      (s) => s['ytid'] == song['ytid'],
      orElse: () => <String, dynamic>{},
    );

    if (offlineSong.isNotEmpty && offlineSong['audioPath'] != null) {
      final fallbackPath = offlineSong['audioPath']?.toString();
      if (fallbackPath == null || fallbackPath.isEmpty) return null;
      final fallbackFile = File(fallbackPath);
      if (await fallbackFile.exists()) {
        song['audioPath'] = fallbackPath;
        return fallbackPath;
      }
    }

    return null;
  }

  Future<bool> _setAudioSourceAndPlay(
    Map song,
    AudioSource audioSource,
    String songUrl,
    bool isOffline, {
    String? mediaId,
    bool allowOnlineRetry = true,
    int? transitionId,
  }) async {
    try {
      // Final staleness check before we touch the audio player.
      // If another song was requested between the URL fetch and here, abort.
      if (_isStaleTransition(transitionId)) {
        return false;
      }

      // Snapshot the pre-swap playing state now: by the time we're committed
      // to this transition (below), audioPlayer.playing reflects the new
      // source, not whatever session we're about to finish.
      final wasPlayingBeforeSwap = audioPlayer.playing;

      await audioPlayer
          .setAudioSource(audioSource)
          .timeout(_songTransitionTimeout);

      // Check once more after the async setAudioSource: a fast offline song
      // could have loaded and started playing while we were buffering/setting up.
      // If so, stop the source we just loaded and yield to the newer song.
      if (_isStaleTransition(transitionId)) {
        unawaited(audioPlayer.stop());
        return false;
      }

      if (audioPlayer.duration != null) {
        _updateCurrentMediaItemWithDuration(audioPlayer.duration!);
      }

      // Finish the old session and start the new one as one atomic pair, only
      // after every abort path above is cleared. Finishing before the staleness
      // re-check let a stale transition kill a newer transition's session.
      // Do this before awaiting play() so Wrapped starts counting from the
      // first moments of the new track, not after the async handoff.
      listeningStatsService
        ..finishListeningSession(
          countCurrentTick: true,
          wasPlaying: wasPlayingBeforeSwap,
        )
        ..startListeningSession(song, duration: audioPlayer.duration);
      debugPrint(
        '[SoundWave AutoNext] PLAY COMMAND: unawaited audioPlayer.play()',
      );
      unawaited(
        audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
          logger.log(
            'Error starting playback',
            error: e,
            stackTrace: stackTrace,
          );
          _lastError = e.toString();
        }),
      );
      unawaited(updateRecentlyPlayed(song['ytid'], songFallback: song));

      if (!isOffline) {
        // Do NOT cache Jamendo stream URLs in Hive — they can expire and
        // JamendoService manages its own short-lived in-memory cache.
        if (!isJamendoId(song['ytid']?.toString())) {
          final cacheKey =
              'song_${song['ytid']}_${audioQualitySetting.value}_url';
          unawaited(addOrUpdateData<String>('cache', cacheKey, songUrl));
        }
      }

      _updatePlaybackState();

      Future.delayed(const Duration(seconds: 2), _preloadUpcomingSongs);

      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error setting audio source',
        error: e,
        stackTrace: stackTrace,
      );

      if (isOffline) {
        // If offline mode is explicitly enabled, do not attempt any online
        // fallback — respect the user's offline-only preference.
        try {
          if (offlineMode.value) {
            return false;
          }
        } catch (_) {
          // If offlineMode isn't accessible, fallthrough to attempt fallback.
        }

        return _attemptOfflineFallback(
          song,
          mediaId: mediaId,
          transitionId: transitionId,
        );
      }

      if (allowOnlineRetry) {
        if (offlineMode.value) {
          _lastError = e.toString();
          return false;
        }
        final songId = song['ytid']?.toString();
        if (songId != null && songId.isNotEmpty) {
          // For Jamendo songs, invalidate the in-memory stream cache so the
          // next attempt fetches a fresh URL from the API.
          if (isJamendoId(songId)) {
            final jamendoId = extractJamendoId(songId);
            if (jamendoId != null) {
              JamendoService.instance.invalidateStreamCache(jamendoId);
              // Also remove the pre-resolved URL from the song map so the
              // fast-path in _getPlaybackUrl doesn't serve a stale URL.
              song.remove('jamendoAudioUrl');
            }
          } else {
            await invalidateSongStreamCache(songId);
          }

          final refreshedUrl = await fetchSongStreamUrl(
            songId,
            song['isLive'] ?? false,
          );

          if (refreshedUrl != null && refreshedUrl.isNotEmpty) {
            final refreshedSource = await buildAudioSource(
              song,
              refreshedUrl,
              false,
            );

            if (refreshedSource != null) {
              return _setAudioSourceAndPlay(
                song,
                refreshedSource,
                refreshedUrl,
                false,
                mediaId: mediaId,
                allowOnlineRetry: false,
                transitionId: transitionId,
              );
            }
          }
        }
      }

      _lastError = e.toString();
      return false;
    }
  }

  Future<bool> _attemptOfflineFallback(
    Map song, {
    String? mediaId,
    int? transitionId,
  }) async {
    // Do not attempt any network calls when offline mode is enabled.
    if (offlineMode.value) return false;

    final onlineUrl = await fetchSongStreamUrl(
      song['ytid'],
      song['isLive'] ?? false,
    );
    if (onlineUrl != null && onlineUrl.isNotEmpty) {
      final onlineSource = await buildAudioSource(song, onlineUrl, false);
      if (onlineSource != null) {
        return _setAudioSourceAndPlay(
          song,
          onlineSource,
          onlineUrl,
          false,
          mediaId: mediaId,
          transitionId: transitionId,
        );
      }
    }
    return false;
  }

  Future<void> playNext(Map song) async {
    await addToQueue(song, playNext: true);
  }

  Future<void> playPlaylistSong({
    Map<dynamic, dynamic>? playlist,
    required int songIndex,
  }) async {
    try {
      if (playlist != null && playlist['list'] != null) {
        await addPlaylistToQueue(
          List<Map>.from(playlist['list']),
          replace: true,
          startIndex: songIndex,
        );
      }
    } catch (e, stackTrace) {
      logger.log('Error playing playlist', error: e, stackTrace: stackTrace);
    }
  }

  /// Play a radio stream directly without queue management
  Future<bool> playRadioStream({
    required String id,
    required String name,
    required String streamUrl,
    required String image,
    String? genre,
  }) async {
    try {
      // Create a song-like map for the radio stream
      final radioSong = {
        'id': id,
        'ytid': id, // Use radio ID as ytid for compatibility
        'title': name,
        'artist': genre ?? 'Radio Station',
        'album': 'Live Stream',
        'highResImage': image,
        'lowResImage': image,
        'duration': null, // Radio streams are live
        'isLive': true,
      };

      _lastError = null;
      final wasPlayingBeforeSwap = audioPlayer.playing;
      if (audioPlayer.playing) {
        listeningStatsService.recordListeningSessionProgress(
          wasPlaying: audioPlayer.playing,
        );
        await audioPlayer.pause();
      }

      // Update media item and queue for mini player visibility
      final mediaItem = mapToMediaItem(radioSong);
      this.mediaItem.add(mediaItem);
      queue.add([mediaItem]);

      // Build audio source from stream URL
      final audioSource = await buildAudioSource(
        radioSong,
        streamUrl,
        false, // Radio streams are always online
      );

      if (audioSource == null) {
        logger.log('Failed to build audio source for radio stream: $id');
        _lastError = 'Failed to load radio stream';
        return false;
      }

      // Play the radio stream
      await audioPlayer
          .setAudioSource(audioSource)
          .timeout(_songTransitionTimeout);

      listeningStatsService.finishListeningSession(
        countCurrentTick: true,
        wasPlaying: wasPlayingBeforeSwap,
      );

      unawaited(
        audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
          logger.log(
            'Error starting radio playback',
            error: e,
            stackTrace: stackTrace,
          );
          _lastError = e.toString();
        }),
      );

      _updatePlaybackState();
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error playing radio stream',
        error: e,
        stackTrace: stackTrace,
      );
      _lastError = e.toString();
      return false;
    }
  }

  Future<AudioSource?> buildAudioSource(
    Map song,
    String songUrl,
    bool isOffline,
  ) async {
    try {
      final tag = mapToMediaItem(song);
      final isJamendo = isJamendoId(song['ytid']?.toString());

      if (isOffline) {
        final fileSource = AudioSource.file(songUrl, tag: tag);

        if (sponsorBlockSupport.value && !isJamendo) {
          return _applyOfflineSponsorBlock(fileSource, song['ytid']) ??
              fileSource;
        }

        return fileSource;
      }

      final uri = Uri.parse(songUrl);
      final audioSource = AudioSource.uri(uri, tag: tag);

      // SponsorBlock only covers YouTube content — skip for Jamendo.
      if (!sponsorBlockSupport.value || isJamendo) {
        return audioSource;
      }

      final spbAudioSource = await checkIfSponsorBlockIsAvailable(
        audioSource,
        song['ytid'],
      );
      return spbAudioSource ?? audioSource;
    } catch (e, stackTrace) {
      logger.log(
        'Error building audio source',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  AudioSource? _applyOfflineSponsorBlock(
    UriAudioSource audioSource,
    String songId,
  ) {
    final segments = getCachedSponsorBlockSegments(songId);
    if (segments != null) {
      return segments.isEmpty
          ? null
          : _buildSkippedAudioSource(audioSource, segments);
    }
    // Nothing stored yet, e.g. a song downloaded before this existed: look it
    // up now so the next playback of it skips offline too.
    if (!offlineMode.value) unawaited(cacheSponsorBlockSegments(songId));
    return null;
  }

  Future<AudioSource?> checkIfSponsorBlockIsAvailable(
    UriAudioSource audioSource,
    String songId,
  ) async {
    try {
      final segments = await getSkipSegments(songId);
      if (segments.isEmpty) return null;
      return _buildSkippedAudioSource(audioSource, segments);
    } catch (e, stackTrace) {
      logger.log(
        'Error checking sponsor block',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static AudioSource? _buildSkippedAudioSource(
    UriAudioSource source,
    List<Map<String, int>> segments,
  ) {
    segments.sort((a, b) => (a['start'] ?? 0).compareTo(b['start'] ?? 0));
    final children = <AudioSource>[];
    var lastEnd = 0;
    for (final segment in segments) {
      final start = segment['start'] ?? 0;
      final end = segment['end'] ?? 0;
      if (start > lastEnd) {
        children.add(
          ClippingAudioSource(
            child: source,
            start: Duration(seconds: lastEnd),
            end: Duration(seconds: start),
          ),
        );
      }
      if (end > lastEnd) lastEnd = end;
    }
    children.add(
      ClippingAudioSource(
        child: source,
        start: Duration(seconds: lastEnd),
      ),
    );
    if (children.length == 1) return children.first;
    // ignore: deprecated_member_use
    return ConcatenatingAudioSource(children: children);
  }

  Future<void> skipToSong(int newIndex) async {
    try {
      if (newIndex < 0 || newIndex >= _queueList.length) {
        logger.log('Invalid song index: $newIndex');
        return;
      }
      await _playFromQueue(newIndex);
    } catch (e, stackTrace) {
      logger.log('Error skipping to song', error: e, stackTrace: stackTrace);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => skipToSong(index);

  // ─── AutoNext song-title filter ───────────────────────────────────────────

  /// Delegates to [RecommendationEngine.isLikelySong], which is the single
  /// source-of-truth for the song-title heuristic used across the app.
  static bool _isLikelySong(String title, {bool isLive = false}) =>
      RecommendationEngine.isLikelySong(title, isLive: isLive);

  // ─────────────────────────────────────────────────────────────────────────────

  Map? _getLastPlayedYouTubeSong() {
    final current = currentSong;
    if (current != null && !isJamendoId(current['ytid']?.toString())) {
      return current;
    }
    if (_currentQueueIndex >= 0 && _currentQueueIndex < _queueList.length) {
      final queued = _queueList[_currentQueueIndex];
      if (!isJamendoId(queued['ytid']?.toString())) {
        return queued;
      }
    }
    for (final song in _historyList) {
      if (!isJamendoId(song['ytid']?.toString())) {
        return song;
      }
    }
    for (final song in _queueList) {
      if (!isJamendoId(song['ytid']?.toString())) {
        return song;
      }
    }
    return null;
  }

  Future<bool> _tryPlayYouTubeRecommendationOrSearch() async {
    if (offlineMode.value) return false;

    debugPrint('[SoundWave AutoNext] SEARCHING YOUTUBE NEXT');
    debugPrint('[SoundWave AutoNext] TRYING YOUTUBE RECOMMENDATION');

    // A. Pre-fetched YouTube recommendation
    if (nextRecommendedSong != null) {
      final candidate = nextRecommendedSong;
      nextRecommendedSong = null;
      if (candidate is Map && !isJamendoId(candidate['ytid']?.toString())) {
        final candidateTitle = candidate['title']?.toString() ?? '';
        debugPrint('[SoundWave AutoNext] CANDIDATE: $candidateTitle');
        if (!_isLikelySong(candidateTitle)) {
          debugPrint('[SoundWave AutoNext] REJECTED NON-SONG: $candidateTitle');
        } else {
          debugPrint('[SoundWave AutoNext] YOUTUBE RECOMMENDATION FOUND: true');
          debugPrint('[SoundWave AutoNext] TESTING SONG: $candidateTitle');
          final queueSong = _queueEntryIds.createSong(candidate);
          queueSong['isAutoPicked'] = true;
          _queueList.add(queueSong);
          _updateQueueMediaItems();
          final success = await _playFromQueue(
            _queueList.length - 1,
            suppressAutoRetry: true,
          );
          if (success) {
            debugPrint(
              '[SoundWave AutoNext] PLAYABLE SONG FOUND: $candidateTitle',
            );
            return true;
          }
          _queueList.removeLast();
          _updateQueueMediaItems();
          debugPrint(
            '[SoundWave AutoNext] Pre-fetched YouTube recommendation stream failed, trying live fetch...',
          );
        }
      }
    }

    // B. Fetch YouTube related videos on-demand
    final baseSong = _getLastPlayedYouTubeSong();
    var foundRecommendations = false;
    if (baseSong != null) {
      final baseId = baseSong['ytid']?.toString();
      if (baseId != null && baseId.isNotEmpty && !isJamendoId(baseId)) {
        try {
          final client = ProxyManager().getClientSync();
          final songVideo = await client.videos
              .get(baseId)
              .timeout(const Duration(seconds: 8));
          final relatedVideos =
              (await client.videos
                  .getRelatedVideos(songVideo)
                  .timeout(const Duration(seconds: 8))) ??
              [];

          final recentIds = <String>{
            ..._queueList.map((s) => s['ytid']?.toString() ?? ''),
            ..._historyList.map((s) => s['ytid']?.toString() ?? ''),
          };

          final candidates = relatedVideos
              .where((v) => !recentIds.contains(v.id.value))
              .toList();

          if (candidates.isNotEmpty) {
            foundRecommendations = true;
            debugPrint(
              '[SoundWave AutoNext] YOUTUBE RECOMMENDATION FOUND: true',
            );
            var triedCount = 0;
            for (final video in candidates) {
              final vidId = video.id.value;
              final videoTitle = video.title;
              debugPrint(
                '[SoundWave AutoNext] CANDIDATE: $videoTitle ($vidId)',
              );

              if (!_isLikelySong(videoTitle, isLive: video.isLive)) {
                debugPrint(
                  '[SoundWave AutoNext] REJECTED NON-SONG: $videoTitle',
                );
                continue;
              }

              triedCount++;
              if (triedCount > 3) break;

              debugPrint(
                '[SoundWave AutoNext] TESTING SONG $triedCount: $videoTitle ($vidId)',
              );
              final songLayout = returnSongLayout(0, video);
              final queueSong = _queueEntryIds.createSong(songLayout);
              queueSong['isAutoPicked'] = true;
              _queueList.add(queueSong);
              _updateQueueMediaItems();

              final success = await _playFromQueue(
                _queueList.length - 1,
                suppressAutoRetry: true,
              );
              if (success) {
                debugPrint(
                  '[SoundWave AutoNext] PLAYABLE SONG FOUND: $videoTitle',
                );
                return true;
              }
              _queueList.removeLast();
              _updateQueueMediaItems();
              debugPrint(
                '[SoundWave AutoNext] YouTube candidate $vidId stream failed, trying next...',
              );
            }
          }
        } catch (e, st) {
          logger.log(
            'Error fetching YouTube related videos',
            error: e,
            stackTrace: st,
          );
        }
      }
    }

    if (!foundRecommendations) {
      debugPrint('[SoundWave AutoNext] YOUTUBE RECOMMENDATION FOUND: false');
    }

    // C. New YouTube search result
    debugPrint('[SoundWave AutoNext] TRYING YOUTUBE SEARCH');
    final queryTitle = baseSong?['title']?.toString() ?? '';
    final queryArtist = baseSong?['artist']?.toString() ?? '';
    final query = '$queryArtist $queryTitle'.trim();
    if (query.isNotEmpty) {
      try {
        final searchResults = await fetchSongsList(query)
            .timeout(const Duration(seconds: 8));
        final recentIds = <String>{
          ..._queueList.map((s) => s['ytid']?.toString() ?? ''),
          ..._historyList.map((s) => s['ytid']?.toString() ?? ''),
        };

        final candidates = searchResults
            .where(
              (s) =>
                  s is Map &&
                  s['ytid'] != null &&
                  s['ytid'].toString().isNotEmpty &&
                  !isJamendoId(s['ytid'].toString()) &&
                  !recentIds.contains(s['ytid'].toString()),
            )
            .toList();

        if (candidates.isNotEmpty) {
          debugPrint('[SoundWave AutoNext] YOUTUBE SEARCH RESULT: true');
          var triedCount = 0;
          for (final song in candidates) {
            final ytid = song['ytid'].toString();
            final songTitle = song['title']?.toString() ?? '';
            debugPrint('[SoundWave AutoNext] CANDIDATE: $songTitle ($ytid)');

            if (!_isLikelySong(songTitle)) {
              debugPrint('[SoundWave AutoNext] REJECTED NON-SONG: $songTitle');
              continue;
            }

            triedCount++;
            if (triedCount > 2) break;

            debugPrint(
              '[SoundWave AutoNext] TESTING SONG $triedCount: $songTitle ($ytid)',
            );
            final queueSong = _queueEntryIds.createSong(song);
            queueSong['isAutoPicked'] = true;
            _queueList.add(queueSong);
            _updateQueueMediaItems();

            final success = await _playFromQueue(
              _queueList.length - 1,
              suppressAutoRetry: true,
            );
            if (success) {
              debugPrint(
                '[SoundWave AutoNext] PLAYABLE SONG FOUND: $songTitle',
              );
              return true;
            }
            _queueList.removeLast();
            _updateQueueMediaItems();
          }
        } else {
          debugPrint('[SoundWave AutoNext] YOUTUBE SEARCH RESULT: false');
        }
      } catch (e, st) {
        debugPrint('[SoundWave AutoNext] YOUTUBE SEARCH RESULT: false');
        logger.log(
          'Error searching YouTube for recommendations',
          error: e,
          stackTrace: st,
        );
      }
    } else {
      debugPrint('[SoundWave AutoNext] YOUTUBE SEARCH RESULT: false');
    }

    debugPrint('[SoundWave AutoNext] YOUTUBE NEXT FAILED');
    return false;
  }

  Future<bool> _tryPlayJamendoFallback() async {
    if (offlineMode.value) return false;

    debugPrint('[SoundWave AutoNext] TRYING JAMENDO FALLBACK');
    final baseSong =
        _getLastPlayedYouTubeSong() ??
        currentSong ??
        (_historyList.isNotEmpty ? _historyList.first : null);
    final artist = baseSong?['artist']?.toString().trim() ?? '';
    final title = baseSong?['title']?.toString().trim() ?? '';

    var jamendoTracks = <Map<String, dynamic>>[];

    // Contextual search: artist + title
    if (artist.isNotEmpty && title.isNotEmpty) {
      try {
        jamendoTracks = await JamendoService.instance.searchTracks(
          '$artist $title',
          limit: 10,
        );
      } catch (_) {}
    }

    // If empty, search artist
    if (jamendoTracks.isEmpty && artist.isNotEmpty) {
      try {
        jamendoTracks = await JamendoService.instance.searchTracks(
          artist,
          limit: 10,
        );
      } catch (_) {}
    }

    // If still empty, fetch popular tracks on Jamendo as independent music fallback
    if (jamendoTracks.isEmpty) {
      try {
        debugPrint(
          '[SoundWave AutoNext] Querying Jamendo popular tracks for fallback...',
        );
        jamendoTracks = await JamendoService.instance.getPopularTracks(
          limit: 10,
        );
      } catch (_) {}
    }

    if (jamendoTracks.isEmpty) {
      debugPrint('[SoundWave AutoNext] JAMENDO RESULT: false');
      return false;
    }

    final recentIds = <String>{
      ..._queueList.map((s) => s['ytid']?.toString() ?? ''),
      ..._historyList.map((s) => s['ytid']?.toString() ?? ''),
    };

    final candidates = jamendoTracks.where((t) {
      final ytid = 'jamendo_${t['id']}';
      return !recentIds.contains(ytid);
    }).toList();

    if (candidates.isEmpty) {
      debugPrint('[SoundWave AutoNext] JAMENDO RESULT: false');
      return false;
    }

    debugPrint('[SoundWave AutoNext] JAMENDO RESULT: true');

    for (var i = 0; i < candidates.length; i++) {
      if (i >= 2) break; // Try up to 2 candidates
      final rawTrack = candidates[i];
      final songMap = returnJamendoSongLayout(i, rawTrack);
      final ytid = songMap['ytid']?.toString() ?? '';

      debugPrint(
        '[SoundWave AutoNext] Playing Jamendo fallback: ${songMap['title']} ($ytid)',
      );
      final queueSong = _queueEntryIds.createSong(songMap);
      queueSong['isAutoPicked'] = true;
      queueSong['isJamendoFallback'] = true;
      _queueList.add(queueSong);
      _updateQueueMediaItems();

      final success = await _playFromQueue(
        _queueList.length - 1,
        suppressAutoRetry: true,
      );
      if (success) return true;
      _queueList.removeLast();
      _updateQueueMediaItems();
    }

    return false;
  }

  Future<void> _advanceToNextOrFallback() async {
    if (_isAdvancingQueue) {
      debugPrint(
        '[SoundWave AutoNext] _advanceToNextOrFallback already in progress, skipping duplicate invocation',
      );
      return;
    }
    _isAdvancingQueue = true;
    try {
      final curSong = _getLastPlayedYouTubeSong() ?? currentSong;
      final curTitle = curSong?['title']?.toString() ?? 'Unknown';
      debugPrint('[SoundWave AutoNext] CURRENT SONG: $curTitle');
      debugPrint('[SoundWave AutoNext] QUEUE LENGTH: ${_queueList.length}');
      debugPrint('[SoundWave AutoNext] CURRENT INDEX: $_currentQueueIndex');
      debugPrint('[SoundWave AutoNext] AUTO NEXT ENABLED: $_autoNextEnabled');

      // 1. YouTube queue: scan ahead in queue for YouTube songs first
      if (_currentQueueIndex < _queueList.length - 1) {
        for (var i = _currentQueueIndex + 1; i < _queueList.length; i++) {
          final candidate = _queueList[i];
          final ytid = candidate['ytid']?.toString() ?? '';
          if (!isJamendoId(ytid)) {
            debugPrint(
              '[SoundWave AutoNext] Playing next YouTube song in queue at index $i: ${candidate['title']}',
            );
            final success = await _playFromQueue(i, suppressAutoRetry: true);
            if (success) return;
            debugPrint(
              '[SoundWave AutoNext] YouTube stream failed for index $i, trying next YouTube option in queue...',
            );
          }
        }

        // If no YouTube songs ahead in queue, check any other queued songs (e.g. user added)
        for (var i = _currentQueueIndex + 1; i < _queueList.length; i++) {
          final candidate = _queueList[i];
          final ytid = candidate['ytid']?.toString() ?? '';
          if (isJamendoId(ytid)) {
            debugPrint(
              '[SoundWave AutoNext] Playing queued song at index $i: ${candidate['title']}',
            );
            final success = await _playFromQueue(i, suppressAutoRetry: true);
            if (success) return;
          }
        }
      }

      // If Repeat ALL is active, loop to beginning of queue and check YouTube songs
      if (repeatNotifier.value == AudioServiceRepeatMode.all &&
          _queueList.isNotEmpty) {
        for (var i = 0; i <= _currentQueueIndex && i < _queueList.length; i++) {
          final candidate = _queueList[i];
          final ytid = candidate['ytid']?.toString() ?? '';
          if (!isJamendoId(ytid)) {
            debugPrint(
              '[SoundWave AutoNext] Repeat ALL -> Playing YouTube song in queue at index $i: ${candidate['title']}',
            );
            final success = await _playFromQueue(i, suppressAutoRetry: true);
            if (success) return;
          }
        }
      }

      debugPrint('[SoundWave AutoNext] QUEUE EXHAUSTED');

      if (_autoNextEnabled) {
        // 2a. Wait for any in-progress background refill before giving up.
        if (_isRefillInProgress && _currentRefillFuture != null) {
          debugPrint(
            '[SoundWave AutoNext] Waiting for background refill to complete...',
          );
          await _currentRefillFuture!.timeout(
            const Duration(seconds: 20),
            onTimeout: () {},
          );
        }

        // 2b. Re-scan queue — the background refill may have added items.
        for (var i = _currentQueueIndex + 1; i < _queueList.length; i++) {
          final candidate = _queueList[i];
          final ytid = candidate['ytid']?.toString() ?? '';
          if (!isJamendoId(ytid)) {
            debugPrint(
              '[SoundWave AutoNext] Post-refill: playing YouTube song '
              'at index $i: ${candidate['title']}',
            );
            final success = await _playFromQueue(i, suppressAutoRetry: true);
            if (success) return;
          }
        }

        // 2c. If still empty, trigger an immediate synchronous refill.
        if (!_isRefillInProgress) {
          debugPrint(
            '[SoundWave AutoNext] Triggering immediate recommendation refill...',
          );
          await _refillRecommendationQueue();

          // Re-scan after immediate refill.
          for (var i = _currentQueueIndex + 1; i < _queueList.length; i++) {
            final candidate = _queueList[i];
            final ytid = candidate['ytid']?.toString() ?? '';
            if (!isJamendoId(ytid)) {
              debugPrint(
                '[SoundWave AutoNext] Post-immediate-refill: playing YouTube song '
                'at index $i: ${candidate['title']}',
              );
              final success = await _playFromQueue(i, suppressAutoRetry: true);
              if (success) return;
            }
          }
        }

        // 3. Safety-net: fall back to the single-song YouTube find mechanism.
        debugPrint('[SoundWave Fallback] ALL YOUTUBE QUEUE OPTIONS EXHAUSTED');
        final ytSuccess = await _tryPlayYouTubeRecommendationOrSearch();
        if (ytSuccess) return;

        // 4. Jamendo fallback (ONLY after all YouTube options exhausted/failed).
        debugPrint('[SoundWave Fallback] TRYING JAMENDO');
        final jamendoSuccess = await _tryPlayJamendoFallback();
        if (jamendoSuccess) return;
      }

      // 5. If all failed or auto-play disabled: STOP
      debugPrint(
        '[SoundWave AutoNext] All sources exhausted or auto-play off -> STOP',
      );
      await stop();
    } catch (e, stackTrace) {
      logger.log(
        'Error in _advanceToNextOrFallback',
        error: e,
        stackTrace: stackTrace,
      );
      await stop();
    } finally {
      _isAdvancingQueue = false;
    }
  }

  @override
  Future<void> skipToNext() async {
    try {
      await _advanceToNextOrFallback();
      _cleanupOldPreloadedSongs();
    } catch (e, stackTrace) {
      logger.log(
        'Error skipping to next song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      if (_currentQueueIndex > 0) {
        await _playFromQueue(_currentQueueIndex - 1);
      } else if (_historyList.isNotEmpty) {
        final lastSong = cloneMap(_historyList.removeLast());
        _queueList.insert(0, lastSong);
        _currentQueueIndex = 0;
        _updateQueueMediaItems();
        await _playFromQueue(0);
      }

      _cleanupOldPreloadedSongs();
    } catch (e, stackTrace) {
      logger.log(
        'Error skipping to previous song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> playAgain() async {
    try {
      listeningStatsService.finishListeningSession(
        countCurrentTick: true,
        wasPlaying: audioPlayer.playing,
      );
      await audioPlayer.seek(Duration.zero);
      final song = currentSong;
      if (song != null) {
        listeningStatsService.startListeningSession(
          song,
          duration: audioPlayer.duration,
        );
        unawaited(updateRecentlyPlayed(song['ytid'], songFallback: song));
      }
      unawaited(
        audioPlayer.play().catchError((Object e, StackTrace stackTrace) {
          logger.log(
            'Error restarting playback in playAgain',
            error: e,
            stackTrace: stackTrace,
          );
          _lastError = e.toString();
        }),
      );
      _updatePlaybackState();
    } catch (e, stackTrace) {
      logger.log('Error playing again', error: e, stackTrace: stackTrace);
    }
  }

  Map<Map, String> _buildIdMap(List<Map> songs) {
    return {for (final song in songs) song: _queueEntryIds.ensureId(song)};
  }

  void _enableShuffle(
    List<Map> unplayedManualSongs,
    Set<String> manualSongIds,
  ) {
    _originalQueueList
      ..clear()
      ..addAll(cloneMaps(_queueList));

    final currentSong = _queueList[_currentQueueIndex];
    final currentQueueEntryId = _queueEntryIds.ensureId(currentSong);

    final queueIdMap = _buildIdMap(_queueList);
    _queueList
      ..removeWhere((song) => manualSongIds.contains(queueIdMap[song]))
      ..shuffle();

    final newCurrentIndex = _queueList.indexWhere(
      (song) => _queueEntryIds.ensureId(song) == currentQueueEntryId,
    );

    if (newCurrentIndex != -1 && newCurrentIndex != 0) {
      _queueList
        ..removeAt(newCurrentIndex)
        ..insert(0, currentSong);
    }

    _queueList.insertAll(_queueList.isNotEmpty ? 1 : 0, unplayedManualSongs);

    _currentQueueIndex = 0;
    _updateQueueMediaItems();
  }

  void _disableShuffle(
    List<Map> unplayedManualSongs,
    Set<String> manualSongIds,
  ) {
    if (_originalQueueList.isEmpty) return;

    final currentSong = _queueList[_currentQueueIndex];
    final currentQueueEntryId = _queueEntryIds.ensureId(currentSong);

    final restoredQueue = cloneMaps(_originalQueueList);
    final restoredQueueIdMap = _buildIdMap(restoredQueue);
    restoredQueue.removeWhere(
      (song) => manualSongIds.contains(restoredQueueIdMap[song]),
    );

    _queueList
      ..clear()
      ..addAll(restoredQueue);

    _currentQueueIndex = _queueList.indexWhere(
      (song) => _queueEntryIds.ensureId(song) == currentQueueEntryId,
    );

    if (_currentQueueIndex == -1) {
      _currentQueueIndex = 0;
    }

    final insertIndex = _currentQueueIndex + 1;
    _queueList.insertAll(insertIndex, unplayedManualSongs);

    _originalQueueList.clear();
    _updateQueueMediaItems();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      final shuffleEnabled = shuffleMode != AudioServiceShuffleMode.none;
      final wasShuffled = shuffleNotifier.value;

      shuffleNotifier.value = shuffleEnabled;
      unawaited(Hive.box('settings').put('shuffleEnabled', shuffleEnabled));
      await audioPlayer.setShuffleModeEnabled(shuffleEnabled);

      if (_queueList.isEmpty) return;

      if (shuffleEnabled && !wasShuffled) {
        _hydrateQueueEntryIds();
        final unplayedManualSongs = _getUnplayedManualSongs();
        final manualSongIds = unplayedManualSongs
            .map(_queueEntryIds.ensureId)
            .toSet();
        _enableShuffle(unplayedManualSongs, manualSongIds);
      } else if (!shuffleEnabled && wasShuffled) {
        _hydrateQueueEntryIds();
        final unplayedManualSongs = _getUnplayedManualSongs();
        final manualSongIds = unplayedManualSongs
            .map(_queueEntryIds.ensureId)
            .toSet();
        _disableShuffle(unplayedManualSongs, manualSongIds);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error setting shuffle mode',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      repeatNotifier.value = repeatMode;
      unawaited(Hive.box('settings').put('repeatMode', repeatMode.index));

      // Always set loop mode to off - we handle all repeating through _handleSongCompletion
      // This ensures ProcessingState.completed is always fired for proper song transitions
      await audioPlayer.setLoopMode(LoopMode.off);
    } catch (e, stackTrace) {
      logger.log('Error setting repeat mode', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> setSleepTimer(Duration duration) async {
    try {
      _sleepTimer?.cancel();
      sleepTimerExpired = false;
      sleepTimerNotifier.value = duration;

      _sleepTimer = Timer(duration, () async {
        sleepTimerExpired = true;
        await stop();
        sleepTimerNotifier.value = null;
      });
    } catch (e, stackTrace) {
      logger.log('Error setting sleep timer', error: e, stackTrace: stackTrace);
    }
  }

  void cancelSleepTimer() {
    try {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      sleepTimerExpired = false;
      sleepTimerEndOfSong = false;
      sleepTimerNotifier.value = Duration.zero;
    } catch (e, stackTrace) {
      logger.log(
        'Error canceling sleep timer',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> setSleepTimerEndOfSong() async {
    try {
      _sleepTimer?.cancel();
      sleepTimerExpired = false;
      sleepTimerEndOfSong = true;
      sleepTimerNotifier.value = const Duration(milliseconds: -1);
    } catch (e, stackTrace) {
      logger.log(
        'Error setting sleep timer end of song',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    try {
      switch (name) {
        case 'clearQueue':
          clearQueue();
          break;
        case 'addToQueue':
          if (extras?['song'] != null) {
            await addToQueue(
              extras!['song'] as Map,
              playNext: extras['playNext'] ?? false,
            );
          }
          break;
        case 'removeFromQueue':
          if (extras?['index'] != null) {
            await removeFromQueue(extras!['index'] as int);
          }
          break;
        case 'reorderQueue':
          if (extras?['oldIndex'] != null && extras?['newIndex'] != null) {
            await reorderQueue(
              extras!['oldIndex'] as int,
              extras['newIndex'] as int,
            );
          }
          break;
        default:
          await super.customAction(name, extras);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error in customAction: $name',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}

class _PlaybackSource {
  const _PlaybackSource({required this.songUrl, required this.isOffline});

  final String songUrl;
  final bool isOffline;
}
