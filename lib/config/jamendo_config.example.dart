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

/// Jamendo public API configuration.
///
/// Replace [clientId] with your real Jamendo client_id from
/// https://developer.jamendo.com/
///
/// DO NOT add a client_secret here — the public catalog API does not require
/// one and secrets should never be embedded in client source code.
class JamendoConfig {
  JamendoConfig._();

  /// Your Jamendo API client_id.
  /// Replace 'YOUR_JAMENDO_CLIENT_ID' with your actual client ID.
  static const String clientId = 'YOUR_JAMENDO_CLIENT_ID';

  /// Jamendo REST API v3.0 base URL.
  static const String baseUrl = 'https://api.jamendo.com/v3.0';

  /// Prefix used for Jamendo song IDs stored in the ytid field.
  /// Example: ytid = 'jamendo:1234567'
  static const String idPrefix = 'jamendo:';
}
