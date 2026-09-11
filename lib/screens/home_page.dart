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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soundwave/constants/app_constants.dart';
import 'package:soundwave/database/albums.db.dart';
import 'package:soundwave/database/radio_stations.db.dart';
import 'package:soundwave/extensions/l10n.dart';
import 'package:soundwave/main.dart';
import 'package:soundwave/services/artist_image_resolver.dart';
import 'package:soundwave/services/best_artists_service.dart';
import 'package:soundwave/services/common_services.dart';
import 'package:soundwave/services/listening_stats_service.dart';
import 'package:soundwave/services/playlists_manager.dart';
import 'package:soundwave/services/release_metadata_service.dart';
import 'package:soundwave/services/router_service.dart';
import 'package:soundwave/services/settings_manager.dart';
import 'package:soundwave/utilities/app_utils.dart';
import 'package:soundwave/utilities/artwork_provider.dart';
import 'package:soundwave/utilities/async_loader.dart';
import 'package:soundwave/utilities/listening_stats_utils.dart';
import 'package:soundwave/widgets/announcement_box.dart';
import 'package:soundwave/widgets/listening_recap_card.dart';
import 'package:soundwave/widgets/mini_player_bottom_space.dart';
import 'package:soundwave/widgets/no_artwork_cube.dart';
import 'package:soundwave/widgets/playlist_cube.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Future<List> _suggestedPlaylistsFuture;
  late Future<List> _recommendedSongsFuture;
  late Future<List<Map<String, dynamic>>> _releasedThisWeekFuture;
  late Future<List<Map<String, dynamic>>> _bestArtistsFuture;
  Future<List>? _featuredArtistSongsFuture;

  String _selectedCategory = 'All';
  final List<String> _categories = const [
    'All',
    'Music',
    'Podcasts',
    'Playlists',
    'Artists',
  ];

  String _featuredArtistName = 'The Weeknd';
  String? _featuredArtistImage;
  bool _isArtistResolved = false;

  @override
  void initState() {
    super.initState();
    _suggestedPlaylistsFuture = getPlaylists(
      playlistsNum: recommendedCubesNumber,
    );
    _recommendedSongsFuture = getRecommendedSongs();
    _releasedThisWeekFuture =
        ReleaseMetadataService.instance.getReleasesThisWeek();
    _bestArtistsFuture = BestArtistsService.instance.getBestArtists();
    externalRecommendations.addListener(_refreshRecommendedSongs);
    musicRegionSetting.addListener(_refreshRecommendedSongs);
    userRecentlyPlayed.addListener(_onRecentsChanged);
    _resolveFeaturedArtist();
  }

  @override
  void dispose() {
    externalRecommendations.removeListener(_refreshRecommendedSongs);
    musicRegionSetting.removeListener(_refreshRecommendedSongs);
    userRecentlyPlayed.removeListener(_onRecentsChanged);
    super.dispose();
  }

  void _onRecentsChanged() {
    if (!_isArtistResolved && mounted) {
      _resolveFeaturedArtist();
    }
  }

  void _resolveFeaturedArtist() {
    String? resolvedArtist;
    String? resolvedImage;

    // 1. Prioritize artist from user recently played
    if (userRecentlyPlayed.value.isNotEmpty) {
      for (final song in userRecentlyPlayed.value) {
        if (song is Map && song['artist'] != null) {
          final artistStr = song['artist'].toString().trim();
          if (artistStr.isNotEmpty &&
              !ArtistImageResolver.isRecordLabelOrChannel(artistStr)) {
            resolvedArtist = artistStr;
            resolvedImage = ArtistImageResolver.instance
                .getCuratedOrCachedImage(artistStr);
            _isArtistResolved = true;
            break;
          }
        }
      }
    }

    // 2. Fallback to liked songs
    if (resolvedArtist == null && userLikedSongsList.value.isNotEmpty) {
      for (final song in userLikedSongsList.value) {
        if (song is Map && song['artist'] != null) {
          final artistStr = song['artist'].toString().trim();
          if (artistStr.isNotEmpty &&
              !ArtistImageResolver.isRecordLabelOrChannel(artistStr)) {
            resolvedArtist = artistStr;
            resolvedImage = ArtistImageResolver.instance
                .getCuratedOrCachedImage(artistStr);
            _isArtistResolved = true;
            break;
          }
        }
      }
    }

    // 3. Fallback to albums in database
    if (resolvedArtist == null && albumsDB.isNotEmpty) {
      for (final album in albumsDB) {
        final rawTitle = album['title']?.toString() ?? '';
        var candidateArtist = rawTitle;
        if (rawTitle.contains(' - ')) {
          candidateArtist = rawTitle.split(' - ')[1].trim();
        }
        if (candidateArtist.isNotEmpty &&
            !ArtistImageResolver.isRecordLabelOrChannel(candidateArtist)) {
          resolvedArtist = candidateArtist;
          resolvedImage = ArtistImageResolver.instance
              .getCuratedOrCachedImage(candidateArtist);
          break;
        }
      }
    }

    resolvedArtist ??= 'The Weeknd';

    // Normalize name (remove multiple artists delimiter for clean artist search)
    if (resolvedArtist.contains(',')) {
      resolvedArtist = resolvedArtist.split(',')[0].trim();
    }
    if (resolvedArtist.contains('&')) {
      resolvedArtist = resolvedArtist.split('&')[0].trim();
    }

    if (mounted) {
      setState(() {
        _featuredArtistName = resolvedArtist!;
        _featuredArtistImage = resolvedImage;
        _featuredArtistSongsFuture = fetchSongsList(
          '$_featuredArtistName songs',
        );
      });
    } else {
      _featuredArtistName = resolvedArtist;
      _featuredArtistImage = resolvedImage;
      _featuredArtistSongsFuture = fetchSongsList('$_featuredArtistName songs');
    }
  }

  void _refreshRecommendedSongs() {
    if (!mounted) return;
    setState(() {
      _recommendedSongsFuture = getRecommendedSongs();
      _releasedThisWeekFuture = ReleaseMetadataService.instance
          .getReleasesThisWeek(forceRefresh: true);
      _bestArtistsFuture =
          BestArtistsService.instance.getBestArtists(forceRefresh: true);
    });
  }

  double _getCardWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 360) return 126;
    if (width >= 600) return 160;
    return 138;
  }

  double _getArtistAvatarSize(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 360) return 80;
    if (width >= 600) return 100;
    return 88;
  }

  double _getArtistCardWidth(BuildContext context) {
    final avatarSize = _getArtistAvatarSize(context);
    return avatarSize + 12;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cardWidth = _getCardWidth(context);

    return Scaffold(
      appBar: _buildTopHeader(context, colorScheme),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            _buildCategoryFilters(colorScheme),
            const SizedBox(height: 6),

            // Optional Announcement
            ValueListenableBuilder<String?>(
              valueListenable: announcementURL,
              builder: (_, url, __) {
                if (url == null) return const SizedBox.shrink();
                final isSponsorship = isSponsorshipAnnouncementUrl(url);
                final message = isSponsorship
                    ? context.l10n!.sponsorProject
                    : context.l10n!.newAnnouncement;
                final icon = isSponsorship
                    ? FluentIcons.heart_24_filled
                    : FluentIcons.megaphone_24_filled;

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: AnnouncementBox(
                    message: message,
                    url: url,
                    icon: icon,
                    onDismiss: () async {
                      announcementURL.value = null;
                    },
                  ),
                );
              },
            ),

            // Content Sections based on selected category
            if (_selectedCategory == 'All' || _selectedCategory == 'Music') ...[
              _buildRecommendedForTodaySection(colorScheme, cardWidth),
              _buildReleasedThisWeekSection(colorScheme, cardWidth),
              _buildBestArtistsSection(colorScheme),
              _buildMoreLikeArtistSection(colorScheme, cardWidth),
            ],

            if (_selectedCategory == 'All') ...[
              _buildAlbumsFeaturingSongsYouLikeSection(colorScheme, cardWidth),
            ],

            if (_selectedCategory == 'All' || _selectedCategory == 'Music') ...[
              _buildRecentsSection(colorScheme, cardWidth),
            ],

            if (_selectedCategory == 'Playlists') ...[
              _buildPlaylistsCategoryView(context),
            ],

            if (_selectedCategory == 'Podcasts') ...[
              _buildPodcastsCategoryView(context, cardWidth),
            ],

            if (_selectedCategory == 'Artists') ...[
              _buildArtistsCategoryView(colorScheme, cardWidth),
            ],

            if (_selectedCategory == 'All') ...[
              _buildCurrentMonthRecapSection(),
            ],

            const MiniPlayerBottomSpace(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. Top Header
  // ---------------------------------------------------------------------------
  PreferredSizeWidget _buildTopHeader(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    return AppBar(
      toolbarHeight: 56,
      scrolledUnderElevation: 0,
      leadingWidth: 56,
      leading: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Center(
          child: GestureDetector(
            onTap: () => context.push('/settings'),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: colorScheme.primary,
              child: ClipOval(
                child: Image.asset(
                  'assets/icons/soundwave.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Text(
                    'S',
                    style: TextStyle(
                      color: colorScheme.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      centerTitle: true,
      title: Text(
        'SoundWave.',
        style: TextStyle(
          fontFamily: 'paytoneOne',
          fontSize: 23,
          color: colorScheme.primary,
          letterSpacing: -0.5,
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(FluentIcons.search_24_regular, size: 23),
          visualDensity: VisualDensity.compact,
          onPressed: () => context.push('/search'),
          tooltip: context.l10n?.search ?? 'Search',
        ),
        IconButton(
          icon: const Icon(FluentIcons.settings_24_regular, size: 23),
          visualDensity: VisualDensity.compact,
          onPressed: () => context.push('/settings'),
          tooltip: context.l10n?.settings ?? 'Settings',
        ),
        const SizedBox(width: 6),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 2. Category Filter Pills
  // ---------------------------------------------------------------------------
  Widget _buildCategoryFilters(ColorScheme colorScheme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: _categories.map((category) {
          final isSelected = _selectedCategory == category;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                if (_selectedCategory != category) {
                  setState(() {
                    _selectedCategory = category;
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  category,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected
                        ? colorScheme.onPrimary
                        : colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3. ✨ Recommended for Today
  // ---------------------------------------------------------------------------
  Widget _buildRecommendedForTodaySection(
    ColorScheme colorScheme,
    double cardWidth,
  ) {
    final title = context.l10n?.recommendedForYou ?? 'Recommended for today';

    return FutureBuilder<List>(
      future: _recommendedSongsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HomeSectionHeader(
                title: title,
                icon: Icon(
                  FluentIcons.sparkle_24_filled,
                  color: colorScheme.primary,
                  size: 21,
                ),
              ),
              _buildRailSkeleton(cardWidth),
            ],
          );
        }

        final songs = snapshot.data ?? [];
        if (songs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HomeSectionHeader(
              title: title,
              icon: Icon(
                FluentIcons.sparkle_24_filled,
                color: colorScheme.primary,
                size: 21,
              ),
              actionText: 'See all >',
              onActionTap: () {
                context.push(
                  NavigationManager.playlistPath(context, 'recommended'),
                  extra: {
                    'ytid': 'recommended',
                    'title': title,
                    'image': songs.isNotEmpty ? songs.first['image'] : null,
                    'list': songs,
                  },
                );
              },
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(songs.length, (index) {
                  final song = songs[index];
                  final isAlbum = song['isAlbum'] == true;
                  final typeLabel = isAlbum ? 'Album' : 'Single';

                  return Padding(
                    padding: const EdgeInsets.only(right: 13),
                    child: _HorizontalContentCard(
                      width: cardWidth,
                      imageUrl: song['image']?.toString(),
                      typeLabel: typeLabel,
                      title: song['title']?.toString() ?? '',
                      subtitle: song['artist']?.toString() ?? '',
                      onTap: () async {
                        await audioHandler.playPlaylistSong(
                          playlist: {'title': title, 'list': songs},
                          songIndex: index,
                        );
                      },
                    ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 3b. 📅 Released This Week
  // ---------------------------------------------------------------------------
  Widget _buildReleasedThisWeekSection(
    ColorScheme colorScheme,
    double cardWidth,
  ) {
    const title = 'Released This Week';

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _releasedThisWeekFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HomeSectionHeader(
                title: title,
                icon: Icon(
                  FluentIcons.calendar_ltr_24_filled,
                  color: colorScheme.primary,
                  size: 21,
                ),
              ),
              _buildRailSkeleton(cardWidth),
            ],
          );
        }

        final songs = snapshot.data ?? [];
        if (songs.isEmpty) return const SizedBox.shrink();

        final weekRange = ReleaseMetadataService.instance.getCurrentWeekRange();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HomeSectionHeader(
              title: title,
              icon: Icon(
                FluentIcons.calendar_ltr_24_filled,
                color: colorScheme.primary,
                size: 21,
              ),
              actionText: 'See all >',
              onActionTap: () {
                context.push(
                  NavigationManager.releasedThisWeekPath,
                  extra: {
                    'songs': songs,
                    'weekRange': weekRange.formattedRange,
                  },
                );
              },
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(songs.length, (index) {
                  final song = songs[index];
                  final isAlbum = song['isAlbum'] == true;
                  final typeLabel = isAlbum ? 'Album' : 'Single';

                  return Padding(
                    padding: const EdgeInsets.only(right: 13),
                    child: _HorizontalContentCard(
                      width: cardWidth,
                      imageUrl: song['image']?.toString(),
                      typeLabel: typeLabel,
                      title: song['title']?.toString() ?? '',
                      subtitle: song['artist']?.toString() ?? '',
                      onTap: () async {
                        await audioHandler.playPlaylistSong(
                          playlist: {'title': title, 'list': songs},
                          songIndex: index,
                        );
                      },
                    ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 3b. 🌟 Best Artists Section
  // ---------------------------------------------------------------------------
  Widget _buildBestArtistsSection(ColorScheme colorScheme) {
    final avatarSize = _getArtistAvatarSize(context);
    final cardWidth = _getArtistCardWidth(context);

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _bestArtistsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HomeSectionHeader(
                title: 'Best Artists',
                icon: Icon(
                  FluentIcons.people_star_24_filled,
                  color: colorScheme.primary,
                  size: 21,
                ),
              ),
              _buildArtistRailSkeleton(avatarSize, cardWidth),
            ],
          );
        }

        final artists = snapshot.data ?? [];
        if (artists.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HomeSectionHeader(
              title: 'Best Artists',
              icon: Icon(
                FluentIcons.people_star_24_filled,
                color: colorScheme.primary,
                size: 21,
              ),
              actionText: 'See all >',
              onActionTap: () {
                context.push(
                  NavigationManager.bestArtistsPath,
                  extra: {'artists': artists},
                );
              },
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(artists.length, (index) {
                  final artist = artists[index];
                  final name = artist['title']?.toString() ?? '';
                  final imageUrl = artist['image']?.toString();

                  return Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: _HomeArtistCard(
                      width: cardWidth,
                      avatarSize: avatarSize,
                      name: name,
                      imageUrl: imageUrl,
                      onTap: () {
                        context.push(
                          NavigationManager.artistPath(context, name),
                          extra: artist,
                        );
                      },
                    ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildArtistRailSkeleton(double avatarSize, double cardWidth) {
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: List.generate(5, (index) {
          return Padding(
            padding: const EdgeInsets.only(right: 14),
            child: SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: avatarSize,
                    height: avatarSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: avatarSize * 0.75,
                    height: 12,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. 👤 More like [Artist]
  // ---------------------------------------------------------------------------
  Widget _buildMoreLikeArtistSection(
    ColorScheme colorScheme,
    double cardWidth,
  ) {
    if (_featuredArtistSongsFuture == null) return const SizedBox.shrink();

    return FutureBuilder<List>(
      future: _featuredArtistSongsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ArtistSectionHeader(
                artistName: _featuredArtistName,
                artistImageUrl: _featuredArtistImage,
                onTap: () {
                  context.push(
                    NavigationManager.artistPath(context, _featuredArtistName),
                  );
                },
              ),
              _buildRailSkeleton(cardWidth),
            ],
          );
        }

        final songs = snapshot.data ?? [];
        if (songs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ArtistSectionHeader(
              artistName: _featuredArtistName,
              artistImageUrl: _featuredArtistImage,
              onTap: () {
                context.push(
                  NavigationManager.artistPath(context, _featuredArtistName),
                );
              },
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(songs.length, (index) {
                  final song = songs[index];
                  final isAlbum = song['isAlbum'] == true;
                  final typeLabel = isAlbum ? 'Album' : 'Single';

                  return Padding(
                    padding: const EdgeInsets.only(right: 13),
                    child: _HorizontalContentCard(
                      width: cardWidth,
                      imageUrl: song['image']?.toString(),
                      typeLabel: typeLabel,
                      title: song['title']?.toString() ?? '',
                      subtitle:
                          song['artist']?.toString() ?? _featuredArtistName,
                      onTap: () async {
                        await audioHandler.playPlaylistSong(
                          playlist: {
                            'title': 'More like $_featuredArtistName',
                            'list': songs,
                          },
                          songIndex: index,
                        );
                      },
                    ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 5. 📈 Albums Featuring Songs You Like
  // ---------------------------------------------------------------------------
  Widget _buildAlbumsFeaturingSongsYouLikeSection(
    ColorScheme colorScheme,
    double cardWidth,
  ) {
    if (albumsDB.isEmpty) return const SizedBox.shrink();

    // Take a curated horizontal selection of real albums from albumsDB
    final albums = albumsDB.take(12).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HomeSectionHeader(
          title: 'Albums featuring songs you like',
          icon: Icon(
            FluentIcons.data_trending_24_filled,
            color: colorScheme.primary,
            size: 21,
          ),
          actionText: 'See all >',
          onActionTap: () {
            context.push('/home/library');
          },
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(albums.length, (index) {
              final album = albums[index];
              final rawTitle = album['title']?.toString() ?? '';
              var albumTitle = rawTitle;
              var artistName = '';

              if (rawTitle.contains(' - ')) {
                final parts = rawTitle.split(' - ');
                albumTitle = parts[0].trim();
                artistName = parts.sublist(1).join(' - ').trim();
              }

              final isCompilation =
                  rawTitle.toLowerCase().contains('hits') ||
                  rawTitle.toLowerCase().contains('forever') ||
                  rawTitle.toLowerCase().contains('best') ||
                  rawTitle.toLowerCase().contains('compilation');

              final typeLabel = isCompilation ? 'Compilation' : 'Album';

              return Padding(
                padding: const EdgeInsets.only(right: 13),
                child: _HorizontalContentCard(
                  width: cardWidth,
                  imageUrl: album['image']?.toString(),
                  typeLabel: typeLabel,
                  title: albumTitle,
                  subtitle: artistName,
                  onTap: () {
                    context.push(
                      '/home/playlist/${album['ytid']}',
                      extra: album,
                    );
                  },
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 6. 🕘 Recents
  // ---------------------------------------------------------------------------
  Widget _buildRecentsSection(ColorScheme colorScheme, double cardWidth) {
    final recentsTitle = context.l10n?.recentlyPlayed ?? 'Recents';

    return ValueListenableBuilder<List>(
      valueListenable: userRecentlyPlayed,
      builder: (context, recentSongs, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HomeSectionHeader(
              title: recentsTitle,
              icon: Icon(
                FluentIcons.history_24_filled,
                color: colorScheme.primary,
                size: 21,
              ),
              actionText: recentSongs.isNotEmpty ? 'Show all >' : null,
              onActionTap: recentSongs.isNotEmpty
                  ? () {
                      NavigationManager.router.go('/library/userSongs/recents');
                    }
                  : null,
            ),
            if (recentSongs.isEmpty)
              _buildRecentsEmptyState(colorScheme)
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(recentSongs.length, (index) {
                    final song = recentSongs[index];
                    return Padding(
                      padding: const EdgeInsets.only(right: 13),
                      child: _HorizontalContentCard(
                        width: cardWidth,
                        imageUrl: song['image']?.toString(),
                        typeLabel: 'Recent',
                        title: song['title']?.toString() ?? '',
                        subtitle: song['artist']?.toString() ?? '',
                        onTap: () async {
                          await audioHandler.playPlaylistSong(
                            playlist: {
                              'title': recentsTitle,
                              'list': recentSongs,
                            },
                            songIndex: index,
                          );
                        },
                      ),
                    );
                  }),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRecentsEmptyState(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.history_24_regular,
              size: 28,
              color: colorScheme.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 8),
            Text(
              'No recently played tracks',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Songs you listen to will appear here',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Category Dedicated Views (Playlists, Podcasts/Radio, Artists)
  // ---------------------------------------------------------------------------
  Widget _buildPlaylistsCategoryView(BuildContext context) {
    final playlistHeight = MediaQuery.sizeOf(context).height * 0.25 / 1.1;
    return Column(
      children: [
        _buildSuggestedPlaylists(playlistHeight),
        _buildSuggestedPlaylists(playlistHeight, showOnlyLiked: true),
      ],
    );
  }

  Widget _buildPodcastsCategoryView(BuildContext context, double cardWidth) {
    final colorScheme = Theme.of(context).colorScheme;
    final stations = radioStationsDB.take(12).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HomeSectionHeader(
          title: context.l10n?.radioStations ?? 'Live Stations & Podcasts',
          icon: Icon(
            FluentIcons.sound_source_24_filled,
            color: colorScheme.primary,
            size: 21,
          ),
          actionText: 'See all >',
          onActionTap: () => context.push('/library/radioStations'),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: stations.map((station) {
              return Padding(
                padding: const EdgeInsets.only(right: 13),
                child: _HorizontalContentCard(
                  width: cardWidth,
                  imageUrl: station.image,
                  typeLabel: station.genre ?? 'Station',
                  title: station.name,
                  subtitle: station.genre ?? 'Live Radio',
                  onTap: () {
                    audioHandler.playRadioStream(
                      id: station.id,
                      name: station.name,
                      streamUrl: station.streamUrl,
                      image: station.image,
                      genre: station.genre,
                    );
                  },
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistsCategoryView(ColorScheme colorScheme, double cardWidth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBestArtistsSection(colorScheme),
        _buildMoreLikeArtistSection(colorScheme, cardWidth),
        ValueListenableBuilder<List<Map>>(
          valueListenable: userLikedPlaylists,
          builder: (context, likedPlaylists, _) {
            final artistPlaylists = likedPlaylists
                .where(isArtistPlaylist)
                .toList();
            if (artistPlaylists.isEmpty) return const SizedBox.shrink();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HomeSectionHeader(
                  title: 'Favorite Artists',
                  icon: Icon(
                    FluentIcons.people_24_filled,
                    color: colorScheme.primary,
                    size: 21,
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: artistPlaylists.map((artist) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 13),
                        child: _HorizontalContentCard(
                          width: cardWidth,
                          imageUrl: artist['image']?.toString(),
                          typeLabel: 'Artist',
                          title: artist['title']?.toString() ?? '',
                          subtitle: 'Artist profile',
                          onTap: () {
                            context.push(
                              '/home/playlist/${artist['ytid']}',
                              extra: artist,
                            );
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Original Suggested Playlists (Preserved for Playlists filter and All)
  // ---------------------------------------------------------------------------
  Widget _buildSuggestedPlaylists(
    double playlistHeight, {
    bool showOnlyLiked = false,
  }) {
    if (showOnlyLiked) {
      return ValueListenableBuilder<List<Map>>(
        valueListenable: userLikedPlaylists,
        builder: (_, likedPlaylists, __) => _buildSuggestedPlaylistsSection(
          playlistHeight,
          likedPlaylists
              .where((playlist) => !isArtistPlaylist(playlist))
              .take(recommendedCubesNumber)
              .toList(),
          showOnlyLiked: true,
        ),
      );
    }

    return AsyncLoader<List<dynamic>>(
      future: _suggestedPlaylistsFuture,
      builder: (context, playlists) =>
          _buildSuggestedPlaylistsSection(playlistHeight, playlists),
    );
  }

  Widget _buildSuggestedPlaylistsSection(
    double playlistHeight,
    List<dynamic> playlists, {
    bool showOnlyLiked = false,
  }) {
    if (playlists.isEmpty) return const SizedBox.shrink();

    final sectionTitle = showOnlyLiked
        ? context.l10n!.backToFavorites
        : context.l10n!.suggestedPlaylists;
    final itemsNumber = playlists.length.clamp(0, recommendedCubesNumber);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HomeSectionHeader(
          title: sectionTitle,
          icon: Icon(
            showOnlyLiked
                ? FluentIcons.heart_24_filled
                : FluentIcons.list_24_filled,
            color: Theme.of(context).colorScheme.primary,
            size: 21,
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: playlistHeight),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: itemsNumber,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => context.push(
                    NavigationManager.playlistPath(context, playlist['ytid']),
                    extra: playlist,
                  ),
                  child: PlaylistCube(playlist, size: playlistHeight),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Monthly Recap (Time Machine)
  // ---------------------------------------------------------------------------
  Widget _buildCurrentMonthRecapSection() {
    return ValueListenableBuilder<bool>(
      valueListenable: wrappedEnabled,
      builder: (_, isEnabled, __) {
        if (!isEnabled) return const SizedBox.shrink();

        final currentMonthKey = listeningStatsMonthKey(DateTime.now());
        final monthStats = listeningStatsService.monthStats(currentMonthKey);
        final songs = listeningStatsService.monthTopSongs(currentMonthKey);
        final displayMinutes = monthDisplayMinutes(monthStats);
        if (displayMinutes <= 0 && songs.isEmpty) {
          return const SizedBox.shrink();
        }

        final previewSongs = songs.take(wrappedShareSongsLimit).toList();
        final periodLabel = formatMonthPeriodLabel(
          Localizations.localeOf(context),
          currentMonthKey,
        );

        return Column(
          children: [
            _HomeSectionHeader(
              title: context.l10n!.timeMachine,
              icon: Icon(
                FluentIcons.data_trending_24_filled,
                color: Theme.of(context).colorScheme.primary,
                size: 21,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListeningRecapCard(
                periodLabel: periodLabel,
                minutes: displayMinutes,
                songs: previewSongs,
                onSongTap: (index) => _playRecapSongs(previewSongs, index),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => context.push('/home/timeMachine'),
                  icon: const Icon(FluentIcons.arrow_right_24_regular),
                  label: Text(context.l10n!.listeningStats),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _playRecapSongs(
    List<Map<String, dynamic>> songs,
    int index,
  ) async {
    if (songs.isEmpty) return;
    await audioHandler.playPlaylistSong(
      playlist: {'title': context.l10n!.timeMachine, 'list': songs},
      songIndex: index,
    );
  }

  // ---------------------------------------------------------------------------
  // Skeleton Loader for Rails
  // ---------------------------------------------------------------------------
  Widget _buildRailSkeleton(double cardWidth) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: List.generate(4, (index) {
          return Padding(
            padding: const EdgeInsets.only(right: 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: cardWidth,
                  height: cardWidth,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  width: cardWidth * 0.45,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  width: cardWidth * 0.85,
                  height: 12,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: cardWidth * 0.6,
                  height: 10,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.3,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// =============================================================================
// Reusable Modular Section Headers & Content Cards
// =============================================================================

class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({
    required this.title,
    this.icon,
    this.actionText,
    this.onActionTap,
  });

  final String title;
  final Widget? icon;
  final String? actionText;
  final VoidCallback? onActionTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
      child: Row(
        children: [
          if (icon != null) ...[icon!, const SizedBox(width: 8)],
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 18.5,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
                letterSpacing: -0.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (actionText != null && onActionTap != null)
            GestureDetector(
              onTap: onActionTap,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Text(
                  actionText!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtistSectionHeader extends StatelessWidget {
  const _ArtistSectionHeader({
    required this.artistName,
    this.artistImageUrl,
    this.onTap,
  });

  final String artistName;
  final String? artistImageUrl;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: colorScheme.surfaceContainerHighest,
              backgroundImage:
                  (artistImageUrl != null && artistImageUrl!.isNotEmpty)
                  ? ArtworkProvider.get(artistImageUrl!)
                  : null,
              child: (artistImageUrl == null || artistImageUrl!.isEmpty)
                  ? Icon(
                      FluentIcons.person_24_filled,
                      color: colorScheme.primary,
                      size: 22,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'More like',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    artistName,
                    style: TextStyle(
                      fontSize: 18.5,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              FluentIcons.chevron_right_24_regular,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _HorizontalContentCard extends StatelessWidget {
  const _HorizontalContentCard({
    required this.width,
    required this.imageUrl,
    this.typeLabel,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final double width;
  final String? imageUrl;
  final String? typeLabel;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Artwork (large, perfectly square, rounded corners, subtle shadow)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: width,
                height: width,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: (imageUrl != null && imageUrl!.isNotEmpty)
                    ? Image(
                        image: ArtworkProvider.get(imageUrl!),
                        width: width,
                        height: width,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => NullArtworkWidget(
                          icon: FluentIcons.music_note_2_24_filled,
                          size: width,
                          iconSize: 30,
                        ),
                      )
                    : NullArtworkWidget(
                        icon: FluentIcons.music_note_2_24_filled,
                        size: width,
                        iconSize: 30,
                      ),
              ),
            ),
            const SizedBox(height: 7),

            // Content Type Label (Album, Single, Compilation, Recent)
            if (typeLabel != null && typeLabel!.isNotEmpty) ...[
              Text(
                typeLabel!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
            ],

            // Title
            Text(
              title,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
                letterSpacing: -0.2,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),

            // Artist / Subtitle
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: colorScheme.onSurfaceVariant,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _HorizontalArtistCard extends StatefulWidget {
  const _HorizontalArtistCard({
    required this.width,
    required this.avatarSize,
    required this.name,
    required this.imageUrl,
    required this.onTap,
  });

  final double width;
  final double avatarSize;
  final String name;
  final String? imageUrl;
  final VoidCallback onTap;

  @override
  State<_HorizontalArtistCard> createState() => _HorizontalArtistCardState();
}

typedef _HomeArtistCard = _HorizontalArtistCard;

class _HorizontalArtistCardState extends State<_HorizontalArtistCard> {
  bool _isPressed = false;
  bool _isHovered = false;
  String? _effectiveImageUrl;
  bool _isResolving = false;

  @override
  void initState() {
    super.initState();
    _effectiveImageUrl = (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
        ? widget.imageUrl
        : ArtistImageResolver.instance.getCachedImage(widget.name);

    if (_effectiveImageUrl == null || _effectiveImageUrl!.isEmpty) {
      _resolveImageAsync();
    }
  }

  @override
  void didUpdateWidget(covariant _HorizontalArtistCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageUrl != oldWidget.imageUrl || widget.name != oldWidget.name) {
      _effectiveImageUrl = (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
          ? widget.imageUrl
          : ArtistImageResolver.instance.getCachedImage(widget.name);
      if (_effectiveImageUrl == null || _effectiveImageUrl!.isEmpty) {
        _resolveImageAsync();
      }
    }
  }

  Future<void> _resolveImageAsync() async {
    if (_isResolving) return;
    _isResolving = true;
    try {
      final img =
          await ArtistImageResolver.instance.resolveArtistImage(widget.name);
      if (mounted && img != null && img.isNotEmpty) {
        setState(() {
          _effectiveImageUrl = img;
        });
      }
    } finally {
      _isResolving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isHighlighted = _isPressed || _isHovered;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _isPressed ? 0.94 : (_isHovered ? 1.03 : 1.0),
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeInOut,
          child: SizedBox(
            width: widget.width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Circular Artwork (perfectly round, subtle border ring)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: widget.avatarSize,
                  height: widget.avatarSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isHighlighted
                          ? colorScheme.primary
                          : colorScheme.outlineVariant.withValues(alpha: 0.35),
                      width: isHighlighted ? 2.0 : 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isHighlighted ? 0.14 : 0.07),
                        blurRadius: isHighlighted ? 10 : 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: (_effectiveImageUrl != null &&
                            ArtistImageResolver.isValidArtistImageUrl(_effectiveImageUrl))
                        ? CachedNetworkImage(
                            imageUrl: _effectiveImageUrl!,
                            fit: BoxFit.cover,
                            width: widget.avatarSize,
                            height: widget.avatarSize,
                            placeholder: (_, __) => _buildFallback(colorScheme),
                            errorWidget: (_, __, ___) => _buildFallback(colorScheme),
                          )
                        : _buildFallback(colorScheme),
                  ),
                ),
                const SizedBox(height: 8),
                // Centered artist name (max 2 lines, ellipsis)
                Text(
                  widget.name,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                    letterSpacing: -0.2,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFallback(ColorScheme colorScheme) {
    return DedicatedArtistPlaceholder(
      name: widget.name,
      size: widget.avatarSize,
    );
  }
}
