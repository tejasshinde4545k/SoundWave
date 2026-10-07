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

/// Song event logger for the SoundWave recommendation ML pipeline.
///
/// Records user-song interactions (play, skip, like, dislike,
/// save_to_playlist) that match the `user_song_events` schema defined in
/// PROMPT_RECOMMENDATION_SYSTEM.md §2.1. Events are stored locally in Hive
/// and can be exported for the daily Python feature-computation script.
///
/// **Privacy guarantees**
/// * Events are only captured when the user has enabled personalised
///   recommendations (`recEventLoggingEnabled` == true in settings).
/// * The user's identity is anonymised: a random 32-byte salt is generated
///   once per installation and stored in the 'user' Hive box. No raw IPs or
///   device fingerprints are stored.
/// * Raw events are purged after 90 days (`_retentionDays`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:soundwave/main.dart' show logger;

// ── public singleton ──────────────────────────────────────────────────────────

final songEventLogger = SongEventLogger._();

// ── event types ───────────────────────────────────────────────────────────────

/// Possible values for the `event_type` field of [SongEvent].
enum SongEventType {
  play,
  skip,
  like,
  dislike,
  saveToPlaylist;

  String get value {
    switch (this) {
      case SongEventType.play:
        return 'play';
      case SongEventType.skip:
        return 'skip';
      case SongEventType.like:
        return 'like';
      case SongEventType.dislike:
        return 'dislike';
      case SongEventType.saveToPlaylist:
        return 'save_to_playlist';
    }
  }
}

// ── event model ───────────────────────────────────────────────────────────────

/// Immutable representation of one user-song interaction.
///
/// Field names mirror the SQLite schema in PROMPT_RECOMMENDATION_SYSTEM.md §2.1
/// so the exported JSON maps directly to the table columns.
class SongEvent {
  const SongEvent({
    required this.userId,
    required this.ytid,
    required this.eventType,
    required this.sessionId,
    required this.timestampUtc,
    this.listenedSeconds,
    this.durationSeconds,
    this.device = 'mobile',
    required this.hourOfDay,
    required this.dayOfWeek,
  });

  final String userId;
  final String ytid;
  final SongEventType eventType;
  final String sessionId;

  /// Unix epoch seconds (UTC).
  final int timestampUtc;

  /// Seconds the user actually listened (null for non-play/skip events).
  final double? listenedSeconds;

  /// Full track duration in seconds (null when unknown).
  final double? durationSeconds;

  /// Device type — always 'mobile' for now; can be extended later.
  final String device;

  /// 0 = midnight, 23 = 11 PM.
  final int hourOfDay;

  /// 1 = Monday ... 7 = Sunday (ISO 8601).
  final int dayOfWeek;

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'ytid': ytid,
    'event_type': eventType.value,
    'session_id': sessionId,
    'timestamp_utc': timestampUtc,
    if (listenedSeconds != null) 'listened_seconds': listenedSeconds,
    if (durationSeconds != null) 'duration_seconds': durationSeconds,
    'device': device,
    'hour_of_day': hourOfDay,
    'day_of_week': dayOfWeek,
  };
}

// ── logger ────────────────────────────────────────────────────────────────────

class SongEventLogger {
  SongEventLogger._();

  // ── Hive box & key names ───────────────────────────────────────────────────

  static const _eventsBoxName = 'rec_events';
  static const _eventsKey = 'events';
  static const _saltKey = 'rec_user_salt';
  static const _saltEpochKey = 'rec_user_salt_epoch';

  // ── retention ─────────────────────────────────────────────────────────────

  /// Raw events older than this many days are automatically purged.
  /// Matches the 90-day retention policy in PROMPT_RECOMMENDATION_SYSTEM.md §2.3.
  static const _retentionDays = 90;

  // ── in-memory state ───────────────────────────────────────────────────────

  /// Session ID regenerated on every app launch. All events within the same
  /// app session share this identifier, which lets the feature pipeline
  /// reconstruct intra-session sequences.
  late final String _sessionId = _generateSessionId();

  String? _cachedUserId;

  // ── public API ────────────────────────────────────────────────────────────

  /// Must be called once during app startup (after Hive is ready).
  ///
  /// Purges events older than [_retentionDays] to honour the 90-day retention
  /// policy defined in PROMPT_RECOMMENDATION_SYSTEM.md §2.3.
  Future<void> init() async {
    try {
      await _openEventsBox();
      await _purgeOldEvents();
    } catch (e, st) {
      logger.log('SongEventLogger: init error', error: e, stackTrace: st);
    }
  }

  /// Records a [SongEventType.play] event.
  ///
  /// [listenedSeconds] is how long the user actually heard the song.
  /// [durationSeconds] is the full track length (may be null if unavailable).
  Future<void> logPlay({
    required Map song,
    required double listenedSeconds,
    double? durationSeconds,
  }) async {
    await _log(
      song: song,
      eventType: SongEventType.play,
      listenedSeconds: listenedSeconds,
      durationSeconds: durationSeconds,
    );
  }

  /// Records a [SongEventType.skip] event.
  ///
  /// [listenedSeconds] is how many seconds were heard before the skip.
  Future<void> logSkip({
    required Map song,
    required double listenedSeconds,
    double? durationSeconds,
  }) async {
    await _log(
      song: song,
      eventType: SongEventType.skip,
      listenedSeconds: listenedSeconds,
      durationSeconds: durationSeconds,
    );
  }

  /// Records a [SongEventType.like] event.
  Future<void> logLike({required Map song}) async {
    await _log(song: song, eventType: SongEventType.like);
  }

  /// Records a [SongEventType.dislike] event.
  Future<void> logDislike({required Map song}) async {
    await _log(song: song, eventType: SongEventType.dislike);
  }

  /// Records a [SongEventType.saveToPlaylist] event.
  Future<void> logSaveToPlaylist({required Map song}) async {
    await _log(song: song, eventType: SongEventType.saveToPlaylist);
  }

  /// Returns all stored events as a list of JSON maps, ready for the Python
  /// feature pipeline to convert to Parquet.
  ///
  /// Events are returned chronologically (oldest first).
  Future<List<Map<String, dynamic>>> exportPendingEvents() async {
    try {
      final box = await _openEventsBox();
      final raw = box.get(_eventsKey);
      if (raw == null) return [];
      final list = raw is List ? raw : <dynamic>[];
      return list
          .whereType<String>()
          .map<Map<String, dynamic>>((s) {
            try {
              final decoded = json.decode(s);
              if (decoded is Map) {
                return Map<String, dynamic>.from(decoded);
              }
              return <String, dynamic>{};
            } catch (_) {
              return <String, dynamic>{};
            }
          })
          .where((m) => m.isNotEmpty)
          .toList();
    } catch (e, st) {
      logger.log('SongEventLogger: export error', error: e, stackTrace: st);
      return [];
    }
  }

  /// Clears all stored events. Called when the user invokes
  /// "Clear my listening history" (implements GDPR right-to-delete).
  ///
  /// Also regenerates the anonymisation salt so future events cannot be
  /// correlated with past data.
  Future<void> clearAll() async {
    try {
      final box = await _openEventsBox();
      await box.delete(_eventsKey);
      _cachedUserId = null;
      // Regenerate salt so future events can't be correlated with past data.
      final userBox = await _openUserBox();
      await userBox.delete(_saltKey);
      await userBox.delete(_saltEpochKey);
    } catch (e, st) {
      logger.log('SongEventLogger: clearAll error', error: e, stackTrace: st);
    }
  }

  /// Total number of events currently stored on device.
  Future<int> get storedEventCount async {
    try {
      final box = await _openEventsBox();
      final raw = box.get(_eventsKey);
      if (raw is List) return raw.length;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // ── private helpers ───────────────────────────────────────────────────────

  Future<void> _log({
    required Map song,
    required SongEventType eventType,
    double? listenedSeconds,
    double? durationSeconds,
  }) async {
    // Consent gate — respect the user's opt-in preference.
    if (!_isLoggingEnabled()) return;

    final ytid = song['ytid']?.toString() ?? '';
    if (ytid.isEmpty) return;
    // Never log Jamendo or JioSaavn tracks; the recommendation model is
    // YouTube-only (matching RecommendationEngine behaviour).
    if (ytid.startsWith('jamendo:') || ytid.startsWith('jiosaavn:')) return;

    try {
      final now = DateTime.now().toUtc();
      final event = SongEvent(
        userId: await _anonymisedUserId(),
        ytid: ytid,
        eventType: eventType,
        sessionId: _sessionId,
        timestampUtc: now.millisecondsSinceEpoch ~/ 1000,
        listenedSeconds: listenedSeconds,
        durationSeconds: durationSeconds ?? _durationSecondsFromSong(song),
        hourOfDay: now.hour,
        dayOfWeek: now.weekday, // 1=Monday ... 7=Sunday (ISO 8601)
      );

      await _appendEvent(event);
    } catch (e, st) {
      logger.log(
        'SongEventLogger: failed to log ${eventType.value} for $ytid',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _appendEvent(SongEvent event) async {
    final box = await _openEventsBox();

    final raw = box.get(_eventsKey);
    final list = raw is List ? List<dynamic>.from(raw) : <dynamic>[];
    // ignore: cascade_invocations
    list.add(json.encode(event.toJson()));

    await box.put(_eventsKey, list);

    // Opportunistically purge every 500 new events to cap storage growth.
    if (list.length % 500 == 0) {
      unawaited(_purgeOldEvents());
    }
  }

  Future<void> _purgeOldEvents() async {
    try {
      final box = await _openEventsBox();
      final raw = box.get(_eventsKey);
      if (raw is! List) return;

      final cutoffEpoch =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 -
          _retentionDays * 86400;

      final pruned = raw.whereType<String>().where((s) {
        try {
          final decoded = json.decode(s);
          if (decoded is! Map) return false;
          final ts = decoded['timestamp_utc'];
          if (ts is! int) return true; // keep entries without a timestamp
          return ts >= cutoffEpoch;
        } catch (_) {
          return false;
        }
      }).toList();

      if (pruned.length < raw.length) {
        await box.put(_eventsKey, pruned);
        logger.log(
          'SongEventLogger: purged ${raw.length - pruned.length} '
          'events older than $_retentionDays days',
        );
      }
    } catch (e, st) {
      logger.log('SongEventLogger: purge error', error: e, stackTrace: st);
    }
  }

  // ── anonymisation ─────────────────────────────────────────────────────────

  /// Returns a stable, anonymised user ID for this installation.
  ///
  /// The ID is derived as SHA-256(salt + install_epoch) so it cannot be
  /// reversed to the user's real identity. The salt is 32 random bytes stored
  /// in the 'user' Hive box; "Clear history" deletes it and regenerates a new
  /// one, breaking linkability with past events.
  Future<String> _anonymisedUserId() async {
    if (_cachedUserId != null) return _cachedUserId!;

    final userBox = await _openUserBox();

    var salt = userBox.get(_saltKey) as String? ?? '';
    var epoch = userBox.get(_saltEpochKey) as int? ?? 0;

    if (salt.isEmpty) {
      salt = _generateSalt();
      epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await userBox.put(_saltKey, salt);
      await userBox.put(_saltEpochKey, epoch);
    }

    final payload = utf8.encode('$salt:$epoch');
    final digest = sha256.convert(payload);
    // Use first 32 hex chars (16 bytes) — sufficient entropy, compact enough.
    _cachedUserId = digest.toString().substring(0, 32);
    return _cachedUserId!;
  }

  String _generateSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  // ── session ID ────────────────────────────────────────────────────────────

  String _generateSessionId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// Reads the user's opt-in setting from the Hive settings box.
  ///
  /// Defaults to false so no data is collected until the user explicitly
  /// enables personalised recommendations.
  bool _isLoggingEnabled() {
    try {
      if (!Hive.isBoxOpen('settings')) return false;
      return Hive.box('settings').get(
            'recEventLoggingEnabled',
            defaultValue: false,
          ) as bool;
    } catch (_) {
      return false;
    }
  }

  double? _durationSecondsFromSong(Map song) {
    final d = song['duration'];
    if (d == null) return null;
    if (d is Duration) return d.inMilliseconds / 1000.0;
    if (d is int) return d.toDouble();
    if (d is double) return d;
    if (d is num) return d.toDouble();
    final text = d.toString();
    final asDouble = double.tryParse(text);
    if (asDouble != null) return asDouble;
    // "mm:ss" or "hh:mm:ss"
    final parts = text.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    if (parts.length == 2) return (parts[0]! * 60 + parts[1]!).toDouble();
    if (parts.length == 3) {
      return (parts[0]! * 3600 + parts[1]! * 60 + parts[2]!).toDouble();
    }
    return null;
  }

  // ── Hive box helpers ──────────────────────────────────────────────────────

  Future<Box> _openEventsBox() async {
    if (Hive.isBoxOpen(_eventsBoxName)) return Hive.box(_eventsBoxName);
    return Hive.openBox(_eventsBoxName);
  }

  Future<Box> _openUserBox() async {
    if (Hive.isBoxOpen('user')) return Hive.box('user');
    return Hive.openBox('user');
  }
}
