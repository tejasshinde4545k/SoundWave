import 'package:flutter/material.dart';
import 'package:soundwave/services/music_source.dart';

class MusicSourceSelector extends StatelessWidget {
  const MusicSourceSelector({required this.onSelected, super.key});

  final Future<void> Function(MusicSource source) onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder<MusicSource>(
        valueListenable: selectedMusicSource,
        builder: (context, selected, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: MusicSource.values.map((source) {
              final isSelected = source == selected;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Material(
                  color: isSelected
                      ? colorScheme.primaryContainer
                      : colorScheme.surfaceContainerHighest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => onSelected(source),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSelected) ...[
                            Icon(
                              Icons.check,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            source.label,
                            style: TextStyle(
                              color: isSelected
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurface,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
