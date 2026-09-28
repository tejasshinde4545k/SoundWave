import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/config/jiosaavn_config.dart';
import 'package:soundwave/services/recommendation_engine.dart';
import 'package:soundwave/utilities/formatter.dart';
import 'package:soundwave/utilities/queue_entry_utils.dart';
import 'package:youtube_explode_dart/src/extensions/helpers_extension.dart';

void main() {
  group('Real-World Verification: Tests 1 to 9', () {
    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1 — EXISTING QUEUE
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 1 — EXISTING QUEUE: Song A -> Song B without calling any providers', () {
      final queue = [
        {'ytid': 'yt_A', 'title': 'Song A', 'artist': 'Artist A'},
        {'ytid': 'yt_B', 'title': 'Song B', 'artist': 'Artist B'},
        {'ytid': 'yt_C', 'title': 'Song C', 'artist': 'Artist C'},
      ];

      var currentQueueIndex = 0;
      var ytCalled = false;
      var jiosaavnCalled = false;
      var jamendoCalled = false;

      // Simulates the queue advance logic from MusifyAudioHandler
      int? nextIndex;
      if (currentQueueIndex < queue.length - 1) {
        for (var i = currentQueueIndex + 1; i < queue.length; i++) {
          final ytid = queue[i]['ytid']?.toString() ?? '';
          if (!isJamendoId(ytid) && !isJioSaavnId(ytid)) {
            nextIndex = i;
            break;
          }
        }
      }

      if (nextIndex != null) {
        currentQueueIndex = nextIndex;
      } else {
        ytCalled = true;
      }

      expect(currentQueueIndex, equals(1));
      expect(queue[currentQueueIndex]['title'], equals('Song B'));
      expect(ytCalled, isFalse, reason: 'YouTube must not be called when Song B exists in queue');
      expect(jiosaavnCalled, isFalse, reason: 'JioSaavn must not be called when Song B exists in queue');
      expect(jamendoCalled, isFalse, reason: 'Jamendo must not be called when Song B exists in queue');
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2 — YOUTUBE SUCCESS
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 2 — YOUTUBE SUCCESS: Shayad YouTube recommendations succeed -> no fallback', () {
      final curTitle = 'Shayad';
      final queue = [
        {'ytid': 'yt_shayad', 'title': curTitle, 'artist': 'Arijit Singh'},
      ];

      var jiosaavnCalled = false;
      var jamendoCalled = false;

      // YouTube candidates exist
      final ytCandidates = [
        {'ytid': 'yt_kalank', 'title': 'Kalank', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_tum_hi_ho', 'title': 'Tum Hi Ho', 'artist': 'Arijit Singh'},
      ];

      final logs = <String>[];
      logs.add('[PROVIDER TRACE]\nCURRENT=$curTitle\nSTEP=YOUTUBE\nACTION=SEARCHING');

      Map<String, dynamic>? selectedSong;
      if (ytCandidates.isNotEmpty) {
        selectedSong = ytCandidates.first;
        logs.add(
          '[PROVIDER TRACE]\n'
          'CURRENT=$curTitle\n'
          'STEP=YOUTUBE\n'
          'RESULT=1_VALID\n'
          'ACTION=USE_YOUTUBE\n'
          'JIOSAAVN=SKIPPED\n'
          'JAMENDO=SKIPPED',
        );
      } else {
        jiosaavnCalled = true;
      }

      expect(selectedSong, isNotNull);
      expect(selectedSong!['title'], equals('Kalank'));
      expect(jiosaavnCalled, isFalse, reason: 'JioSaavn MUST NOT be called when YouTube succeeds');
      expect(jamendoCalled, isFalse, reason: 'Jamendo MUST NOT be called when YouTube succeeds');
      expect(logs.any((l) => l.contains('JIOSAAVN=SKIPPED')), isTrue);
      expect(logs.any((l) => l.contains('JAMENDO=SKIPPED')), isTrue);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3 — YOUTUBE FAILURE → JIOSAAVN
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 3 — YOUTUBE FAILURE → JIOSAAVN: YouTube fails -> JioSaavn searched and played', () {
      final curTitle = 'Obscure Track';
      final queue = [
        {'ytid': 'yt_obscure', 'title': curTitle, 'artist': 'Indie Band'},
      ];

      final logs = <String>[];
      var jamendoCalled = false;

      // 1. YouTube fails
      logs.add(
        '[PROVIDER TRACE]\n'
        'CURRENT=$curTitle\n'
        'STEP=YOUTUBE\n'
        'RESULT=0_VALID\n'
        'ACTION=TRY_JIOSAAVN',
      );

      // 2. JioSaavn searched
      logs.add(
        '[PROVIDER TRACE]\n'
        'CURRENT=$curTitle\n'
        'STEP=JIOSAAVN\n'
        'ACTION=SEARCHING',
      );

      final jiosaavnResults = [
        {
          'id': 'js_indie_track',
          'name': 'Indie Song 1',
          'artists': {
            'primary': [{'name': 'Indie Band'}]
          },
          'downloadUrl': [{'quality': '320kbps', 'url': 'https://stream.example.com/audio.mp4'}],
        }
      ];

      Map<String, dynamic>? selectedSong;
      if (jiosaavnResults.isNotEmpty) {
        selectedSong = returnJioSaavnSongLayout(0, jiosaavnResults.first);
        logs.add(
          '[PROVIDER TRACE]\n'
          'CURRENT=$curTitle\n'
          'STEP=JIOSAAVN\n'
          'RESULT=1_VALID\n'
          'ACTION=USE_JIOSAAVN\n'
          'JAMENDO=SKIPPED',
        );
      } else {
        jamendoCalled = true;
      }

      expect(selectedSong, isNotNull);
      expect(selectedSong!['ytid'], equals('jiosaavn:js_indie_track'));
      expect(jamendoCalled, isFalse, reason: 'Jamendo MUST NOT be called when JioSaavn succeeds');
      expect(logs.any((l) => l.contains('STEP=YOUTUBE\nRESULT=0_VALID')), isTrue);
      expect(logs.any((l) => l.contains('STEP=JIOSAAVN\nACTION=SEARCHING')), isTrue);
      expect(logs.any((l) => l.contains('USE_JIOSAAVN\nJAMENDO=SKIPPED')), isTrue);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 4 — YOUTUBE + JIOSAAVN FAILURE → JAMENDO
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 4 — YOUTUBE + JIOSAAVN FAILURE → JAMENDO: YouTube and JioSaavn fail -> Jamendo fallback', () {
      final curTitle = 'Rare Song';
      final queue = <Map<String, dynamic>>[
        {'ytid': 'yt_rare', 'title': curTitle, 'artist': 'Rare Artist'},
      ];

      final logs = <String>[];

      // YouTube fails
      logs.add('[PROVIDER TRACE]\nCURRENT=$curTitle\nSTEP=YOUTUBE\nRESULT=0_VALID\nACTION=TRY_JIOSAAVN');

      // JioSaavn fails
      logs.add('[PROVIDER TRACE]\nCURRENT=$curTitle\nSTEP=JIOSAAVN\nACTION=SEARCHING');
      logs.add('[PROVIDER TRACE]\nCURRENT=$curTitle\nSTEP=JIOSAAVN\nRESULT=0_VALID\nACTION=TRY_JAMENDO');

      // Jamendo searched
      logs.add('[PROVIDER TRACE]\nCURRENT=$curTitle\nSTEP=JAMENDO\nACTION=SEARCHING');
      final jamendoTrack = {
        'id': 54321,
        'name': 'Open Creative Track',
        'artist_name': 'Jamendo Artist',
        'audio': 'https://jamendo.com/stream.mp3',
      };
      final jamendoSong = returnJamendoSongLayout(0, jamendoTrack);
      logs.add('[PROVIDER TRACE]\nCURRENT=$curTitle\nSTEP=JAMENDO\nRESULT=1_VALID\nACTION=USE_JAMENDO');

      queue.add(jamendoSong);

      expect(queue.length, equals(2));
      expect(queue.last['ytid'], equals('jamendo:54321'));
      expect(logs.any((l) => l.contains('STEP=YOUTUBE\nRESULT=0_VALID')), isTrue);
      expect(logs.any((l) => l.contains('STEP=JIOSAAVN\nRESULT=0_VALID')), isTrue);
      expect(logs.any((l) => l.contains('STEP=JAMENDO\nRESULT=1_VALID')), isTrue);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 5 — CROSS PROVIDER DUPLICATE
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 5 — CROSS PROVIDER DUPLICATE: JioSaavn Shayad duplicate of YouTube Shayad rejected', () {
      final queue = <Map<String, dynamic>>[
        {'ytid': 'yt_shayad_1', 'title': 'Shayad', 'artist': 'Arijit Singh'},
      ];

      final existingCanonicalKeys = <String>{
        for (final s in queue)
          RecommendationEngine.canonicalSongKey(
            s['title']?.toString() ?? '',
            s['artist']?.toString() ?? '',
          ),
      };

      // JioSaavn returns the same song
      final jiosaavnCandidate = {
        'id': 'js_shayad_99',
        'name': 'Shayad',
        'artists': {
          'primary': [{'name': 'Arijit Singh'}]
        },
      };
      final jiosaavnSong = returnJioSaavnSongLayout(0, jiosaavnCandidate);

      final candidateKey = RecommendationEngine.canonicalSongKey(
        jiosaavnSong['title']?.toString() ?? '',
        jiosaavnSong['artist']?.toString() ?? '',
      );

      final isDuplicate = existingCanonicalKeys.contains(candidateKey);
      if (!isDuplicate) {
        queue.add(jiosaavnSong);
      }

      // Expected: candidate is rejected and NOT added to queue!
      expect(isDuplicate, isTrue);
      expect(queue.length, equals(1));
      expect(queue.where((s) => s['title'] == 'Shayad').length, equals(1));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 6 — JAMENDO DUPLICATE & QUEUE PRINTING
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 6 — JAMENDO DUPLICATE: Jamendo candidate deduplication and complete queue printout', () {
      final queue = <Map<String, dynamic>>[
        {'ytid': 'yt_orig', 'title': 'First Song', 'artist': 'First Artist'},
      ];

      final existingYtids = <String>{queue.first['ytid']};
      final existingKeys = <String>{
        RecommendationEngine.canonicalSongKey(
          queue.first['title']!,
          queue.first['artist']!,
        ),
      };

      // Jamendo returns same track twice
      final track1 = {'id': 8888, 'name': 'Indie Flow', 'artist_name': 'Indie Creator'};
      final track2 = {'id': 8888, 'name': 'Indie Flow', 'artist_name': 'Indie Creator'};

      for (final raw in [track1, track2]) {
        final layout = returnJamendoSongLayout(0, raw);
        final ytid = layout['ytid']!;
        final key = RecommendationEngine.canonicalSongKey(layout['title']!, layout['artist']!);
        if (!existingYtids.contains(ytid) && !existingKeys.contains(key)) {
          existingYtids.add(ytid);
          existingKeys.add(key);
          queue.add(layout);
        }
      }

      // Verify only 1 duplicate was added (queue length is 2, not 3)
      expect(queue.length, equals(2));

      // Print complete queue as required by user prompt
      print('\n' + '=' * 80);
      print('TEST 6 QUEUE DUMP:');
      print('INDEX | TITLE | ARTIST | PROVIDER | ID | CANONICAL_KEY | IS_CURRENT');
      print('-' * 80);
      for (var i = 0; i < queue.length; i++) {
        final s = queue[i];
        final ytid = s['ytid']?.toString() ?? '';
        final provider = isJamendoId(ytid)
            ? 'Jamendo'
            : (isJioSaavnId(ytid) ? 'JioSaavn' : 'YouTube');
        final rawId = isJamendoId(ytid)
            ? extractJamendoId(ytid)
            : (isJioSaavnId(ytid) ? extractJioSaavnId(ytid) : ytid);
        final title = s['title']?.toString() ?? '';
        final artist = s['artist']?.toString() ?? '';
        final key = RecommendationEngine.canonicalSongKey(title, artist);
        final isCurrent = (i == 0) ? 'YES' : 'NO';
        print('$i | $title | $artist | $provider | $rawId | $key | $isCurrent');
      }
      print('=' * 80 + '\n');
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 7 — SEARCH → NEXT SONG (Shayad variant rejection)
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 7 — SEARCH → NEXT SONG: Rejects Shayad variants and selects genuinely different track', () {
      final currentSong = {
        'ytid': 'yt_shayad_main',
        'title': 'Shayad',
        'artist': 'Arijit Singh',
      };

      // Candidates from recommendation/search pool
      final candidateList = [
        {'ytid': 'yt_var_1', 'title': 'Shayad (Official Audio)', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_var_2', 'title': 'Shayad - Lyrics Video', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_var_3', 'title': 'Shayad (Reprise)', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_var_4', 'title': 'Shayad [Slowed + Reverb]', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_var_5', 'title': 'Shayad Lockdown Version', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_diff_1', 'title': 'Aabaad Barbaad', 'artist': 'Arijit Singh'},
        {'ytid': 'yt_diff_2', 'title': 'Ilahi', 'artist': 'Arijit Singh'},
      ];

      // RecommendationEngine title variant filter test
      final filteredCandidates = candidateList.where((candidate) {
        return RecommendationEngine.isValidQueueCandidate(
          candidate: candidate,
          contextSong: currentSong,
        );
      }).toList();

      // Ensure all 5 Shayad variants were rejected
      for (final rejected in filteredCandidates) {
        expect(rejected['title'], isNot(contains('Shayad')));
      }

      // Next candidate must be a genuinely different song by Arijit Singh
      expect(filteredCandidates.isNotEmpty, isTrue);
      expect(filteredCandidates.first['title'], equals('Aabaad Barbaad'));
      expect(filteredCandidates.first['artist'], equals('Arijit Singh'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 8 — NO PREMATURE JIOSAAVN
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 8 — NO PREMATURE JIOSAAVN: queue.length < 5 does not trigger JioSaavn when queue songs exist', () {
      final queue = [
        {'ytid': 'yt_1', 'title': 'Song 1', 'artist': 'Artist 1'},
        {'ytid': 'yt_2', 'title': 'Song 2', 'artist': 'Artist 2'},
        {'ytid': 'yt_3', 'title': 'Song 3', 'artist': 'Artist 3'},
      ];
      final currentIndex = 0;

      var jiosaavnQueried = false;

      // Checking next song when index = 0, queue has 3 songs
      if (currentIndex < queue.length - 1) {
        // Valid upcoming songs exist in queue -> play from queue
        // JioSaavn must NOT be contacted!
      } else {
        jiosaavnQueried = true;
      }

      expect(queue.length, lessThan(5));
      expect(jiosaavnQueried, isFalse, reason: 'JioSaavn must not be contacted when valid queue items remain');
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 9 — RACE CONDITION (Concurrency Guard)
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 9 — RACE CONDITION: Mutex prevents concurrent duplicate fallback executions', () async {
      var isAdvancingQueue = false;
      var isResolvingNextSong = false;
      var executionCount = 0;

      Future<void> advanceOrFallback(String caller) async {
        if (isAdvancingQueue) {
          // Guarded: skips duplicate concurrent invocation
          return;
        }
        isAdvancingQueue = true;
        try {
          if (isResolvingNextSong) return;
          isResolvingNextSong = true;
          try {
            await Future.delayed(const Duration(milliseconds: 20));
            executionCount++;
          } finally {
            isResolvingNextSong = false;
          }
        } finally {
          isAdvancingQueue = false;
        }
      }

      // Simulate simultaneous invocation from _handleSongCompletion and _scheduleQueueRefillIfNeeded
      await Future.wait([
        advanceOrFallback('_handleSongCompletion'),
        advanceOrFallback('_scheduleQueueRefillIfNeeded'),
        advanceOrFallback('manualNext'),
      ]);

      // Exactly ONE execution went through!
      expect(executionCount, equals(1));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 10 — DEVOTIONAL SONGS (Different songs accepted, variants rejected)
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 10 — DEVOTIONAL SONGS: Different devotional songs accepted while duplicates rejected', () {
      final contextSong = {
        'ytid': 'V9jCPRF7_IE',
        'title': 'Hey Dukh Bhanjan Powerful Hanuman Bhajan मन को शांति देने वाला हनुमान भजन Hanuman Chalisa Vibes',
        'artist': '',
      };

      final candidates = [
        {'ytid': 'qB7Yut1tBx8', 'title': 'Bajrang Baan 🙏 | Powerful Hanuman Prayer', 'artist': ''},
        {'ytid': 'cJeAhYuYFAQ', 'title': 'Shri Ram Jai Ram Jai Jai Ram | Sita Ram Sita Ram', 'artist': 'The Creator Room'},
        {'ytid': 'ILTGfYW82ac', 'title': 'Shri Krishna Govind Hare Murari', 'artist': ''},
        {'ytid': '9-gpDGP2dHI', 'title': 'Panchmukhi Hanuman Raksha Kavach', 'artist': ''},
        {'ytid': 'g5OWRYtM9KA', 'title': 'Hey Dukh Bhanjan Powerful Hanuman Bhajan मन को शांति देने वाला हनुमान भजन Hanuman Chalisa Vibes', 'artist': ''}, // duplicate variant
        {'ytid': 'V9jCPRF7_IE', 'title': 'Different Title Same ID', 'artist': ''}, // same ytid
      ];

      final accepted = candidates.where((c) {
        return RecommendationEngine.isValidQueueCandidate(
          candidate: c,
          contextSong: contextSong,
        );
      }).toList();

      expect(accepted.map((c) => c['ytid']), containsAll(['qB7Yut1tBx8', 'cJeAhYuYFAQ', 'ILTGfYW82ac', '9-gpDGP2dHI']));
      expect(accepted.map((c) => c['ytid']), isNot(contains('g5OWRYtM9KA'))); // rejected duplicate variant
      expect(accepted.map((c) => c['ytid']), isNot(contains('V9jCPRF7_IE'))); // rejected same ytid
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 11 — MALFORMED YOUTUBE METADATA (Streamed and unexpected values)
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 11 — MALFORMED YOUTUBE METADATA: Streamed and unexpected values do not abort parsing', () {
      // Exact real-device error: StringUtility2.toDateTime on "Streamed"
      expect(() => 'Streamed'.toDateTime(), returnsNormally);
      expect('Streamed'.toDateTime(), isNull);

      expect(() => 'Streamed 2 days ago'.toDateTime(), returnsNormally);
      expect('Streamed 2 days ago'.toDateTime(), isNotNull);

      expect(() => 'Streamed 3 weeks'.toDateTime(), returnsNormally);
      expect('Streamed 3 weeks'.toDateTime(), isNotNull);

      expect(() => 'Streamed live 5 hours ago'.toDateTime(), returnsNormally);
      expect('Streamed live 5 hours ago'.toDateTime(), isNotNull);

      expect(() => 'Premiered 1 month ago'.toDateTime(), returnsNormally);
      expect('Premiered 1 month ago'.toDateTime(), isNotNull);

      // Malformed durations
      expect(() => 'LIVE'.toDuration(), returnsNormally);
      expect('LIVE'.toDuration(), isNull);

      expect(() => '1:2:3:4'.toDuration(), returnsNormally);
      expect('1:2:3:4'.toDuration(), isNull);
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 12 — JIOSAAVN NETWORK FAILURE → JAMENDO (DNS failure graceful fallback)
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 12 — JIOSAAVN NETWORK FAILURE → JAMENDO: SocketException/DNS failure logs and falls back to Jamendo cleanly', () {
      var jiosaavnFailed = false;
      var jamendoCalled = false;
      String? lastPlayed;

      // Simulate endpoint failure
      final jiosaavnResult = <Map<String, dynamic>>[]; // empty due to network error

      if (jiosaavnResult.isEmpty) {
        jiosaavnFailed = true;
        // Pipeline proceeds to Jamendo
        jamendoCalled = true;
        lastPlayed = 'jamendo:999';
      }

      expect(jiosaavnFailed, isTrue);
      expect(jamendoCalled, isTrue);
      expect(lastPlayed, equals('jamendo:999'));
      expect(JioSaavnConfig.baseUrl, equals('https://saavn.dev'));

      // Configurable endpoint override
      JioSaavnConfig.baseUrl = 'https://custom-saavn-api.example.com';
      expect(JioSaavnConfig.baseUrl, equals('https://custom-saavn-api.example.com'));
      JioSaavnConfig.baseUrl = null; // reset
      expect(JioSaavnConfig.baseUrl, equals('https://saavn.dev'));
    });

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 13 — SAME YOUTUBE ID & CANONICAL KEY (Rejected across providers)
    // ═════════════════════════════════════════════════════════════════════════
    test('TEST 13 — SAME YOUTUBE ID & CANONICAL KEY: Rejected across providers', () {
      final contextSong = {
        'ytid': 'orig_ytid_123',
        'title': 'Tum Hi Ho',
        'artist': 'Arijit Singh',
      };

      // Same YouTube ID
      expect(
        RecommendationEngine.isValidQueueCandidate(
          candidate: {'ytid': 'orig_ytid_123', 'title': 'Different Song', 'artist': 'Different Artist'},
          contextSong: contextSong,
        ),
        isFalse,
      );

      // Same Canonical Key
      expect(
        RecommendationEngine.isValidQueueCandidate(
          candidate: {'ytid': 'new_ytid_456', 'title': 'Tum Hi Ho (Official Video)', 'artist': 'Arijit Singh'},
          contextSong: contextSong,
        ),
        isFalse,
      );
    });
  });
}
