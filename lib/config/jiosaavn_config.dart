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

import 'package:hive_flutter/hive_flutter.dart';

/// Configuration for the JioSaavn public API proxy (saavn.dev / jiosaavn-api).
///
/// The API is a self-hostable, open-source proxy:
///   https://github.com/sumitkolhe/jiosaavn-api
///
/// The public deployment at https://saavn.dev is community-maintained and
/// provided on a best-effort basis. If you self-host the API, override
/// [baseUrl] accordingly.
///
/// **No API key is required.**
class JioSaavnConfig {
  JioSaavnConfig._();

  static const String defaultBaseUrl = 'https://saavn.dev';
  static String? _customBaseUrl;

  /// Base URL of the jiosaavn-api deployment, WITHOUT a trailing slash.
  ///
  /// Checks programmatic override first, then Hive box('settings').get('jiosaavnApiUrl'),
  /// and falls back to [defaultBaseUrl].
  static String get baseUrl {
    if (_customBaseUrl != null && _customBaseUrl!.trim().isNotEmpty) {
      return _customBaseUrl!.trim().replaceAll(RegExp(r'/+$'), '');
    }
    try {
      if (Hive.isBoxOpen('settings')) {
        final saved = Hive.box('settings').get('jiosaavnApiUrl') as String?;
        if (saved != null && saved.trim().isNotEmpty) {
          return saved.trim().replaceAll(RegExp(r'/+$'), '');
        }
      }
    } catch (_) {}
    return defaultBaseUrl;
  }

  static set baseUrl(String? url) {
    _customBaseUrl = url;
  }

  /// Preferred audio quality when resolving download/stream URLs.
  /// Valid values (from the API): '12kbps', '48kbps', '96kbps', '160kbps', '320kbps'.
  static const String preferredQuality = '320kbps';
}
