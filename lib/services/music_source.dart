import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:soundwave/services/data_manager.dart';

enum MusicSource { youtube, jioSaavn, railway, jamendo }

typedef MusicProviderType = MusicSource;

extension MusicSourceLabel on MusicSource {
  String get label => switch (this) {
        MusicSource.youtube => 'YouTube',
        MusicSource.jioSaavn => 'JioSaavn',
        MusicSource.railway => 'Railway Music',
        MusicSource.jamendo => 'Jamendo Open Music',
      };

  String get storageValue => name;
}

MusicSource _readMusicSource() {
  final value = Hive.box('settings').get('music_source', defaultValue: 'youtube');
  return MusicSource.values.firstWhere(
    (source) => source.storageValue == value,
    orElse: () => MusicSource.youtube,
  );
}

final selectedMusicSource = ValueNotifier<MusicSource>(_readMusicSource());

Future<void> setMusicSource(MusicSource source) async {
  selectedMusicSource.value = source;
  await addOrUpdateData<String>('settings', 'music_source', source.storageValue);
}
