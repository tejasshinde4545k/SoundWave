import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/services/recommendation_cache.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/utilities/formatter.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // JioSaavn, Jamendo & YouTube ID Scheme
  // ═══════════════════════════════════════════════════════════════════════════
  group('JioSaavn, Jamendo & YouTube ID Scheme', () {
    test('isJioSaavnId correctly identifies JioSaavn vs YouTube vs Jamendo IDs', () {
      expect(isJioSaavnId('jiosaavn:3IoDK8qI'), isTrue);
      expect(isJioSaavnId('jiosaavn:abc_123'), isTrue);
      expect(isJioSaavnId('jamendo:123456'), isFalse);
      expect(isJioSaavnId('dQw4w9WgXcQ'), isFalse);
      expect(isJioSaavnId('7wtfhZwyrcc'), isFalse);
      expect(isJioSaavnId(null), isFalse);
      expect(isJioSaavnId(''), isFalse);
    });

    test('extractJioSaavnId extracts raw alphanumeric id', () {
      expect(extractJioSaavnId('jiosaavn:3IoDK8qI'), equals('3IoDK8qI'));
      expect(extractJioSaavnId('jiosaavn:987654'), equals('987654'));
      expect(extractJioSaavnId('jamendo:123456'), isNull);
      expect(extractJioSaavnId('dQw4w9WgXcQ'), isNull);
      expect(extractJioSaavnId(null), isNull);
    });

    test('returnJioSaavnSongLayout formats tracks with jiosaavn ytid and source', () {
      final song = {
        'id': '3IoDK8qI',
        'name': 'Kesariya',
        'artists': {
          'primary': [
            {'name': 'Arijit Singh'},
          ],
        },
        'album': {'name': 'Brahmastra'},
        'duration': 268,
        'image': [
          {'quality': '50x50', 'url': 'https://example.com/50.jpg'},
          {'quality': '500x500', 'url': 'https://example.com/500.jpg'},
        ],
        'downloadUrl': [
          {'quality': '320kbps', 'url': 'https://example.com/stream.mp4'},
        ],
      };

      final layout = returnJioSaavnSongLayout(
        0,
        song,
        preResolvedStreamUrl: 'https://example.com/stream.mp4',
      );
      expect(layout['ytid'], equals('jiosaavn:3IoDK8qI'));
      expect(layout['source'], equals('jiosaavn'));
      expect(layout['title'], equals('Kesariya'));
      expect(layout['artist'], equals('Arijit Singh'));
      expect(layout['album'], equals('Brahmastra'));
      expect(layout['duration'], equals(268));
      expect(layout['highResImage'], equals('https://example.com/500.jpg'));
      expect(layout['jiosaavnAudioUrl'], equals('https://example.com/stream.mp4'));
      expect(isJioSaavnId(layout['ytid']), isTrue);
    });

    test('isJamendoId correctly identifies Jamendo vs YouTube vs JioSaavn IDs', () {
      expect(isJamendoId('jamendo:123456'), isTrue);
      expect(isJamendoId('jamendo:abc_xyz'), isTrue);
      expect(isJamendoId('jiosaavn:3IoDK8qI'), isFalse);
      expect(isJamendoId('dQw4w9WgXcQ'), isFalse);
      expect(isJamendoId('7wtfhZwyrcc'), isFalse);
      expect(isJamendoId(null), isFalse);
      expect(isJamendoId(''), isFalse);
    });

    test('extractJamendoId extracts raw id', () {
      expect(extractJamendoId('jamendo:123456'), equals('123456'));
      expect(extractJamendoId('jiosaavn:3IoDK8qI'), isNull);
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

  // ═══════════════════════════════════════════════════════════════════════════
  // Priority & Fallback Pipeline Scenarios: YouTube -> JioSaavn -> Jamendo
  // ═══════════════════════════════════════════════════════════════════════════
  group('Priority & Fallback Pipeline Scenarios', () {
    test('Test 1 — Existing queue has songs: plays next in queue (JioSaavn & Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:111';
        },
      );

      expect(next1, equals('youtube_queue:1'));
      expect(jiosaavnCalled, isFalse);
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:111';
        },
      );

      expect(next2, equals('youtube_queue:2'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 2 — YouTube queue exhausted: fetches YouTube recommendations (JioSaavn & Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:222';
        },
      );

      expect(next, equals('youtube_recommendation:yt_rec_1'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 3 — YouTube recommendation fails, but YouTube search succeeds (JioSaavn & Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeRecommendation: () => null, // Recommendation fails
        fetchYouTubeSearch: () => 'yt_search_result', // Search succeeds
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:222';
        },
      );

      expect(next, equals('youtube_search:yt_search_result'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 4 — YouTube fails completely: JioSaavn fallback called & succeeds (Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      // YouTube streams fail, JioSaavn succeeds
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (id) => isJioSaavnId(id),
        fetchYouTubeRecommendation: () => null,
        fetchYouTubeSearch: () => null,
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_kesariya';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:333';
        },
      );

      expect(jiosaavnCalled, isTrue);
      expect(jamendoCalled, isFalse);
      expect(next, equals('jiosaavn_fallback:jiosaavn:js_kesariya'));
    });

    test('Test 5 — YouTube fails AND JioSaavn fails: Jamendo fallback called & succeeds', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      // Both YouTube and JioSaavn fail; Jamendo succeeds
      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (id) => isJamendoId(id),
        fetchYouTubeRecommendation: () => null,
        fetchYouTubeSearch: () => null,
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return null; // JioSaavn has no results or failed
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:444';
        },
      );

      expect(jiosaavnCalled, isTrue);
      expect(jamendoCalled, isTrue);
      expect(next, equals('jamendo_fallback:jamendo:444'));
    });

    test('Test 6 — All fail: YouTube fails, JioSaavn fails, Jamendo fails -> player stops cleanly', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (_) => false, // No stream resolves
        fetchYouTubeRecommendation: () => null,
        fetchYouTubeSearch: () => null,
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return null;
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return null;
        },
      );

      expect(jiosaavnCalled, isTrue);
      expect(jamendoCalled, isTrue);
      expect(next, equals('stop'));
    });

    test('Test 7 — YouTube stream failure: B stream fails -> tries next valid YouTube option C', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:555';
        },
      );

      // Successfully skipped failed B to play YouTube C! JioSaavn & Jamendo NOT used.
      expect(next, equals('youtube_queue:2'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 8 — Repeat ONE: YouTube A finishes -> YouTube A starts again (JioSaavn & Jamendo NOT used)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:666';
        },
      );

      expect(next, equals('replay_current'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 9 — Repeat ALL: loops queue (JioSaavn & Jamendo NOT inserted)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:777';
        },
      );

      expect(next, equals('youtube_repeat_all:0'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 10 — Single YouTube song: queue.length == 1, song finishes -> plays YouTube recommendation', () {
      final queue = [
        {'ytid': 'yt_single_A', 'title': 'Single Song A'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:888';
        },
      );

      expect(next, equals('youtube_recommendation:yt_single_B'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 11 — Single YouTube song: queue.length == 1, YouTube exhausted -> JioSaavn fallback used', () {
      final queue = [
        {'ytid': 'yt_single_A', 'title': 'Single Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveNextSource(
        queue: queue,
        currentIndex: 0,
        repeatOne: false,
        repeatAll: false,
        autoPlay: true,
        streamResolves: (id) => isJioSaavnId(id),
        fetchYouTubeRecommendation: () => null,
        fetchYouTubeSearch: () => null,
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_single';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:999';
        },
      );

      expect(jiosaavnCalled, isTrue);
      expect(jamendoCalled, isFalse);
      expect(next, equals('jiosaavn_fallback:jiosaavn:js_single'));
    });

    test('Test 12 — Single YouTube song with global autoPlay = false: singleSongAutoNext = true -> advances to YouTube recommendation', () {
      final queue = [
        {'ytid': 'yt_search_song', 'title': 'Search Song'},
      ];

      var jiosaavnCalled = false;
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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:1010';
        },
      );

      expect(next, equals('youtube_recommendation:yt_next_rec'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 13 — Album with global autoPlay = false: singleSongAutoNext = false -> stops cleanly at end of album', () {
      final queue = [
        {'ytid': 'yt_album_1', 'title': 'Album Track 1'},
        {'ytid': 'yt_album_2', 'title': 'Album Track 2'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

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
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:1011';
        },
      );

      expect(next, equals('stop'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 14 — Cross-provider canonical deduplication: rejects JioSaavn duplicate of queued YouTube song', () {
      final queue = [
        {'ytid': 'yt_song_1', 'title': 'Shape of You', 'artist': 'Ed Sheeran'},
      ];

      final existingCanonicalKeys = <String>{
        for (final s in queue)
          RecommendationEngine.canonicalSongKey(
            s['title']?.toString() ?? '',
            s['artist']?.toString() ?? '',
          ),
      };

      // JioSaavn returns the same track
      final candidateTitle = 'Shape of You';
      final candidateArtist = 'Ed Sheeran';
      final candidateKey = RecommendationEngine.canonicalSongKey(
        candidateTitle,
        candidateArtist,
      );

      // Verify that canonicalSongKey identifies it as duplicate
      expect(existingCanonicalKeys.contains(candidateKey), isTrue);

      // A different JioSaavn track is accepted
      final differentKey = RecommendationEngine.canonicalSongKey(
        'Bad Habits',
        'Ed Sheeran',
      );
      expect(existingCanonicalKeys.contains(differentKey), isFalse);
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
    String resolveWithRefill({
      required List<Map<String, dynamic>> initialQueue,
      required List<Map<String, dynamic>> queueAfterRefill,
      required int currentIndex,
      required bool autoPlay,
      bool refillInProgress = false,
      required bool Function(String ytid) streamResolves,
      required String? Function() fetchYouTubeSearch,
      String? Function()? fetchJioSaavnFallback,
      required String? Function() fetchJamendoFallback,
    }) {
      // Step 1: scan initial queue ahead (YouTube songs first).
      for (var i = currentIndex + 1; i < initialQueue.length; i++) {
        final ytid = initialQueue[i]['ytid']?.toString() ?? '';
        if (!isJamendoId(ytid) && !isJioSaavnId(ytid) && streamResolves(ytid)) {
          return 'youtube_queue:$i';
        }
      }

      if (!autoPlay) return 'stop';

      // Step 2a: if refill was in progress, simulate completing it and
      // re-scan queueAfterRefill.
      final queue = refillInProgress ? queueAfterRefill : initialQueue;
      for (var i = currentIndex + 1; i < queue.length; i++) {
        final ytid = queue[i]['ytid']?.toString() ?? '';
        if (!isJamendoId(ytid) && !isJioSaavnId(ytid) && streamResolves(ytid)) {
          return 'youtube_queue_post_refill:$i';
        }
      }

      // Step 2b: immediate refill (same queue since we already simulated it).
      for (var i = currentIndex + 1; i < queueAfterRefill.length; i++) {
        final ytid = queueAfterRefill[i]['ytid']?.toString() ?? '';
        if (!isJamendoId(ytid) && !isJioSaavnId(ytid) && streamResolves(ytid)) {
          return 'youtube_queue_immediate_refill:$i';
        }
      }

      // Step 3: YouTube search safety-net.
      final ytSearch = fetchYouTubeSearch();
      if (ytSearch != null && streamResolves(ytSearch)) {
        return 'youtube_search:$ytSearch';
      }

      // Step 4: JioSaavn fallback.
      if (fetchJioSaavnFallback != null) {
        final jiosaavn = fetchJioSaavnFallback();
        if (jiosaavn != null && streamResolves(jiosaavn)) {
          return 'jiosaavn_fallback:$jiosaavn';
        }
      }

      // Step 5: Jamendo fallback.
      final jamendo = fetchJamendoFallback();
      if (jamendo != null && streamResolves(jamendo)) {
        return 'jamendo_fallback:$jamendo';
      }

      return 'stop';
    }

    test('Test 1 — Single song: background refill adds multiple YouTube songs', () {
      final initialQueue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];
      final queueAfterRefill = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
        {'ytid': 'yt_D', 'title': 'Song D'},
        {'ytid': 'yt_E', 'title': 'Song E'},
        {'ytid': 'yt_F', 'title': 'Song F'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: initialQueue,
        queueAfterRefill: queueAfterRefill,
        currentIndex: 0,
        autoPlay: true,
        refillInProgress: true,
        streamResolves: (_) => true,
        fetchYouTubeSearch: () => 'yt_fallback_search',
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:111';
        },
      );

      expect(next, startsWith('youtube_queue'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 2 — A finishes → B automatically starts (no manual Next)', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
        {'ytid': 'yt_B', 'title': 'Song B'},
        {'ytid': 'yt_C', 'title': 'Song C'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: queue,
        queueAfterRefill: queue,
        currentIndex: 0,
        autoPlay: true,
        streamResolves: (_) => true,
        fetchYouTubeSearch: () => 'yt_search',
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_1';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:222';
        },
      );

      expect(next, equals('youtube_queue:1'));
      expect(jiosaavnCalled, isFalse);
      expect(jamendoCalled, isFalse);
    });

    test('Test 3 — Dynamic refill: YouTube exhausted -> JioSaavn fallback used', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: queue,
        queueAfterRefill: queue,
        currentIndex: 0,
        autoPlay: true,
        streamResolves: (id) => isJioSaavnId(id),
        fetchYouTubeSearch: () => null,
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return 'jiosaavn:js_fallback';
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:333';
        },
      );

      expect(jiosaavnCalled, isTrue);
      expect(jamendoCalled, isFalse);
      expect(next, equals('jiosaavn_fallback:jiosaavn:js_fallback'));
    });

    test('Test 4 — All YouTube & JioSaavn exhausted → Jamendo fallback', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      final next = resolveWithRefill(
        initialQueue: queue,
        queueAfterRefill: queue,
        currentIndex: 0,
        autoPlay: true,
        streamResolves: (id) => isJamendoId(id), // Only Jamendo streams resolve.
        fetchYouTubeSearch: () => null,
        fetchJioSaavnFallback: () {
          jiosaavnCalled = true;
          return null;
        },
        fetchJamendoFallback: () {
          jamendoCalled = true;
          return 'jamendo:1001';
        },
      );

      expect(jiosaavnCalled, isTrue);
      expect(jamendoCalled, isTrue);
      expect(next, equals('jamendo_fallback:jamendo:1001'));
    });

    test('Test 5 — Duplicate protection: deduplicates candidate list', () {
      final raw = [
        {'ytid': 'yt_A', 'title': 'A', '_rec_score': 50.0},
        {'ytid': 'yt_B', 'title': 'B', '_rec_score': 40.0},
        {'ytid': 'yt_B', 'title': 'B dupe', '_rec_score': 30.0},
        {'ytid': 'yt_C', 'title': 'C', '_rec_score': 35.0},
        {'ytid': 'yt_A', 'title': 'A dupe', '_rec_score': 20.0},
        {'ytid': 'yt_D', 'title': 'D', '_rec_score': 10.0},
      ];

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

      expect(deduped, equals(['yt_A', 'yt_B', 'yt_C', 'yt_D']));
      expect(deduped.length, equals(4));
    });

    test('Test 6 — Stale recommendation request: old generation is cancelled', () {
      var generation = 0;
      var appended = <String>[];

      Future<void> fakeRefill(int myGeneration) async {
        await Future.delayed(Duration.zero);
        if (myGeneration != generation) return;
        appended.add('from_gen_$myGeneration');
      }

      generation = 1;
      final futureA = fakeRefill(1);

      generation = 2;
      final futureB = fakeRefill(2);

      expectLater(
        Future.wait([futureA, futureB]).then((_) => appended),
        completion(equals(['from_gen_2'])),
      );
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// Priority resolution decision helper
// Order: Queue -> YouTube -> JioSaavn -> Jamendo -> Stop
// ═══════════════════════════════════════════════════════════════════════════
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
  String? Function()? fetchJioSaavnFallback,
  required String? Function() fetchJamendoFallback,
}) {
  final autoNextEnabled = autoPlay || singleSongAutoNext;

  if (repeatOne) return 'replay_current';

  // Step 1: Check existing queue.
  if (currentIndex < queue.length - 1) {
    // 1a. YouTube items first.
    for (int i = currentIndex + 1; i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (!isJamendoId(ytid) && !isJioSaavnId(ytid) && streamResolves(ytid)) {
        return 'youtube_queue:$i';
      }
    }
    // 1b. Queued JioSaavn items.
    for (int i = currentIndex + 1; i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (isJioSaavnId(ytid) && streamResolves(ytid)) {
        return 'queued_jiosaavn:$i';
      }
    }
    // 1c. Queued Jamendo items.
    for (int i = currentIndex + 1; i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (isJamendoId(ytid) && streamResolves(ytid)) {
        return 'queued_jamendo:$i';
      }
    }
  }

  // Repeat ALL: loop queue (YouTube songs first).
  if (repeatAll && queue.isNotEmpty) {
    for (int i = 0; i <= currentIndex && i < queue.length; i++) {
      final ytid = queue[i]['ytid']?.toString() ?? '';
      if (!isJamendoId(ytid) && !isJioSaavnId(ytid) && streamResolves(ytid)) {
        return 'youtube_repeat_all:$i';
      }
    }
  }

  // Step 2, 3, 4: Fallback pipeline
  if (autoNextEnabled) {
    // Primary: YouTube recommendation.
    final ytRec = fetchYouTubeRecommendation();
    if (ytRec != null && streamResolves(ytRec)) return 'youtube_recommendation:$ytRec';

    // Primary safety net: YouTube search.
    final ytSearch = fetchYouTubeSearch();
    if (ytSearch != null && streamResolves(ytSearch)) return 'youtube_search:$ytSearch';

    // Secondary: JioSaavn fallback.
    if (fetchJioSaavnFallback != null) {
      final jiosaavn = fetchJioSaavnFallback();
      if (jiosaavn != null && streamResolves(jiosaavn)) return 'jiosaavn_fallback:$jiosaavn';
    }

    // Tertiary: Jamendo fallback.
    final jamendo = fetchJamendoFallback();
    if (jamendo != null && streamResolves(jamendo)) return 'jamendo_fallback:$jamendo';
  }

  return 'stop';
}
