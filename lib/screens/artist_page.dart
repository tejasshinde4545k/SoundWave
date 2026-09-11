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
import 'package:material_ui/material_ui.dart';
import 'package:soundwave/constants/app_constants.dart';
import 'package:soundwave/extensions/l10n.dart';
import 'package:soundwave/main.dart';
import 'package:soundwave/screens/playlist_page.dart';
import 'package:soundwave/services/artist_catalog_service.dart';
import 'package:soundwave/services/artist_image_resolver.dart';
import 'package:soundwave/services/artist_service.dart';
import 'package:soundwave/services/playlists_manager.dart';
import 'package:soundwave/services/router_service.dart';
import 'package:soundwave/services/settings_manager.dart';
import 'package:soundwave/utilities/app_utils.dart';
import 'package:soundwave/utilities/async_loader.dart';
import 'package:soundwave/utilities/flutter_toast.dart';
import 'package:soundwave/widgets/artist_shelf.dart';
import 'package:soundwave/widgets/mini_player_bottom_space.dart';
import 'package:soundwave/widgets/playlist_hero_artwork.dart';
import 'package:soundwave/widgets/playlist_page/add_to_playlist_button.dart';
import 'package:soundwave/widgets/playlist_page/download_button.dart';
import 'package:soundwave/widgets/playlist_page/empty_playlist_state.dart';
import 'package:soundwave/widgets/playlist_page/like_button.dart';
import 'package:soundwave/widgets/playlist_page/playlist_action_buttons.dart';
import 'package:soundwave/widgets/playlist_page/playlist_header.dart';
import 'package:soundwave/widgets/playlist_page/playlist_sliver_app_bar.dart';
import 'package:soundwave/widgets/section_header.dart';
import 'package:soundwave/widgets/song_bar.dart';
import 'package:soundwave/widgets/spinner.dart';

/// The page an artist opens on: who the artist is, its top songs, its releases
/// and related artists.
class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.artistId, this.artistData});

  final String artistId;
  final Map? artistData;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  /// Read the first time the page is shown online, and left alone offline,
  /// where the artist is its downloaded songs and there is nothing to read.
  Future<Map<String, dynamic>?>? _artistFuture;

  Map<String, dynamic>? _artist;
  Map<String, dynamic>? _catalog;
  Future<Map?>? _catalogFuture;
  List<Map<String, dynamic>> _albums = const [];
  List<Map<String, dynamic>> _singles = const [];
  List<Map<String, dynamic>> _relatedArtists = const [];

  Future<List<Map<String, dynamic>>>? _artistSongsFuture;
  List<Map<String, dynamic>> _artistSongs = const [];

  /// Whether the songs of the artist are being read for the play buttons.
  final _isLoadingCatalog = ValueNotifier<bool>(false);

  /// Cache for the resolved artist ID to avoid repeated lookups.
  String? _cachedResolvedArtistId;

  /// Cache for the artist title to avoid repeated lookups.
  String? _cachedArtistTitle;

  int _artistLoadGeneration = 0;

  /// Refresh artist data, preserving current state on failure.
  Future<void> _refresh() async {
    final generation = ++_artistLoadGeneration;
    final loaded = _artistFuture;
    _catalogFuture = null;
    final refreshed = _loadArtist(forceRefresh: true, refreshCatalog: true);
    // Block syntax: setState doesn't accept Future-returning callbacks
    setState(() {
      _artistFuture = refreshed;
    });

    Map<String, dynamic>? refreshedArtist;
    try {
      refreshedArtist = await refreshed;
    } catch (_) {
      refreshedArtist = null;
    }
    if (!mounted ||
        generation != _artistLoadGeneration ||
        refreshedArtist != null) {
      return;
    }
    setState(() {
      _artistFuture = loaded;
    });
    showToast(context, context.l10n!.error);
  }

  @override
  void didUpdateWidget(covariant ArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Artist identity is determined by ID only (data seed changes on rebuild)
    if (oldWidget.artistId != widget.artistId) {
      _artistLoadGeneration++;
      _artistFuture = null;
      _catalog = null;
      _catalogFuture = null;
      _cachedResolvedArtistId = null;
      _cachedArtistTitle = null;
    }
  }

  @override
  void dispose() {
    _isLoadingCatalog.dispose();
    super.dispose();
  }

  String get _resolvedArtistId => _cachedResolvedArtistId ??=
      _artist?['ytid']?.toString() ?? widget.artistId;

  String get _artistTitle => _cachedArtistTitle ??=
      _artist?['title']?.toString() ??
      widget.artistData?['title']?.toString() ??
      '';

  Future<Map<String, dynamic>?> _loadArtist({
    bool forceRefresh = false,
    bool refreshCatalog = false,
  }) async {
    final generation = _artistLoadGeneration;
    final artistData = widget.artistData;
    var artist = await getArtistProfile(
      widget.artistId,
      forceRefresh: forceRefresh,
      cacheResult: !refreshCatalog,
      preferredName: artistData?['title']?.toString(),
      preferredImage: artistData?['image']?.toString(),
      sourceSongId: artistData?['sourceSongId']?.toString(),
      sourceVideoAuthor: artistData?['videoAuthor']?.toString(),
      preferredVerified: artistData?['isVerifiedArtist'] == true,
    );

    // If YouTube Music profile is not found or fails, create a valid artist profile
    // from artistData/ID so ArtistPage always loads reliably
    artist ??= {
      'ytid': widget.artistId,
      'title': artistData?['title']?.toString() ?? widget.artistId,
      'image': artistData?['image']?.toString() ??
          ArtistImageResolver.instance.getCuratedOrCachedImage(widget.artistId),
      'topSongs': const [],
      'releases': const [],
      'relatedArtists': const [],
    };

    final title = artist['title']?.toString() ?? widget.artistId;
    final verifiedImg = artist['image']?.toString() ??
        await ArtistImageResolver.instance.resolveArtistImage(title);
    if (verifiedImg != null && verifiedImg.isNotEmpty) {
      artist['image'] = verifiedImg;
    }

    if (!mounted || generation != _artistLoadGeneration) {
      return null;
    }

    // Trigger on-demand fetching of all verified songs for this artist
    _artistSongsFuture = ArtistCatalogService.instance.getArtistSongs(
      title,
      artistId: widget.artistId,
      forceRefresh: forceRefresh,
    );

    unawaited(
      _artistSongsFuture!.then((songs) {
        if (mounted && generation == _artistLoadGeneration) {
          setState(() {
            _artistSongs = songs;
          });
        }
      }),
    );

    Map<String, dynamic>? catalog;
    if (refreshCatalog) {
      catalog = await getArtistCatalogFromProfile(artist, forceRebuild: true);
      if (catalog != null &&
          catalog['catalogStatus'] != 'failed' &&
          mounted &&
          generation == _artistLoadGeneration) {
        cacheArtistProfileInBackground(artist);
      }
    }

    _artist = artist;
    if (refreshCatalog) {
      _catalog = catalog;
      _catalogFuture = null;
    }
    // Clear caches when artist data updates
    _cachedResolvedArtistId = null;
    _cachedArtistTitle = null;
    _relatedArtists = asMapList(artist['relatedArtists']);
    final releases = asMapList(artist['releases']);
    _albums = releases.where((r) => !isSingleOrEpRelease(r)).toList();
    _singles = releases.where(isSingleOrEpRelease).toList();
    return artist;
  }

  @override
  Widget build(BuildContext context) {
    // Offline: show downloaded songs only; online: fetch full profile
    if (offlineMode.value) return _buildAllSongsPage();

    return AsyncLoader<Map<String, dynamic>?>(
      future: _artistFuture ??= _loadArtist(),
      loadingWidget: Scaffold(appBar: AppBar(), body: const Spinner()),
      emptyWidget: _buildNotFoundPage(),
      builder: (context, _) => Scaffold(
        body: Padding(
          padding: commonSingleChildScrollViewPadding,
          child: CustomScrollView(
            slivers: [
              PlaylistSliverAppBar(
                title: _artistTitle,
                artwork: (_artist?['image'] != null &&
                        _artist!['image'].toString().isNotEmpty)
                    ? PlaylistHeroArtwork(
                        _artist!,
                        cubeIcon: FluentIcons.person_24_filled,
                      )
                    : DedicatedArtistPlaceholder(
                        name: _artistTitle,
                        size: 200,
                      ),
              ),
              SliverToBoxAdapter(child: _buildHeaderSection()),
              SliverToBoxAdapter(child: _buildSongsSection()),
              if (_albums.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: ArtistShelf(
                      title: context.l10n!.albums,
                      icon: FluentIcons.cd_16_regular,
                      items: _albums,
                      subtitleOf: _releaseSubtitle,
                      onTap: _openRelease,
                    ),
                  ),
                ),
              if (_singles.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: ArtistShelf(
                      title: context.l10n!.singlesAndEps,
                      icon: FluentIcons.music_note_2_24_regular,
                      items: _singles,
                      subtitleOf: _releaseSubtitle,
                      onTap: _openRelease,
                    ),
                  ),
                ),
              if (_relatedArtists.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: ArtistShelf(
                      title: context.l10n!.suggestedArtists,
                      icon: FluentIcons.person_24_regular,
                      items: _relatedArtists,
                      cubeIcon: FluentIcons.person_24_filled,
                      circular: true,
                      onTap: _openArtist,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              const SliverToBoxAdapter(child: MiniPlayerBottomSpace()),
            ],
          ),
        ),
      ),
    );
  }

  /// The artist as its song list, which offline is the whole page.
  Widget _buildAllSongsPage() {
    return PlaylistPage(
      playlistId: widget.artistId,
      playlistData: artistPlaylistData({
        'ytid': widget.artistId,
        'title': _artistTitle,
        'image': _artist?['image'] ?? widget.artistData?['image'],
      }),
      cubeIcon: FluentIcons.person_24_filled,
      isArtist: true,
    );
  }

  Widget _buildNotFoundPage() {
    return Scaffold(
      appBar: AppBar(),
      body: CustomScrollView(
        slivers: [
          // Not finding an artist is an answer, not a failure of the app.
          EmptyPlaylistState(
            icon: FluentIcons.person_24_filled,
            message: context.l10n!.artistNotFound,
          ),
          const SliverMiniPlayerBottomSpace(),
        ],
      ),
    );
  }

  Widget _buildHeaderSection() {
    return Column(
      children: [
        PlaylistHeader(
          title: _artistTitle,
          isArtist: true,
          showTitle: false,
          monthlyListeners: _artist!['monthlyListeners']?.toString(),
          description: _artist!['description']?.toString(),
        ),
        _buildPlaybackButtons(),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 5,
          children: [
            PlaylistLikeButton(
              playlistId: _resolvedArtistId,
              playlistData: () => artistPlaylistData(_artist!, songs: const []),
            ),
            PlaylistAddToPlaylistButton(resolvePlaylist: _loadCatalog),
            // Downloading artist = downloading all its songs
            PlaylistDownloadButton(
              playlistId: _resolvedArtistId,
              resolvePlaylist: _loadCatalog,
              songs: _catalog?['list'] as List?,
              requireSnapshotMatch: true,
            ),
            IconButton.filledTonal(
              icon: const Icon(FluentIcons.arrow_sync_24_filled),
              iconSize: 24,
              onPressed: _refresh,
              tooltip: context.l10n!.update,
            ),
          ],
        ),
      ],
    );
  }

  /// Play all artist songs (synced with "All songs" queue).
  Widget _buildPlaybackButtons() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isLoadingCatalog,
      builder: (_, isLoading, __) => PlaylistActionButtons(
        isLoading: isLoading,
        onPlay: _playArtist,
        onShuffle: () => _playArtist(shuffle: true),
      ),
    );
  }

  Widget _buildSongsSection() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _artistSongsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            _artistSongs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: Spinner()),
          );
        }

        final songs =
            _artistSongs.isNotEmpty ? _artistSongs : (snapshot.data ?? const []);

        if (songs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.music_note_2_24_regular,
                    size: 44,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No songs found for this artist',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            SectionHeader(
              title: context.l10n?.songs ?? 'Songs',
              icon: FluentIcons.music_note_2_24_filled,
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: commonListViewBottomPadding,
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                return RepaintBoundary(
                  key: listItemKey('artist_catalog_song', index, song),
                  child: SongBar(
                    song,
                    true,
                    rank: index + 1,
                    borderRadius: getItemBorderRadius(index, songs.length),
                    onPlay: () => audioHandler.playPlaylistSong(
                      playlist: {'title': _artistTitle, 'list': songs},
                      songIndex: index,
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  String _releaseSubtitle(Map<String, dynamic> release) {
    final year = release['year']?.toString();
    final type = switch (release['releaseType']?.toString()) {
      'single' => context.l10n!.single,
      'ep' => 'EP',
      _ => context.l10n!.album,
    };
    return year == null || year.isEmpty ? type : '$type • $year';
  }

  // Shares the complete catalog with "All songs" and keeps it after the first
  // action so play, add and download cannot resolve different song snapshots.
  Future<Map?> _loadCatalog() async {
    final loadedCatalog = _catalog;
    if (loadedCatalog != null) return loadedCatalog;

    final inFlight = _catalogFuture;
    if (inFlight != null) return inFlight;

    final generation = _artistLoadGeneration;
    final artistId = _resolvedArtistId;
    final future = _resolveCatalog();
    _catalogFuture = future;
    final catalog = await future;

    final ownsFuture = identical(_catalogFuture, future);
    final isCurrent =
        mounted &&
        generation == _artistLoadGeneration &&
        artistId == _resolvedArtistId &&
        ownsFuture;
    if (ownsFuture) _catalogFuture = null;
    if (!isCurrent) return null;

    if (catalog != null && catalog['catalogStatus'] != 'failed') {
      setState(() {
        _catalog = Map<String, dynamic>.from(catalog);
      });
    }
    return catalog;
  }

  Future<Map?> _resolveCatalog() {
    final artist = _artist;
    if (artist != null) return getArtistCatalogFromProfile(artist);

    return getPlaylistInfoForWidget(
      _resolvedArtistId,
      isArtist: true,
      artistName: _artistTitle,
      artistImage: _artist?['image']?.toString(),
      preferredVerified: _artist?['isVerifiedArtist'] == true,
    );
  }

  Future<void> _playArtist({bool shuffle = false}) async {
    _isLoadingCatalog.value = true;
    try {
      final songs = _artistSongs.isNotEmpty
          ? _artistSongs
          : (await (_artistSongsFuture ??
              ArtistCatalogService.instance.getArtistSongs(
                _artistTitle,
                artistId: widget.artistId,
              )));
      if (!mounted) return;

      if (songs.isEmpty) {
        showToast(context, context.l10n!.error);
        return;
      }

      if (shuffle) {
        await audioHandler.addPlaylistToQueue(
          List<Map>.from(songs)..shuffle(),
          replace: true,
          startIndex: 0,
        );
      } else {
        await audioHandler.playPlaylistSong(
          playlist: {'title': _artistTitle, 'list': songs},
          songIndex: 0,
        );
      }
    } finally {
      if (mounted) _isLoadingCatalog.value = false;
    }
  }

  void _openArtist(Map<String, dynamic> artist) {
    final artistId = artist['ytid']?.toString();
    if (artistId == null || artistId.isEmpty) return;

    context.push(
      NavigationManager.artistPath(context, artistId),
      extra: artist,
    );
  }

  void _openRelease(Map<String, dynamic> release) {
    final releaseId = release['ytid']?.toString();
    if (releaseId == null || releaseId.isEmpty) return;

    context.push(
      NavigationManager.albumPath(context, releaseId),
      extra: release,
    );
  }
}
