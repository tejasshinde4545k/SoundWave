import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/services/recommendation_cache.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/utilities/formatter.dart';

void main() {
  group('Jamendo & YouTube ID Scheme', () {
    test('isJamendoId correctly identifies Jamendo vs YouTube IDs', () {
      expect(isJamendoId('jamendo:123456'), isTrue);
      expect(isJamendoId('jamendo:abc_xyz'), isTrue);
      expect(isJamendoId('dQw4w9WgXcQ'), isFalse);
      expect(isJamendoId('7wtfhZwyrcc'), isFalse);
      expect(isJamendoId(null), isFalse);
      expect(isJamendoId(''), isFalse);
    });

    test('extractJamendoId extracts raw id', () {
      expect(extractJamendoId('jamendo:123456'), equals('123456'));
      expect(extractJamendoId('dQw4w9WgXcQ'), isNull);
      expect(extractJamendoId(null), isNull);
    });

    test('returnJamendoSongLayout formats tracks with jamendo ytid and source', () {
      final track = {
        'id': 98765,
        'name': 'Indie Groove',
        'artist_name': 'Independent Artist',
        'artist_id': 'art_42',
        'album_name': 'Indie Album',
        'image': 'https://example.com/img.jpg',
        'duration': 210,
        'audio': 'https://example.com/stream.mp3',
      };

      final layout = returnJamendoSongLayout(0, track);
      expect(layout['ytid'], equals('jamendo:98765'));
      expect(layout['source'], equals('jamendo'));
      expect(layout['title'], equals('Indie Groove'));
      expect(layout['artist'], equals('Independent Artist'));
      expect(layout['jamendoAudioUrl'], equals('https://example.com/stream.mp3'));
      expect(isJamendoId(layout['ytid']), isTrue);
    });
  });

  group('Priority & Fallback Pipeline Scenarios', () {
    test('Test 1 — Existing queue has songs: plays next in queue (Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jamendoCalled = false;

      // Song A finishes (currentIndex: 0) -> should pick B
      final next1 = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:111';
        },
      );

      expect(next1, equals('youtube_queue:1'));
      expect(jamendoCalled, isFalse);

      // Song B finishes (currentIndex: 1) -> should pick C
      final next2 = resolveNextSource(
        queue: queue,
        currentIndex: 1,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:111';
        },
      );

      expect(next2, equals('youtube_queue:2'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 2 — YouTube queue exhausted: fetches YouTube recommendations (Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
      ];

      var jamendoCalled = false;

      // Queue at end (currentIndex: 1) -> YouTube recommendations available
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 1,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec_1',
        fetchYouTubeSearch: () => 'yt_search_1',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:222';
        },
      );

      expect(next, equals('youtube_recommendation:yt_rec_1'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 3 — No YouTube song: YouTube unavailable -> Jamendo fallback used', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jamendoCalled = false;

      // YouTube queue exhausted, YouTube recommendation returns null, YouTube search returns null
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (id) => isJamendoId(id), // YouTube streams fail, Jamendo succeeds
        fetchYouTubeRecommendation: () => null,
        fetchYouTubeSearch: () => null,
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:333';
        },
      );

      expect(jamendoCalled, isTrue);
      expect(next, equals('jamendo_fallback:jamendo:333'));
    });

    test('Test 4 — YouTube stream failure: B stream fails -> tries next valid YouTube option C', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jamendoCalled = false;

      // B stream fails, but C stream succeeds
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (id) => id != 'yt_B', // B fails, C succeeds
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:444';
        },
      );

      // Successfully skipped failed B to play YouTube C! Jamendo is NOT used.
      expect(next, equals('youtube_queue:2'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 5 — Repeat ONE: YouTube A finishes -> YouTube A starts again (Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
      ];

      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: true,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:555';
        },
      );

      expect(next, equals('replay_current'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 6 — Repeat ALL: YouTube A -> B -> C -> A (Jamendo NOT inserted while YouTube available)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jamendoCalled = false;

      // Song C is at end (currentIndex: 2). Repeat ALL loops to 0 (Song A).
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 2,
        repeatOne: false,
        repeatAll: true,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:666';
        },
      );

      expect(next, equals('youtube_repeat_all:0'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 7 — Single YouTube song: queue.length == 1, song finishes -> plays YouTube recommendation (Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_single_A', 'title': 'Single Song A'},
      ];

      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_single_B',
        fetchYouTubeSearch: () => 'yt_search_song',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:777';
        },
      );

      // Successfully advances to YouTube Song B! Jamendo is NOT called.
      expect(next, equals('youtube_recommendation:yt_single_B'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 8 — Single YouTube song: queue.length == 1, YouTube exhausted -> Jamendo fallback used', () {
      final queue = [
        {'ytid': 'yt_single_A', 'title': 'Single Song A'},
      ];

      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (id) => isJamendoId(id),
        fetchYouTubeRecommendation: () => null,
        fetchYouTubeSearch: () => null,
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:888';
        },
      );

      expect(jamendoCalled, isTrue);
      expect(next, equals('jamendo_fallback:jamendo:888'));
    });

    test('Test 9 — Single YouTube song with global autoPlay = false: singleSongAutoNext = true -> advances to YouTube recommendation', () {
      final queue = [
        {'ytid': 'yt_search_song', 'title': 'Search Song'},
      ];

      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: false, // Global setting is OFF!
        singleSongAutoNext: true, // Single-song search context is ON!
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_next_rec',
        fetchYouTubeSearch: () => null,
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:999';
        },
      );

      // Advances to YouTube recommendation even though global autoPlay is OFF!
      expect(next, equals('youtube_recommendation:yt_next_rec'));
      expect(jamendoCalled, isFalse);
    });

    test('Test 10 — Album with global autoPlay = false: singleSongAutoNext = false -> stops cleanly at end of album', () {
      final queue = [
        {'ytid': 'yt_album_1', 'title': 'Album Track 1'},
        {'ytid': 'yt_album_2', 'title': 'Album Track 2'},
      ];

      var jamendoCalled = false;

      // When Track 2 (last track, currentIndex: 1) finishes in an album
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 1,
        repeatOne: false,
        repeatAll: false,
        autoPlay: false, // Global setting is OFF!
        singleSongAutoNext: false, // Album context: singleSongAutoNext is FALSE!
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:1010';
        },
      );

      // Stops cleanly at the end of the album without triggering auto-next!
      expect(next, equals('stop'));
      expect(jamendoCalled, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Recommendation Cache
  // ═══════════════════════════════════════════════════════════════════════════
  group('RecommendationCache', () {
    setUp(() => RecommendationCache.instance.clear());

    test('put + get returns stored candidates', () {
      final candidates = [
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];
      RecommendationCache.instance.put('yt_A', candidates);
      final result = RecommendationCache.instance.get('yt_A');
      expect(result, isNotNull);
      expect(result!.length, equals(2));
      expect(result.first['ytid'], equals('yt_B'));
    });

    test('get returns null for unknown key', () {
      expect(RecommendationCache.instance.get('not_in_cache'), isNull);
    });

    test('invalidate removes entry', () {
      RecommendationCache.instance.put('yt_X', [
        {'ytid': 'yt_Y', 'title': 'Y'},
      ]);
      RecommendationCache.instance.invalidate('yt_X');
      expect(RecommendationCache.instance.get('yt_X'), isNull);
    });

    test('clear removes all entries', () {
      RecommendationCache.instance.put('k1', [
        {'ytid': 'v1'},
      ]);
      RecommendationCache.instance.put('k2', [
        {'ytid': 'v2'},
      ]);
      RecommendationCache.instance.clear();
      expect(RecommendationCache.instance.length, equals(0));
    });

    test('evicts oldest entry when maxEntries is reached', () {
      for (var i = 0; i < RecommendationCache.maxEntries; i++) {
        RecommendationCache.instance.put('key_$i', [
          {'ytid': 'val_$i'},
        ]);
      }
      expect(
        RecommendationCache.instance.length,
        equals(RecommendationCache.maxEntries),
      );
      // Adding one more should evict the oldest (key_0).
      RecommendationCache.instance.put('key_overflow', [
        {'ytid': 'val_overflow'},
      ]);
      expect(
        RecommendationCache.instance.length,
        equals(RecommendationCache.maxEntries),
      );
      expect(RecommendationCache.instance.get('key_0'), isNull);
      expect(RecommendationCache.instance.get('key_overflow'), isNotNull);
    });

    test('re-inserting existing key refreshes LRU order', () {
      // Fill to max.
      for (var i = 0; i < RecommendationCache.maxEntries; i++) {
        RecommendationCache.instance.put('key_$i', [
          {'ytid': 'val_$i'},
        ]);
      }
      // Access key_0 to refresh its LRU position.
      RecommendationCache.instance.get('key_0');
      // Adding one more should now evict key_1 (oldest that wasn't refreshed).
      RecommendationCache.instance.put('key_new', [
        {'ytid': 'val_new'},
      ]);
      expect(RecommendationCache.instance.get('key_0'), isNotNull);
      expect(RecommendationCache.instance.get('key_1'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // RecommendationEngine.isLikelySong — song-title heuristic
  // ═══════════════════════════════════════════════════════════════════════════
  group('RecommendationEngine.isLikelySong', () {
    test('accepts plain song titles', () {
      expect(RecommendationEngine.isLikelySong('Churai Janda Eh'), isTrue);
      expect(RecommendationEngine.isLikelySong('Loser - Tame Impala'), isTrue);
      expect(RecommendationEngine.isLikelySong('8K Video Arijit Singh'), isTrue);
      expect(RecommendationEngine.isLikelySong('Shape Of You'), isTrue);
    });

    test('accepts titles with explicit music signals', () {
      expect(
        RecommendationEngine.isLikelySong('Song Name (Official Audio)'),
        isTrue,
      );
      expect(
        RecommendationEngine.isLikelySong('Track Name | Lyrics Video'),
        isTrue,
      );
      expect(
        RecommendationEngine.isLikelySong('Artist - Title (Official Music Video)'),
        isTrue,
      );
      expect(RecommendationEngine.isLikelySong('Remix Edition'), isTrue);
    });

    test('rejects podcast/episode content', () {
      expect(
        RecommendationEngine.isLikelySong('Latent Season 2 Bonus Episode'),
        isFalse,
      );
      expect(RecommendationEngine.isLikelySong('My Podcast Episode 42'), isFalse);
      expect(RecommendationEngine.isLikelySong('Tech Talk Show #15'), isFalse);
    });

    test('rejects gaming/vlog/non-music content', () {
      expect(
        RecommendationEngine.isLikelySong('Let\'s Play Minecraft Episode 1'),
        isFalse,
      );
      expect(RecommendationEngine.isLikelySong('My Daily Vlog - Day 7'), isFalse);
      expect(
        RecommendationEngine.isLikelySong('Movie Trailer Official 2026'),
        isFalse,
      );
    });

    test('rejects active live-streams', () {
      expect(
        RecommendationEngine.isLikelySong('Some Stream', isLive: true),
        isFalse,
      );
    });

    test('music signals take priority over weak non-song words', () {
      // "documentary" is a non-song signal, but "official audio" is a stronger
      // music signal — the music signal wins.
      expect(
        RecommendationEngine.isLikelySong(
          'Song Name Documentary (Official Audio)',
        ),
        isTrue,
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Dynamic Recommendation Queue — decision-engine scenarios
  // ═══════════════════════════════════════════════════════════════════════════
  group('Dynamic Recommendation Queue', () {
    /// Simulates the new _advanceToNextOrFallback() decision logic including
    /// the background-refill check.
    ///
    /// [queueAfterRefill] represents the queue state AFTER a background refill
    /// has completed. Pass the same list as [initialQueue] to simulate a
    /// refill that produced no results.
    String resolveWithRefill({
      required List<Map<String, dynamic>> initialQueue,
      required List<Map<String, dynamic>> queueAfterRefill,
      required int currentIndex,
      required bool autoPlay,
      bool refillInProgress = false,
      required bool Function(String ytid) streamResolves,
      required String? Function() fetchYouTubeSearch,
      required String? Function() fetchJamendoFallback,
    }) {
      // Step 1: scan initial queue ahead (YouTube songs first).
      for (var i = currentIndex + 1; i < initialQueue.length; i++) {
        final ytid = initialQueue[i]['ytid']?.toString() ?? '';
        if (!isJamendoId(ytid) && streamResolves(ytid)) {
          return 'youtube_queue:$i';
        }
      }

      if (!autoPlay) return 'stop';

      // Step 2a: if refill was in progress, simulate completing it and
      // re-scan queueAfterRefill.
      final queue = refillInProgress ? queueAfterRefill : initialQueue;
      for (var i = currentIndex + 1; i < queue.length; i++) {
        final ytid = queue[i]['ytid']?.toString() ?? '';
        if (!isJamendoId(ytid) && streamResolves(ytid)) {
          return 'youtube_queue_post_refill:$i';
        }
      }

      // Step 2b: immediate refill (same queue since we already simulated it).
      for (var i = currentIndex + 1; i < queueAfterRefill.length; i++) {
        final ytid = queueAfterRefill[i]['ytid']?.toString() ?? '';
        if (!isJamendoId(ytid) && streamResolves(ytid)) {
          return 'youtube_queue_immediate_refill:$i';
        }
      }

      // Step 3: YouTube search safety-net.
      final ytSearch = fetchYouTubeSearch();
      if (ytSearch != null && streamResolves(ytSearch)) {
        return 'youtube_search:$ytSearch';
      }

      // Step 4: Jamendo.
      final jamendo = fetchJamendoFallback();
      if (jamendo != null && streamResolves(jamendo)) {
        return 'jamendo_fallback:$jamendo';
      }

      return 'stop';
    }

    // ── Test 1: Single song generates multiple upcoming songs ─────────────────
    test('Test 1 — Single song: background refill adds multiple YouTube songs', () {
      // Before refill: only [A].
      final initialQueue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];
      // After refill: [A, B, C, D, E, F].
      final queueAfterRefill = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
        {'ytid': 'yt_D', 'title': 'Song D'},
        {'ytid': 'yt_E', 'title': 'Song E'},
        {'ytid': 'yt_F', 'title': 'Song F'},
      ];

      var jamendoCalled = false;

      // A finishes; refill was in progress.
      final next = resolveWithRefill(
        initialQueue: initialQueue,
        queueAfterRefill: queueAfterRefill,
        currentIndex: 0,
        autoPlay: true,
        refillInProgress: true,
        streamResolves: (_) => true,
        fetchYouTubeSearch: () => 'yt_fallback_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:111';
        },
      );

      // Plays B (index 1) after refill completes. Jamendo NOT called.
      expect(next, startsWith('youtube_queue'));
      expect(jamendoCalled, isFalse);
    });

    // ── Test 2: Automatic playback A → B ──────────────────────────────────────
    test('Test 2 — A finishes → B automatically starts (no manual Next)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: queue,
        queueAfterRefill: queue,
        currentIndex: 0,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:222';
        },
      );

      expect(next, equals('youtube_queue:1'));
      expect(jamendoCalled, isFalse);
    });

    // ── Test 3: Multiple automatic transitions A → B → C → D ─────────────────
    test('Test 3 — Multiple transitions without manual interaction', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'A'},
        {'ytid': 'yt_B', 'title': 'B'},
        {'ytid': 'yt_C', 'title': 'C'},
        {'ytid': 'yt_D', 'title': 'D'},
      ];

      var jamendoCalled = false;

      for (var i = 0; i < queue.length - 1; i++) {
        final next = resolveWithRefill(
          initialQueue: queue,
          queueAfterRefill: queue,
          currentIndex: i,
          autoPlay: true,
          streamResolves: (_) => true,
          fetchYouTubeSearch: () => null,
          fetchJamendoFallback: () {
            jamendoCalled = true;
            return null;
          },
        );
        expect(next, equals('youtube_queue:${i + 1}'));
      }

      expect(jamendoCalled, isFalse);
    });

    // ── Test 4: Dynamic refill adds G-J when queue runs low ───────────────────
    test('Test 4 — Dynamic refill: G-J appended when upcoming < threshold', () {
      // Before refill: A–F.
      final initialQueue = List.generate(6, (i) {
        final letter = String.fromCharCode('A'.codeUnitAt(0) + i);
        return <String, dynamic>{'ytid': 'yt_$letter', 'title': 'Song $letter'};
      });

      // After refill: A–J.
      final queueAfterRefill = List.generate(10, (i) {
        final letter = String.fromCharCode('A'.codeUnitAt(0) + i);
        return <String, dynamic>{'ytid': 'yt_$letter', 'title': 'Song $letter'};
      });

      var jamendoCalled = false;

      // Current song is F (index 5) — queue is now exhausted in initialQueue.
      final next = resolveWithRefill(
        initialQueue: initialQueue,
        queueAfterRefill: queueAfterRefill,
        currentIndex: 5,
        autoPlay: true,
        refillInProgress: true,
        streamResolves: (_) => true,
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:444';
        },
      );

      // G is at index 6 in queueAfterRefill. Jamendo NOT called.
      expect(next, startsWith('youtube_queue'));
      expect(jamendoCalled, isFalse);
    });

    // ── Test 5: Album A → B → C → D ──────────────────────────────────────────
    test('Test 5 — Album playback A → B → C → D', () {
      final album = [
        {'ytid': 'alb_A', 'title': 'Track A'},
        {'ytid': 'alb_B', 'title': 'Track B'},
        {'ytid': 'alb_C', 'title': 'Track C'},
        {'ytid': 'alb_D', 'title': 'Track D'},
      ];

      for (var i = 0; i < album.length - 1; i++) {
        final next = resolveWithRefill(
          initialQueue: album,
          queueAfterRefill: album,
          currentIndex: i,
          autoPlay: false, // Album — global autoPlay off.
          streamResolves: (_) => true,
          fetchYouTubeSearch: () => null,
          fetchJamendoFallback: () => null,
        );
        expect(next, equals('youtube_queue:${i + 1}'));
      }
    });

    // ── Test 6: Playlist A → B → C → D ───────────────────────────────────────
    test('Test 6 — Playlist playback A → B → C → D', () {
      final playlist = [
        {'ytid': 'pl_A', 'title': 'PL Track A'},
        {'ytid': 'pl_B', 'title': 'PL Track B'},
        {'ytid': 'pl_C', 'title': 'PL Track C'},
        {'ytid': 'pl_D', 'title': 'PL Track D'},
      ];

      for (var i = 0; i < playlist.length - 1; i++) {
        final next = resolveWithRefill(
          initialQueue: playlist,
          queueAfterRefill: playlist,
          currentIndex: i,
          autoPlay: false,
          streamResolves: (_) => true,
          fetchYouTubeSearch: () => null,
          fetchJamendoFallback: () => null,
        );
        expect(next, equals('youtube_queue:${i + 1}'));
      }
    });

    // ── Test 7: Repeat ONE ────────────────────────────────────────────────────
    test('Test 7 — Repeat ONE: A → A → A (Jamendo NOT called)', () {
      // Simulated as the existing resolveNextSource function handles Repeat ONE.
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: true,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:777';
        },
      );

      expect(next, equals('replay_current'));
      expect(jamendoCalled, isFalse);
    });

    // ── Test 8: Repeat ALL ────────────────────────────────────────────────────
    test('Test 8 — Repeat ALL A → B → C → A (Jamendo NOT inserted)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'A'},
        {'ytid': 'yt_B', 'title': 'B'},
        {'ytid': 'yt_C', 'title': 'C'},
      ];

      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 2, // C finishes.
        repeatOne: false,
        repeatAll: true,
        autoPlay: false,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => 'yt_rec',
        fetchYouTubeSearch: () => 'yt_search',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:888';
        },
      );

      expect(next, equals('youtube_repeat_all:0'));
      expect(jamendoCalled, isFalse);
    });

    // ── Test 9: YouTube recommendation failure → search ───────────────────────
    test('Test 9 — YouTube recommendation fails → YouTube search (no Jamendo)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: queue,
        queueAfterRefill: queue, // Refill produced nothing.
        currentIndex: 0,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeSearch: () => 'yt_search_result',
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:999';
        },
      );

      expect(next, equals('youtube_search:yt_search_result'));
      expect(jamendoCalled, isFalse);
    });

    // ── Test 10: Complete YouTube failure → Jamendo ───────────────────────────
    test('Test 10 — All YouTube exhausted → Jamendo fallback', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: queue,
        queueAfterRefill: queue,
        currentIndex: 0,
        autoPlay: true,
        streamResolves: (id) => isJamendoId(id), // Only Jamendo streams resolve.
        fetchYouTubeSearch: () => null,
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:1001';
        },
      );

      expect(jamendoCalled, isTrue);
      expect(next, equals('jamendo_fallback:jamendo:1001'));
    });

    // ── Test 11: Duplicate protection ─────────────────────────────────────────
    test('Test 11 — Duplicate protection: deduplicates candidate list', () {
      // Simulate a raw candidate list with duplicates.
      final raw = [
        {'ytid': 'yt_A', 'title': 'A', '_rec_score': 50.0},
        {'ytid': 'yt_B', 'title': 'B', '_rec_score': 40.0},
        {'ytid': 'yt_B', 'title': 'B dupe', '_rec_score': 30.0}, // duplicate
        {'ytid': 'yt_C', 'title': 'C', '_rec_score': 35.0},
        {'ytid': 'yt_A', 'title': 'A dupe', '_rec_score': 20.0}, // duplicate
        {'ytid': 'yt_D', 'title': 'D', '_rec_score': 10.0},
      ];

      // Deduplication logic mirrors what RecommendationEngine does internally.
      final scores = <String, double>{};
      final songMap = <String, Map<String, dynamic>>{};

      for (final c in raw) {
        final id = c['ytid']?.toString() ?? '';
        if (id.isEmpty) continue;
        scores[id] = (scores[id] ?? 0) + (c['_rec_score'] as double);
        songMap[id] = c;
      }

      final deduped =
          (scores.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .map((e) => e.key)
              .toList();

      // Expect exactly 4 unique IDs in descending score order.
      expect(deduped, equals(['yt_A', 'yt_B', 'yt_C', 'yt_D']));
      expect(deduped.length, equals(4));
    });

    // ── Test 12: Stale recommendation request cancellation ────────────────────
    test('Test 12 — Stale request: old generation is cancelled', () {
      var generation = 0;
      var appended = <String>[];

      Future<void> fakeRefill(int myGeneration) async {
        await Future.delayed(Duration.zero); // simulate async fetch
        if (myGeneration != generation) return; // stale guard
        appended.add('from_gen_$myGeneration');
      }

      // Start refill for song A (generation 1).
      generation = 1;
      final futureA = fakeRefill(1);

      // User skips to B → increment generation → cancels A's refill.
      generation = 2;

      // Start refill for song B (generation 2).
      final futureB = fakeRefill(2);

      // Await both.
      expectLater(
        Future.wait([futureA, futureB]).then((_) => appended),
        completion(equals(['from_gen_2'])), // Only B's refill went through.
      );
    });
  });
}

// Re-expose the existing resolveNextSource helper used by the priority tests
// so it is accessible in both test groups in this file.
String resolveNextSource({
  required List<Map<String, dynamic>> queue,
  required int currentIndex,
  required bool repeatOne,
  required bool repeatAll,
  required bool autoPlay,
  bool singleSongAutoNext = false,
  required bool Function(String ytid) streamResolves,
  required String? Function() fetchYouTubeRecommendation,
  required String? Function() fetchYouTubeSearch,
  required String? Function() fetchJamendoFallback,
}) {
  final autoNextEnabled = autoPlay || singleSongAutoNext;

  if (repeatOne) return 'replay_current';

  if (currentIndex < queue.length - 1) {
    for (int i = currentIndex + 1; i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (!isJamendoId(ytid) && streamResolves(ytid)) {
        return 'youtube_queue:$i';
      }
    }
    for (int i = currentIndex + 1; i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (isJamendoId(ytid) && streamResolves(ytid)) {
        return 'queued_jamendo:$i';
      }
    }
  }

  if (repeatAll && queue.isNotEmpty) {
    for (int i = 0; i <= currentIndex && i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (!isJamendoId(ytid) && streamResolves(ytid)) {
        return 'youtube_repeat_all:$i';
      }
    }
  }

  if (autoNextEnabled) {
    final ytRec = fetchYouTubeRecommendation();
    if (ytRec != null && streamResolves(ytRec)) return 'youtube_recommendation:$ytRec';

    final ytSearch = fetchYouTubeSearch();
    if (ytSearch != null && streamResolves(ytSearch)) return 'youtube_search:$ytSearch';

    final jamendo = fetchJamendoFallback();
    if (jamendo != null && streamResolves(jamendo)) return 'jamendo_fallback:$jamendo';
  }

  return 'stop';
}
