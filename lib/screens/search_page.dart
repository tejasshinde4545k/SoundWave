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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soundwave/constants/app_constants.dart';
import 'package:soundwave/database/radio_stations.db.dart';
import 'package:soundwave/extensions/l10n.dart';
import 'package:soundwave/main.dart';
import 'package:soundwave/models/radio_model.dart';
import 'package:soundwave/services/common_services.dart';
import 'package:soundwave/services/data_manager.dart';
import 'package:soundwave/services/playlists_manager.dart';
import 'package:soundwave/services/router_service.dart';
import 'package:soundwave/utilities/app_utils.dart';
import 'package:soundwave/utilities/flutter_toast.dart';
import 'package:soundwave/widgets/artist_bar.dart';
import 'package:soundwave/widgets/confirmation_dialog.dart';
import 'package:soundwave/widgets/custom_bar.dart';
import 'package:soundwave/widgets/custom_search_bar.dart';
import 'package:soundwave/widgets/mini_player_bottom_space.dart';
import 'package:soundwave/widgets/playlist_bar.dart';
import 'package:soundwave/widgets/radio_station_card.dart';
import 'package:soundwave/widgets/section_title.dart';
import 'package:soundwave/widgets/song_bar.dart';

// ─── Search Category ──────────────────────────────────────────────────────────

enum _SearchCategory { all, songs, artists, albums, playlists }

// ─── Popular Searches (static, no network) ────────────────────────────────────

const _popularSearches = [
  'Arijit Singh',
  'The Weeknd',
  'Taylor Swift',
  'Ed Sheeran',
  'Diljit Dosanjh',
  'Shreya Ghoshal',
];

// ─── Global reactive search history (unchanged from original) ─────────────────

final ValueNotifier<List> searchHistoryNotifier = ValueNotifier<List>(
  Hive.box('user').get('searchHistory', defaultValue: []),
);

List get searchHistory => searchHistoryNotifier.value;
set searchHistory(List value) {
  searchHistoryNotifier.value = value;
}

void reloadSearchHistoryFromStorage() {
  searchHistoryNotifier.value = Hive.box('user')
      .get('searchHistory', defaultValue: []);
}

// ─── SearchPage ───────────────────────────────────────────────────────────────

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  _SearchPageState createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  // ── Controllers / nodes ──────────────────────────────────────────────────
  final TextEditingController _searchBar = TextEditingController();
  final FocusNode _inputNode = FocusNode();
  final ValueNotifier<bool> _fetchingSongs = ValueNotifier(false);

  // ── Result lists (unchanged) ──────────────────────────────────────────────
  int maxSongsInList = 15;
  List<dynamic> _songsSearchResult = [];
  List<dynamic> _jamendoSearchResult = [];
  List<Map<String, dynamic>> _artistsSearchResult = [];
  List<dynamic> _albumsSearchResult = [];
  List<dynamic> _playlistsSearchResult = [];
  List<RadioStation> _radioStationsSearchResult = [];
  List<String> _suggestionsList = [];

  // ── Debounce / stale-request guards (unchanged) ───────────────────────────
  Timer? _debounce;
  int _latestSuggestionRequest = 0;
  int _latestSearchRequest = 0;

  // ── NEW UI state ──────────────────────────────────────────────────────────
  _SearchCategory _selectedCategory = _SearchCategory.all;
  bool _hasSearchError = false;

  // ── Skeleton pulse animation ──────────────────────────────────────────────
  late final AnimationController _skeletonController;
  late final Animation<double> _skeletonOpacity;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _skeletonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _skeletonOpacity = Tween<double>(begin: 0.35, end: 0.75).animate(
      CurvedAnimation(parent: _skeletonController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _searchBar.dispose();
    _inputNode.dispose();
    _fetchingSongs.dispose();
    _debounce?.cancel();
    _skeletonController.dispose();
    super.dispose();
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  bool get _hasQuery => _searchBar.text.isNotEmpty;

  bool get _hasResults =>
      _songsSearchResult.isNotEmpty ||
      _jamendoSearchResult.isNotEmpty ||
      _artistsSearchResult.isNotEmpty ||
      _albumsSearchResult.isNotEmpty ||
      _playlistsSearchResult.isNotEmpty ||
      _radioStationsSearchResult.isNotEmpty;


  // ─── Search logic (unchanged from original) ────────────────────────────────

  Future<void> _submitSearch([String? query]) async {
    if (query != null) {
      _searchBar.text = query;
      _searchBar.selection = TextSelection.fromPosition(
        TextPosition(offset: _searchBar.text.length),
      );
    }

    _latestSuggestionRequest++;
    _debounce?.cancel();
    _suggestionsList = [];
    if (mounted) setState(() {});

    await search();
    _inputNode.unfocus();
  }

  Future<void> search() async {
    final query = _searchBar.text;
    final requestId = ++_latestSearchRequest;

    if (query.isEmpty) {
      _songsSearchResult = [];
      _jamendoSearchResult = [];
      _artistsSearchResult = [];
      _albumsSearchResult = [];
      _playlistsSearchResult = [];
      _radioStationsSearchResult = [];
      _suggestionsList = [];
      _hasSearchError = false;
      _selectedCategory = _SearchCategory.all;
      if (mounted) setState(() {});
      return;
    }
    _fetchingSongs.value = true;
    _hasSearchError = false;
    if (mounted) setState(() {});

    if (!searchHistory.contains(query)) {
      final updatedHistory = List.from(searchHistory)..insert(0, query);
      searchHistoryNotifier.value = updatedHistory;
      unawaited(addOrUpdateData<List>('user', 'searchHistory', updatedHistory));
    }

    try {
      // ── Step 1: Search YouTube (Primary Source) ───────────────────────────
      final results = await Future.wait<List<dynamic>>([
        fetchSongsList(query),
        searchArtists(query),
        getPlaylists(query: query, type: 'album'),
        getPlaylists(query: query, type: 'playlist'),
      ]);

      if (!mounted || requestId != _latestSearchRequest) return;

      _songsSearchResult = results[0];
      _artistsSearchResult = results[1]
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      if (_songsSearchResult.isEmpty && _artistsSearchResult.isNotEmpty) {
        _songsSearchResult = await _fetchSongsForResolvedArtist(query);
      }
      _albumsSearchResult = results[2];
      _playlistsSearchResult = results[3];
      _radioStationsSearchResult = _filterRadioStations(query);

      // ── Step 2: Jamendo Fallback ──────────────────────────────────────────
      if (_songsSearchResult.isNotEmpty ||
          _artistsSearchResult.isNotEmpty ||
          _albumsSearchResult.isNotEmpty ||
          _playlistsSearchResult.isNotEmpty) {
        _jamendoSearchResult = [];
      } else {
        _jamendoSearchResult = await fetchJamendoSongsList(query);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error while searching YouTube songs; attempting Jamendo fallback',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted && requestId == _latestSearchRequest) {
        try {
          _jamendoSearchResult = await fetchJamendoSongsList(query);
        } catch (_) {
          _hasSearchError = true;
        }
      }
    } finally {
      if (requestId == _latestSearchRequest) {
        _fetchingSongs.value = false;
        if (mounted) setState(() {});
      }
    }
  }

  List<RadioStation> _filterRadioStations(String query) {
    return radioStationsDB
        .where(
          (station) =>
              station.name.toLowerCase().contains(query.toLowerCase()) ||
              (station.genre?.toLowerCase().contains(query.toLowerCase()) ??
                  false),
        )
        .toList();
  }

  Future<List<dynamic>> _fetchSongsForResolvedArtist(String query) async {
    final artistName = _artistsSearchResult.first['title']?.toString().trim();
    if (artistName == null || artistName.isEmpty) return [];

    final fallbackQueries = <String>{
      if (artistName.toLowerCase() != query.trim().toLowerCase()) artistName,
      '$artistName songs',
      '$artistName music',
    };

    for (final fallbackQuery in fallbackQueries) {
      final songs = await fetchSongsList(fallbackQuery);
      if (songs.isNotEmpty) return songs;
    }

    return [];
  }

  // ─── History helpers ────────────────────────────────────────────────────────

  void _removeHistoryItem(dynamic query) {
    final updatedHistory = List.from(searchHistory)..remove(query);
    searchHistoryNotifier.value = updatedHistory;
    unawaited(
      addOrUpdateData<List>('user', 'searchHistory', updatedHistory),
    );
  }

  void _clearAllHistory() {
    searchHistoryNotifier.value = [];
    unawaited(addOrUpdateData<List>('user', 'searchHistory', []));
  }

  Future<bool?> _showConfirmationDialog(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ConfirmationDialog(
          confirmationMessage: context.l10n!.removeSearchQueryQuestion,
          submitMessage: context.l10n!.confirm,
          onCancel: () {
            Navigator.of(context).pop(false);
          },
          onSubmit: () {
            Navigator.of(context).pop(true);
          },
        );
      },
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n!.search)),
      body: SingleChildScrollView(
        padding: commonSingleChildScrollViewPadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ── Search field ───────────────────────────────────────────────
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 600;
                final bar = ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isWide ? 600 : double.infinity,
                  ),
                  child: Semantics(
                    label: 'Search songs, artists, albums',
                    child: CustomSearchBar(
                      loadingProgressNotifier: _fetchingSongs,
                      controller: _searchBar,
                      focusNode: _inputNode,
                      labelText: 'Search songs, artists, albums...',
                      onChanged: (value) {
                        // Reset category filter when query changes
                        if (_selectedCategory != _SearchCategory.all) {
                          _selectedCategory = _SearchCategory.all;
                        }
                        _hasSearchError = false;

                        // Debounce suggestions (unchanged logic)
                        _debounce?.cancel();
                        final query = value;
                        final requestId = ++_latestSuggestionRequest;

                        if (query.isEmpty) {
                          _suggestionsList = [];
                          if (mounted) setState(() {});
                          return;
                        }

                        _debounce = Timer(
                          const Duration(milliseconds: 300),
                          () async {
                            final searchSuggestions =
                                await getSearchSuggestions(query);

                            if (!mounted ||
                                requestId != _latestSuggestionRequest ||
                                _searchBar.text != query) {
                              return;
                            }

                            _suggestionsList = List<String>.from(
                              searchSuggestions,
                            );
                            if (mounted) setState(() {});
                          },
                        );
                      },
                      onSubmitted: (String value) {
                        _submitSearch();
                      },
                    ),
                  ),
                );
                if (isWide) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [bar],
                  );
                } else {
                  return bar;
                }
              },
            ),

            // ── Body content area ──────────────────────────────────────────
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _buildBodyContent(primaryColor),
            ),

            const MiniPlayerBottomSpace(),
          ],
        ),
      ),
    );
  }

  // ─── Body content dispatcher ───────────────────────────────────────────────

  Widget _buildBodyContent(Color primaryColor) {
    // 1. Suggestions list (overrides everything)
    if (_suggestionsList.isNotEmpty) {
      return _buildSuggestionsList(key: const ValueKey('suggestions'));
    }

    // 2. Empty query → show empty/discovery state
    if (!_hasQuery) {
      return _buildEmptyState(key: const ValueKey('empty'));
    }

    // 3. Loading
    if (_fetchingSongs.value) {
      return _buildSkeletonLoader(key: const ValueKey('skeleton'));
    }

    // 4. Error state
    if (_hasSearchError && !_hasResults) {
      return _buildErrorState(key: const ValueKey('error'));
    }

    // 5. No results
    if (!_hasResults) {
      return _buildNoResultsState(key: const ValueKey('no-results'));
    }

    // 6. Results with category filter
    return _buildResultsWithFilters(
      primaryColor: primaryColor,
      key: ValueKey(
        'results-${_songsSearchResult.length}-${_artistsSearchResult.length}-${_selectedCategory.index}',
      ),
    );
  }

  // ─── Suggestions list (autocomplete, unchanged behaviour) ─────────────────

  Widget _buildSuggestionsList({Key? key}) {
    return ValueListenableBuilder<List>(
      key: key,
      valueListenable: searchHistoryNotifier,
      builder: (context, _, __) {
        return Column(
          children: [
            for (int index = 0; index < _suggestionsList.length; index++)
              Builder(
                builder: (context) {
                  final query = _suggestionsList[index];
                  final borderRadius = getItemBorderRadius(
                    index,
                    _suggestionsList.length,
                  );
                  return CustomBar(
                    query,
                    FluentIcons.search_24_regular,
                    borderRadius: borderRadius,
                    onTap: () async {
                      await _submitSearch(query);
                    },
                  );
                },
              ),
          ],
        );
      },
    );
  }

  // ─── Empty / Discovery state ───────────────────────────────────────────────

  Widget _buildEmptyState({Key? key}) {
    return ValueListenableBuilder<List>(
      key: key,
      valueListenable: searchHistoryNotifier,
      builder: (context, history, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final trimmedHistory = history.take(10).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Recent Searches ──────────────────────────────────────────
            if (trimmedHistory.isNotEmpty) ...[
              _SectionHeader(
                label: 'Recent Searches',
                trailing: trimmedHistory.isNotEmpty
                    ? Semantics(
                        label: 'Clear all recent searches',
                        child: TextButton(
                          onPressed: _clearAllHistory,
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.primary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            minimumSize: const Size(48, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'Clear',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 8),
              for (int i = 0; i < trimmedHistory.length; i++)
                Builder(
                  builder: (context) {
                    final query = trimmedHistory[i];
                    final borderRadius = getItemBorderRadius(
                      i,
                      trimmedHistory.length,
                    );
                    return CustomBar(
                      query.toString(),
                      FluentIcons.history_24_regular,
                      key: ValueKey('history-$i-$query'),
                      borderRadius: borderRadius,
                      onTap: () async {
                        await _submitSearch(query.toString());
                      },
                      onLongPress: () async {
                        final confirm =
                            await _showConfirmationDialog(context) ?? false;
                        if (confirm && searchHistory.contains(query)) {
                          _removeHistoryItem(query);
                        }
                      },
                      trailing: Semantics(
                        label: 'Remove $query from recent searches',
                        child: InkWell(
                          onTap: () => _removeHistoryItem(query),
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(
                              FluentIcons.dismiss_24_regular,
                              size: 16,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 24),
            ],

            // ── Popular Searches ─────────────────────────────────────────
            const _SectionHeader(label: 'Popular Searches'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _popularSearches
                  .map(
                    (tag) => Semantics(
                      label: 'Search for $tag',
                      child: _PopularChip(
                        label: tag,
                        onTap: () => _submitSearch(tag),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 24),

            // ── Empty-history placeholder ────────────────────────────────
            if (trimmedHistory.isEmpty)
              _buildDiscoveryPlaceholder(colorScheme),
          ],
        );
      },
    );
  }

  Widget _buildDiscoveryPlaceholder(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.music_note_2_24_regular,
              size: 52,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            Text(
              'Search for your favorite music',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Songs, artists, albums and more',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Skeleton loader ────────────────────────────────────────────────────────

  Widget _buildSkeletonLoader({Key? key}) {
    return AnimatedBuilder(
      key: key,
      animation: _skeletonOpacity,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final skeletonColor = colorScheme.onSurface.withValues(
          alpha: _skeletonOpacity.value * 0.12,
        );
        return Column(
          children: List.generate(
            5,
            (i) => Padding(
              padding: EdgeInsets.only(
                bottom: i < 4 ? 2 : 0,
              ),
              child: _SkeletonRow(color: skeletonColor),
            ),
          ),
        );
      },
    );
  }

  // ─── No results state ───────────────────────────────────────────────────────

  Widget _buildNoResultsState({Key? key}) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _searchBar.text;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.search_24_regular,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            Text(
              'No results found',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              query.isNotEmpty
                  ? 'No results for "$query"'
                  : 'Try a different song, artist, or album.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (query.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Try a different song, artist, or album.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Error state ─────────────────────────────────────────────────────────

  Widget _buildErrorState({Key? key}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.wifi_warning_24_regular,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              "Couldn't complete the search",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Semantics(
              label: 'Try search again',
              child: OutlinedButton.icon(
                onPressed: search,
                icon: const Icon(FluentIcons.arrow_counterclockwise_24_regular),
                label: const Text('Try again'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  side: BorderSide(
                    color: colorScheme.primary.withValues(alpha: 0.5),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  minimumSize: const Size(48, 48),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Results with category filter pills ────────────────────────────────────

  Widget _buildResultsWithFilters({
    required Color primaryColor,
    Key? key,
  }) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Category filter rail ───────────────────────────────────────
        _buildCategoryFilters(),
        const SizedBox(height: 8),

        // ── Filtered results ───────────────────────────────────────────
        _buildSearchResults(context, primaryColor),
      ],
    );
  }

  // ─── Category filter pills ─────────────────────────────────────────────────

  Widget _buildCategoryFilters() {
    final categories = <_SearchCategory, String>{
      _SearchCategory.all: 'All',
      _SearchCategory.songs: 'Songs',
      _SearchCategory.artists: 'Artists',
      _SearchCategory.albums: 'Albums',
      _SearchCategory.playlists: 'Playlists',
    };

    // Only include categories that have results
    final available = <_SearchCategory, String>{
      _SearchCategory.all: 'All',
    };
    if (_songsSearchResult.isNotEmpty || _jamendoSearchResult.isNotEmpty) {
      available[_SearchCategory.songs] = 'Songs';
    }
    if (_artistsSearchResult.isNotEmpty) {
      available[_SearchCategory.artists] = 'Artists';
    }
    if (_albumsSearchResult.isNotEmpty) {
      available[_SearchCategory.albums] = 'Albums';
    }
    if (_playlistsSearchResult.isNotEmpty) {
      available[_SearchCategory.playlists] = 'Playlists';
    }

    // Only show filter bar when more than just "All" is available
    if (available.length <= 1) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: available.entries.map((entry) {
          final category = entry.key;
          final label = categories[category] ?? entry.value;
          final isSelected = _selectedCategory == category;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              label: 'Filter by $label',
              selected: isSelected,
              child: _CategoryPill(
                label: label,
                isSelected: isSelected,
                onTap: () {
                  if (_selectedCategory != category) {
                    setState(() => _selectedCategory = category);
                  }
                },
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ─── Search results ────────────────────────────────────────────────────────

  Widget _buildSearchResults(BuildContext context, Color primaryColor) {
    final widgets = <Widget>[];

    // ── Songs (YouTube primary) ───────────────────────────────────────────
    if (_selectedCategory == _SearchCategory.all ||
        _selectedCategory == _SearchCategory.songs) {
      if (_songsSearchResult.isNotEmpty) {
        widgets.add(
          SectionTitle(
            context.l10n!.songs,
            primaryColor,
            icon: FluentIcons.music_note_1_24_filled,
          ),
        );

        final count = _songsSearchResult.length > maxSongsInList
            ? maxSongsInList
            : _songsSearchResult.length;

        for (var index = 0; index < count; index++) {
          final song = _songsSearchResult[index];
          final borderRadius = getItemBorderRadius(index, count);
          widgets.add(
            SongBar(
              song,
              true,
              key: listItemKey('search_song', index, song),
              showMusicDuration: true,
              borderRadius: borderRadius,
            ),
          );
        }
      }

      // ── Jamendo fallback (only when YouTube had nothing) ─────────────
      if (_jamendoSearchResult.isNotEmpty) {
        widgets.add(
          SectionTitle(
            '${context.l10n!.songs} · Jamendo (Fallback)',
            primaryColor,
            icon: FluentIcons.headphones_24_filled,
          ),
        );

        final jamendoCount = _jamendoSearchResult.length > maxSongsInList
            ? maxSongsInList
            : _jamendoSearchResult.length;

        for (var index = 0; index < jamendoCount; index++) {
          final song = _jamendoSearchResult[index];
          final borderRadius = getItemBorderRadius(index, jamendoCount);
          widgets.add(
            SongBar(
              song,
              true,
              key: listItemKey('search_jamendo', index, song),
              showMusicDuration: true,
              borderRadius: borderRadius,
            ),
          );
        }
      }
    }

    // ── Artists ───────────────────────────────────────────────────────────
    if (_selectedCategory == _SearchCategory.all ||
        _selectedCategory == _SearchCategory.artists) {
      if (_artistsSearchResult.isNotEmpty) {
        widgets.add(
          SectionTitle(
            context.l10n!.artists,
            primaryColor,
            icon: FluentIcons.person_24_filled,
          ),
        );

        final artists = _artistsSearchResult.take(3).toList();
        for (var index = 0; index < artists.length; index++) {
          final artist = Map<String, dynamic>.from(artists[index]);
          final artistId =
              artist['ytid']?.toString() ?? artist['title']?.toString() ?? '';
          if (artistId.isEmpty) continue;

          final borderRadius = getItemBorderRadius(index, artists.length);
          widgets.add(
            ArtistBar(
              key: listItemKey('search_artist', index, artist),
              artist: artist,
              borderRadius: borderRadius,
              onTap: () {
                context.push(
                  '${NavigationManager.searchPath}/artist/${Uri.encodeComponent(artistId)}',
                  extra: artist,
                );
              },
            ),
          );
        }
      }
    }

    // ── Albums ────────────────────────────────────────────────────────────
    if (_selectedCategory == _SearchCategory.all ||
        _selectedCategory == _SearchCategory.albums) {
      if (_albumsSearchResult.isNotEmpty) {
        widgets.add(
          SectionTitle(
            context.l10n!.albums,
            primaryColor,
            icon: FluentIcons.album_24_filled,
          ),
        );

        final albumsCount = _albumsSearchResult.length > maxSongsInList
            ? maxSongsInList
            : _albumsSearchResult.length;

        for (var index = 0; index < albumsCount; index++) {
          final playlist = _albumsSearchResult[index];
          final borderRadius = getItemBorderRadius(index, albumsCount);

          widgets.add(
            PlaylistBar(
              key: listItemKey('search_album', index, playlist),
              playlist['title'],
              playlistId: playlist['ytid'],
              playlistArtwork: playlist['image'],
              cubeIcon: FluentIcons.cd_16_filled,
              isAlbum: true,
              borderRadius: borderRadius,
            ),
          );
        }
      }
    }

    // ── Playlists ─────────────────────────────────────────────────────────
    if (_selectedCategory == _SearchCategory.all ||
        _selectedCategory == _SearchCategory.playlists) {
      if (_playlistsSearchResult.isNotEmpty) {
        widgets.add(
          SectionTitle(
            context.l10n!.playlists,
            primaryColor,
            icon: FluentIcons.text_bullet_list_24_filled,
          ),
        );

        final playlistsCount = _playlistsSearchResult.length > maxSongsInList
            ? maxSongsInList
            : _playlistsSearchResult.length;

        for (var index = 0; index < playlistsCount; index++) {
          final playlist = _playlistsSearchResult[index];
          final isLast = index == playlistsCount - 1;
          final borderRadius = getItemBorderRadius(index, playlistsCount);

          widgets.add(
            Padding(
              padding: isLast ? commonListViewBottomPadding : EdgeInsets.zero,
              child: PlaylistBar(
                key: listItemKey('search_playlist', index, playlist),
                playlist['title'],
                playlistId: playlist['ytid'],
                playlistArtwork: playlist['image'],
                cubeIcon: FluentIcons.apps_list_24_filled,
                borderRadius: borderRadius,
              ),
            ),
          );
        }
      }
    }

    // ── Radio stations (always shown under "All") ─────────────────────────
    if (_selectedCategory == _SearchCategory.all &&
        _radioStationsSearchResult.isNotEmpty) {
      widgets.add(
        SectionTitle(
          context.l10n!.radioStations,
          primaryColor,
          icon: FluentIcons.speaker_2_24_filled,
        ),
      );

      final stationsCount = _radioStationsSearchResult.length > maxSongsInList
          ? maxSongsInList
          : _radioStationsSearchResult.length;

      for (var index = 0; index < stationsCount; index++) {
        final station = _radioStationsSearchResult[index];
        final isLast = index == stationsCount - 1;

        widgets.add(
          Padding(
            padding: isLast ? commonListViewBottomPadding : EdgeInsets.zero,
            child: RadioStationCard(
              key: listItemKey('search_radio_station', index, station),
              station: station,
              onPressed: () async {
                final success = await audioHandler.playRadioStream(
                  id: station.id,
                  name: station.name,
                  streamUrl: station.streamUrl,
                  image: station.image,
                  genre: station.genre,
                );
                if (!success && context.mounted) {
                  showToast(context, context.l10n!.failedPlayingRadio);
                }
              },
            ),
          ),
        );
      }
    }

    // ── Empty category (filter active but no results for it) ──────────────
    if (widgets.isEmpty) {
      return _buildNoResultsState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

// ─── Private helper widgets ───────────────────────────────────────────────────

/// Section header with an optional trailing widget (e.g. "Clear" button).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize:
                    Theme.of(context).textTheme.titleMedium?.fontSize ?? 15,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Rounded pill for "Popular Searches" chips.
class _PopularChip extends StatelessWidget {
  const _PopularChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded pill for the category filter row.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Single skeleton row displayed while results are loading.
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          // Artwork placeholder
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(width: 14),
          // Text placeholders
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 13,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 11,
                  width: 120,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
