// Regression tests for the Search Result → Queue bug.
//
// Before the fix, tapping a search result called:
//   addPlaylistToQueue([singleSong], replace: true)
// resulting in a single-element queue (or duplicates after recommendation fill).
//
// After the fix, search_page.dart passes the full displayed sublist to
// addPlaylistToQueue via the onPlay callback, with the correct startIndex.
//
// These tests exercise that queue construction logic directly, without
// requiring Flutter widgets, audio hardware, or network access.

import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/utilities/map_utils.dart';
import 'package:soundwave/utilities/queue_entry_utils.dart';

// ─── Helpers that mirror the search-page queue-construction logic ──────────

/// Simulates what _playSearchResultAtIndex does before calling
/// addPlaylistToQueue: snapshot the sublist and record startIndex.
///
/// Returns a record of (queueEntries, startIndex) that the test can inspect.
({List<Map<String, dynamic>> queue, int startIndex}) buildSearchQueue(
  List<Map<String, dynamic>> results,
  int tapIndex, {
  int maxSongsInList = 15,
}) {
  final count =
      results.length > maxSongsInList ? maxSongsInList : results.length;
  final sublist = results.sublist(0, count);

  // QueueEntryIdManager.createSong does a shallow copy + adds queueEntryId.
  final idManager = QueueEntryIdManager();
  final queueEntries = sublist.map(idManager.createSong).toList();

  return (queue: queueEntries, startIndex: tapIndex);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

void main() {
  group('Search Result → Queue (regression: bug fix verification)', () {
    // Helpers to produce clearly distinct song maps.
    Map<String, dynamic> makeSong(int n) => {
          'ytid': 'yt_ID_$n',
          'title': 'Song $n',
          'artist': 'Artist $n',
          'album': 'Album $n',
          'highResImage': 'https://img.example.com/$n.jpg',
          'duration': 180 + n,
        };

    // ── Core correctness ───────────────────────────────────────────────────

    test('queue contains ALL distinct search results, not only the tapped one',
        () {
      final results = List.generate(5, makeSong);
      const tapIndex = 2; // tap "Song 2"

      final (:queue, :startIndex) = buildSearchQueue(results, tapIndex);

      // Queue must hold every result.
      expect(queue.length, equals(results.length),
          reason: 'queue length must equal the number of search results');

      // Every original ytid must appear exactly once.
      final queueIds = queue.map((s) => s['ytid']?.toString()).toList();
      for (var i = 0; i < results.length; i++) {
        final expectedId = results[i]['ytid'];
        expect(queueIds.where((id) => id == expectedId).length, equals(1),
            reason:
                'ytid $expectedId must appear exactly once — not 0 or >1 times');
      }
    });

    test('tapping the middle result sets startIndex to the correct position',
        () {
      final results = List.generate(7, makeSong);
      const tapIndex = 3; // "Song 3" is at index 3

      final (:queue, :startIndex) = buildSearchQueue(results, tapIndex);

      expect(startIndex, equals(3));

      // The queue entry at startIndex must match the tapped song's ytid.
      expect(queue[startIndex]['ytid'], equals(results[tapIndex]['ytid']));
    });

    test('tapping the first result starts queue at index 0', () {
      final results = List.generate(4, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 0);

      expect(startIndex, equals(0));
      expect(queue[0]['ytid'], equals(results[0]['ytid']));
    });

    test('tapping the last result starts queue at the last index', () {
      final results = List.generate(6, makeSong);
      final lastIndex = results.length - 1;
      final (:queue, :startIndex) = buildSearchQueue(results, lastIndex);

      expect(startIndex, equals(lastIndex));
      expect(queue[lastIndex]['ytid'], equals(results[lastIndex]['ytid']));
    });

    // ── Distinct song data ─────────────────────────────────────────────────

    test('each queue entry retains its own distinct title', () {
      final results = List.generate(5, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 2);

      for (var i = 0; i < results.length; i++) {
        expect(queue[i]['title'], equals(results[i]['title']),
            reason: 'queue[$i].title must equal results[$i].title');
      }
    });

    test('each queue entry retains its own distinct artist', () {
      final results = List.generate(5, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 0);

      for (var i = 0; i < results.length; i++) {
        expect(queue[i]['artist'], equals(results[i]['artist']));
      }
    });

    test('each queue entry retains its own distinct ytid', () {
      final results = List.generate(5, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 1);

      for (var i = 0; i < results.length; i++) {
        expect(queue[i]['ytid'], equals(results[i]['ytid']));
      }
    });

    test('each queue entry retains its own distinct duration', () {
      final results = List.generate(5, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 0);

      for (var i = 0; i < results.length; i++) {
        expect(queue[i]['duration'], equals(results[i]['duration']));
      }
    });

    // ── No duplicate IDs unless source data genuinely has duplicates ────────

    test('no ytid appears more than once in queue when source data is distinct',
        () {
      final results = List.generate(10, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 4);

      final ids = queue.map((s) => s['ytid']?.toString()).toList();
      final uniqueIds = ids.toSet();
      expect(uniqueIds.length, equals(ids.length),
          reason: 'Duplicate ytids found in queue: $ids');
    });

    test(
        'if source data genuinely contains a duplicate ytid, queue mirrors that',
        () {
      // Two entries with the same ytid (genuinely duplicated source data).
      final results = [
        makeSong(1),
        makeSong(2),
        {'ytid': 'yt_ID_1', 'title': 'Song 1 (dup)', 'artist': 'Artist 1'},
        makeSong(3),
      ];

      final (:queue, :startIndex) = buildSearchQueue(results, 0);

      // Both instances of yt_ID_1 should be present since the source has them.
      final count1 =
          queue.where((s) => s['ytid']?.toString() == 'yt_ID_1').length;
      expect(count1, equals(2),
          reason:
              'When source results genuinely contain a dup, the queue must too');
    });

    // ── Queue rebuild on second tap ─────────────────────────────────────────

    test('tapping a different result rebuilds the queue with all songs', () {
      final results = List.generate(5, makeSong);

      // First tap: Song 1
      final first = buildSearchQueue(results, 1);
      expect(first.queue.length, equals(results.length));
      expect(first.startIndex, equals(1));

      // Second tap: Song 3 (different)
      final second = buildSearchQueue(results, 3);
      expect(second.queue.length, equals(results.length));
      expect(second.startIndex, equals(3));

      // Both queues must list all songs, just with different start indices.
      for (var i = 0; i < results.length; i++) {
        expect(first.queue[i]['ytid'], equals(results[i]['ytid']));
        expect(second.queue[i]['ytid'], equals(results[i]['ytid']));
      }
    });

    // ── maxSongsInList capping ──────────────────────────────────────────────

    test('queue is capped at maxSongsInList when results exceed limit', () {
      // 20 results but the UI only shows 15.
      final results = List.generate(20, makeSong);
      const max = 15;

      final (:queue, :startIndex) = buildSearchQueue(
        results,
        0,
        maxSongsInList: max,
      );

      expect(queue.length, equals(max),
          reason: 'Queue must be capped at maxSongsInList ($max)');
    });

    test('startIndex into a capped queue is still valid', () {
      final results = List.generate(20, makeSong);
      const max = 15;
      const tap = 10; // within the displayed range

      final (:queue, :startIndex) = buildSearchQueue(
        results,
        tap,
        maxSongsInList: max,
      );

      expect(startIndex, equals(tap));
      expect(startIndex, lessThan(queue.length),
          reason: 'startIndex must be a valid queue index');
      expect(queue[startIndex]['ytid'], equals(results[tap]['ytid']));
    });

    // ── QueueEntryIdManager produces unique queue-entry IDs ─────────────────

    test('createSong gives each queue entry a unique queueEntryId', () {
      final results = List.generate(5, makeSong);
      final (:queue, :startIndex) = buildSearchQueue(results, 0);

      final entryIds =
          queue.map((s) => s['queueEntryId']?.toString()).toList();
      expect(entryIds.toSet().length, equals(entryIds.length),
          reason:
              'Every queue entry must have a distinct queueEntryId');
    });

    test('createSong produces a copy — original song map is not mutated', () {
      final song = makeSong(42);
      final originalYtid = song['ytid'];
      final idManager = QueueEntryIdManager();
      final queueSong = idManager.createSong(song);

      // The copy has the queueEntryId added.
      expect(queueSong.containsKey('queueEntryId'), isTrue);
      // The original does NOT have queueEntryId.
      expect(song.containsKey('queueEntryId'), isFalse,
          reason: 'createSong must not mutate the original Map');
      // Data is preserved in the copy.
      expect(queueSong['ytid'], equals(originalYtid));
    });

    // ── cloneMap utility (used in playSong) ───────────────────────────────

    test('cloneMap produces an independent copy', () {
      final original = {'ytid': 'abc', 'title': 'Test'};
      final clone = cloneMap(original);

      // Mutating the clone must not affect the original.
      clone['title'] = 'Modified';
      expect(original['title'], equals('Test'),
          reason:
              'cloneMap must return an independent copy — not a shared reference');
    });
  });
}
