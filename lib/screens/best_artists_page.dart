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
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:soundwave/services/artist_image_resolver.dart';
import 'package:soundwave/services/best_artists_service.dart';
import 'package:soundwave/services/router_service.dart';
import 'package:soundwave/widgets/mini_player_bottom_space.dart';
import 'package:soundwave/widgets/spinner.dart';

class BestArtistsPage extends StatefulWidget {
  const BestArtistsPage({
    super.key,
    this.initialArtists,
  });

  final List<Map<String, dynamic>>? initialArtists;

  @override
  State<BestArtistsPage> createState() => _BestArtistsPageState();
}

class _BestArtistsPageState extends State<BestArtistsPage> {
  late Future<List<Map<String, dynamic>>> _artistsFuture;

  @override
  void initState() {
    super.initState();
    if (widget.initialArtists != null && widget.initialArtists!.isNotEmpty) {
      _artistsFuture = Future.value(widget.initialArtists);
    } else {
      _artistsFuture = BestArtistsService.instance.getBestArtists(limit: 30);
    }
  }

  void _onArtistTap(Map<String, dynamic> artist) {
    final artistName = artist['title']?.toString().trim() ?? '';
    if (artistName.isEmpty) return;
    context.push(
      NavigationManager.artistPath(context, artistName),
      extra: artist,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Best Artists',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _artistsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: Spinner());
          }

          final artists = snapshot.data ?? [];

          if (artists.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.people_24_regular,
                      size: 56,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No Artists Available',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 120,
                    mainAxisSpacing: 20,
                    crossAxisSpacing: 16,
                    mainAxisExtent: 140,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final artist = artists[index];
                      final name = artist['title']?.toString() ?? '';
                      final imageUrl = artist['image']?.toString();

                      return _GridArtistCard(
                        name: name,
                        imageUrl: imageUrl,
                        onTap: () => _onArtistTap(artist),
                      );
                    },
                    childCount: artists.length,
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: MiniPlayerBottomSpace(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GridArtistCard extends StatelessWidget {
  const _GridArtistCard({
    required this.name,
    required this.imageUrl,
    required this.onTap,
  });

  final String name;
  final String? imageUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Circular Artwork (perfectly round, subtle border)
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  width: 1.5,
                ),
              ),
              child: ClipOval(
                child: (imageUrl != null &&
                        ArtistImageResolver.isValidArtistImageUrl(imageUrl))
                    ? CachedNetworkImage(
                        imageUrl: imageUrl!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _buildFallback(colorScheme),
                        errorWidget: (_, __, ___) => _buildFallback(colorScheme),
                      )
                    : _buildFallback(colorScheme),
              ),
            ),
            const SizedBox(height: 8),
            // Centered artist name (max 2 lines)
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
                height: 1.2,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallback(ColorScheme colorScheme) {
    return DedicatedArtistPlaceholder(
      name: name,
    );
  }
}
