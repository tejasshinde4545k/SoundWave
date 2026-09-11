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

/// In-memory LRU recommendation cache keyed by YouTube video ID.
///
/// Stores up to [maxEntries] lists of candidate song maps for [ttl] before
/// expiry. Uses an insertion-order eviction strategy.
/// This is intentionally in-memory only — no Hive/database persistence.
class RecommendationCache {
  RecommendationCache._();

  /// Singleton instance.
  static final RecommendationCache instance = RecommendationCache._();

  /// Time-to-live for each cache entry.
  static const Duration ttl = Duration(minutes: 15);

  /// Maximum number of cache entries before the oldest is evicted.
  static const int maxEntries = 20;

  final Map<String, _CacheEntry> _cache = {};

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Returns the cached candidates for [ytid], or `null` when absent or expired.
  ///
  /// On a cache hit, the entry is refreshed to the end of the LRU order.
  List<Map<String, dynamic>>? get(String ytid) {
    final entry = _cache[ytid];
    if (entry == null) return null;

    if (DateTime.now().difference(entry.cachedAt) > ttl) {
      _cache.remove(ytid);
      return null;
    }

    // LRU: move to end of insertion order by re-inserting.
    _cache
      ..remove(ytid)
      ..[ytid] = entry;

    return List.unmodifiable(entry.candidates);
  }

  /// Stores [candidates] for [ytid], evicting the oldest entry when full.
  void put(String ytid, List<Map<String, dynamic>> candidates) {
    // Remove first so a fresh insert always lands at the end.
    _cache.remove(ytid);
    if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[ytid] = _CacheEntry(
      candidates: List.unmodifiable(candidates),
      cachedAt: DateTime.now(),
    );
  }

  /// Removes the entry for [ytid] if present.
  void invalidate(String ytid) => _cache.remove(ytid);

  /// Clears all cached entries.
  void clear() => _cache.clear();

  /// Returns the number of entries currently in the cache.
  int get length => _cache.length;
}

class _CacheEntry {
  const _CacheEntry({required this.candidates, required this.cachedAt});

  final List<Map<String, dynamic>> candidates;
  final DateTime cachedAt;
}
