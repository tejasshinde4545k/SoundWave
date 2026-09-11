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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:soundwave/main.dart' show audioHandler;
import 'package:soundwave/services/release_metadata_service.dart';
import 'package:soundwave/widgets/mini_player_bottom_space.dart';
import 'package:soundwave/widgets/song_bar.dart';
import 'package:soundwave/widgets/spinner.dart';

class ReleasedThisWeekPage extends StatefulWidget {
  const ReleasedThisWeekPage({
    super.key,
    this.initialSongs,
    this.weekRangeText,
  });

  final List<dynamic>? initialSongs;
  final String? weekRangeText;

  @override
  State<ReleasedThisWeekPage> createState() => _ReleasedThisWeekPageState();
}

class _ReleasedThisWeekPageState extends State<ReleasedThisWeekPage> {
  late Future<List<Map<String, dynamic>>> _songsFuture;
  late final String _weekRangeLabel;

  @override
  void initState() {
    super.initState();
    final weekRange = ReleaseMetadataService.instance.getCurrentWeekRange();
    _weekRangeLabel = widget.weekRangeText ?? weekRange.formattedRange;

    if (widget.initialSongs != null && widget.initialSongs!.isNotEmpty) {
      _songsFuture = Future.value(
        widget.initialSongs!.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
      );
    } else {
      _songsFuture = ReleaseMetadataService.instance.getReleasesThisWeek();
    }
  }

  void _playAll(List<Map<String, dynamic>> songs) {
    if (songs.isEmpty) return;
    audioHandler.playPlaylistSong(
      playlist: {
        'title': 'Released This Week ($_weekRangeLabel)',
        'list': songs,
      },
      songIndex: 0,
    );
  }

  void _shufflePlay(List<Map<String, dynamic>> songs) {
    if (songs.isEmpty) return;
    final shuffled = List<Map<String, dynamic>>.from(songs)..shuffle();
    audioHandler.playPlaylistSong(
      playlist: {
        'title': 'Released This Week ($_weekRangeLabel)',
        'list': shuffled,
      },
      songIndex: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Released This Week',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _songsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: Spinner());
          }

          final songs = snapshot.data ?? [];

          if (songs.isEmpty) {
            return _buildEmptyState(context, colorScheme);
          }

          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: colorScheme.primary.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              FluentIcons.calendar_ltr_24_filled,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _weekRangeLabel,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Verified releases from the current calendar week via MusicBrainz.',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _playAll(songs),
                              icon: const Icon(FluentIcons.play_24_filled, size: 18),
                              label: const Text('Play All'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _shufflePlay(songs),
                              icon: const Icon(FluentIcons.arrow_shuffle_24_regular, size: 18),
                              label: const Text('Shuffle'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = songs[index];
                    return SongBar(
                      song,
                      false,
                      onPlay: () {
                        audioHandler.playPlaylistSong(
                          playlist: {
                            'title': 'Released This Week ($_weekRangeLabel)',
                            'list': songs,
                          },
                          songIndex: index,
                        );
                      },
                    );
                  },
                  childCount: songs.length,
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

  Widget _buildEmptyState(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.sparkle_24_regular,
              size: 56,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No Verified Releases This Week',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'SoundWave verifies release metadata through MusicBrainz to ensure only genuine new music is featured.',
              style: TextStyle(
                fontSize: 13.5,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
