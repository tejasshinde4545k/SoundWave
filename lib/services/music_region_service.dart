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

import 'dart:ui' as ui;

import 'package:soundwave/services/settings_manager.dart';

/// Represents a geographic or cultural music region.
class MusicRegion {
  const MusicRegion({
    required this.code,
    required this.displayName,
    this.nativeName,
  });

  final String code;
  final String displayName;
  final String? nativeName;
}

/// A specific language preference definition with scoring weight, search keywords,
/// and script detection patterns.
class LanguagePreference {
  const LanguagePreference({
    required this.code,
    required this.name,
    required this.weight,
    required this.sampleQueries,
    required this.keywords,
    this.scriptPattern,
  });

  final String code;
  final String name;
  final double weight;
  final List<String> sampleQueries;
  final List<String> keywords;
  final RegExp? scriptPattern;

  bool matches(String text) {
    final lower = text.toLowerCase();
    for (final kw in keywords) {
      if (lower.contains(kw)) return true;
    }
    if (scriptPattern != null && scriptPattern!.hasMatch(text)) {
      return true;
    }
    return false;
  }
}

/// Summarizes the user's historical listening profile based on liked songs,
/// recently played tracks, and custom playlists.
class UserMusicProfile {
  const UserMusicProfile({
    required this.isColdStart,
    required this.totalSampledSongs,
    required this.topArtists,
    required this.languageAffinities,
    required this.isEnglishHeavy,
    required this.isKPopHeavy,
    required this.isIndianHeavy,
  });

  final bool isColdStart;
  final int totalSampledSongs;
  final Set<String> topArtists;

  /// Normalized affinities (0.0 to 1.0) for each language code.
  final Map<String, double> languageAffinities;
  final bool isEnglishHeavy;
  final bool isKPopHeavy;
  final bool isIndianHeavy;

  bool hasArtist(String artist) {
    final lower = artist.toLowerCase().trim();
    if (lower.isEmpty) return false;
    for (final a in topArtists) {
      if (a.contains(lower) || lower.contains(a)) return true;
    }
    return false;
  }

  double getAffinityForLanguage(String langCode) {
    return languageAffinities[langCode] ?? 0.0;
  }
}

/// Service that manages location/region detection, language hierarchy,
/// user listening profile analysis, and regional recommendation scoring signals.
///
/// **Privacy First**: No GPS or fine location permissions are ever requested.
/// Region is resolved strictly from:
///   1. User's manual setting (`musicRegionSetting`)
///   2. Device locale countryCode (`PlatformDispatcher.instance.locale.countryCode`)
///   3. Language setting fallback
///   4. `'GLOBAL'`
class MusicRegionService {
  MusicRegionService._();

  static final MusicRegionService instance = MusicRegionService._();

  /// Supported regions available for selection in Settings.
  static const List<MusicRegion> supportedRegions = [
    MusicRegion(code: 'auto', displayName: 'Automatic'),
    MusicRegion(code: 'IN', displayName: 'India', nativeName: 'भारत'),
    MusicRegion(code: 'US', displayName: 'United States'),
    MusicRegion(code: 'GB', displayName: 'United Kingdom'),
    MusicRegion(code: 'CA', displayName: 'Canada'),
    MusicRegion(code: 'AU', displayName: 'Australia'),
    MusicRegion(code: 'JP', displayName: 'Japan', nativeName: '日本'),
    MusicRegion(code: 'KR', displayName: 'South Korea', nativeName: '대한민국'),
    MusicRegion(code: 'BR', displayName: 'Brazil', nativeName: 'Brasil'),
    MusicRegion(code: 'MX', displayName: 'Mexico', nativeName: 'México'),
    MusicRegion(code: 'DE', displayName: 'Germany', nativeName: 'Deutschland'),
    MusicRegion(code: 'FR', displayName: 'France'),
    MusicRegion(code: 'ES', displayName: 'Spain', nativeName: 'España'),
    MusicRegion(code: 'IT', displayName: 'Italy', nativeName: 'Italia'),
    MusicRegion(code: 'GLOBAL', displayName: 'Global'),
  ];

  // ── Indian Language Hierarchy ───────────────────────────────────────────────
  // Specific weights as requested:
  // Hindi: 1.00, Punjabi: 0.85, Marathi: 0.75, Tamil: 0.70, Telugu: 0.65,
  // Bengali: 0.60, Kannada: 0.55, Malayalam: 0.50, Gujarati: 0.45
  static final List<LanguagePreference> indianLanguages = [
    LanguagePreference(
      code: 'hi',
      name: 'Hindi',
      weight: 1,
      sampleQueries: const [
        'latest Hindi songs',
        'Bollywood hits',
        'Hindi romantic songs',
        'trending Hindi songs',
      ],
      keywords: const [
        'hindi',
        'bollywood',
        'arijit',
        'pritam',
        'shreya',
        'sonu nigam',
        'badshah',
        'neha kakkar',
        'jubin nautiyal',
        'vishal-shekhar',
        'amit trivedi',
        'armaan malik',
        'sachet-parampara',
        'kumar sanu',
        'alka yagnik',
        'atif aslam',
        'kk',
        'mohit chauhan',
        'udit narayan',
        'anuv jain',
      ],
      scriptPattern: RegExp(r'[\u0900-\u097F]'),
    ),
    LanguagePreference(
      code: 'pa',
      name: 'Punjabi',
      weight: 0.85,
      sampleQueries: const [
        'latest Punjabi songs',
        'Punjabi hits',
        'trending Punjabi music',
      ],
      keywords: const [
        'punjabi',
        'sidhu',
        'ap dhillon',
        'diljit',
        'karan aujla',
        'shubh',
        'ammy virk',
        'b praak',
        'harrdy sandhu',
        'guru randhawa',
        'jassi gill',
        'moosewala',
      ],
      scriptPattern: RegExp(r'[\u0A00-\u0A7F]'),
    ),
    const LanguagePreference(
      code: 'mr',
      name: 'Marathi',
      weight: 0.75,
      sampleQueries: [
        'latest Marathi songs',
        'Marathi hits',
        'Marathi romantic songs',
      ],
      keywords: [
        'marathi',
        'ajay atul',
        'avdhoot gupte',
        'swapnil bandodkar',
        'marathi gaani',
        'marathi song',
        'adwait patwardhan',
      ],
    ),
    LanguagePreference(
      code: 'ta',
      name: 'Tamil',
      weight: 0.70,
      sampleQueries: const [
        'latest Tamil songs',
        'Tamil hits',
        'Kollywood hits',
      ],
      keywords: const [
        'tamil',
        'kollywood',
        'anirudh',
        'ar rahman',
        'yuvan',
        'harris jayaraj',
        'sid sriram',
        'ilayaraja',
        'vijay antony',
        'santhosh narayanan',
      ],
      scriptPattern: RegExp(r'[\u0B80-\u0BFF]'),
    ),
    LanguagePreference(
      code: 'te',
      name: 'Telugu',
      weight: 0.65,
      sampleQueries: const [
        'latest Telugu songs',
        'Telugu hits',
        'Tollywood hits',
      ],
      keywords: const [
        'telugu',
        'tollywood',
        'devi sri prasad',
        'dsp',
        'thaman',
        'sid sriram',
        'ram miriyala',
        'keeravani',
        'anurag kulkarni',
      ],
      scriptPattern: RegExp(r'[\u0C00-\u0C7F]'),
    ),
    LanguagePreference(
      code: 'bn',
      name: 'Bengali',
      weight: 0.60,
      sampleQueries: const [
        'latest Bengali songs',
        'Bangla hits',
      ],
      keywords: const [
        'bengali',
        'bangla',
        'anupam roy',
        'arijit singh bangla',
        'shreya ghoshal bangla',
        'rabindra sangeet',
        'somlata',
      ],
      scriptPattern: RegExp(r'[\u0980-\u09FF]'),
    ),
    LanguagePreference(
      code: 'kn',
      name: 'Kannada',
      weight: 0.55,
      sampleQueries: const [
        'latest Kannada songs',
        'Kannada hits',
      ],
      keywords: const [
        'kannada',
        'sanjith hegde',
        'arjun janya',
        'chandan shetty',
        'ravi basrur',
        'charan raj',
      ],
      scriptPattern: RegExp(r'[\u0C80-\u0CFF]'),
    ),
    LanguagePreference(
      code: 'ml',
      name: 'Malayalam',
      weight: 0.50,
      sampleQueries: const [
        'latest Malayalam songs',
        'Malayalam hits',
      ],
      keywords: const [
        'malayalam',
        'sushin shyam',
        'shaan rahman',
        'ks chithra',
        'heshem abdul wahab',
        'jakes bejoy',
      ],
      scriptPattern: RegExp(r'[\u0D00-\u0D7F]'),
    ),
    LanguagePreference(
      code: 'gu',
      name: 'Gujarati',
      weight: 0.45,
      sampleQueries: const [
        'latest Gujarati songs',
        'Gujarati geet',
      ],
      keywords: const [
        'gujarati',
        'kinjal dave',
        'geeta rabari',
        'jignesh kaviraj',
        'kirtidan gadhvi',
        'osman mir',
      ],
      scriptPattern: RegExp(r'[\u0A80-\u0AFF]'),
    ),
  ];

  static const List<String> indianGeneralKeywords = [
    'desi',
    'indian',
    't-series',
    'zee music',
    'speed records',
    'sony music india',
    'yrf',
    'tips official',
    'saregama',
  ];

  // ── International Genre / Language Patterns ────────────────────────────────
  static const List<String> kpopKeywords = [
    'k-pop',
    'kpop',
    'bts',
    'blackpink',
    'twice',
    'stray kids',
    'newjeans',
    'ive',
    'aespa',
    'exo',
    'txt',
    'seventeen',
    'iu',
    'enhypen',
    'le sserafim',
    'ateez',
  ];
  static final RegExp kpopHangulRegex = RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]');

  static const List<String> jpopKeywords = [
    'j-pop',
    'jpop',
    'anime',
    'japanese',
    'yoasobi',
    'kenshi yonezu',
    'lisa',
    'ado',
    'official hige dandism',
    'radwimps',
    'aimer',
  ];
  static final RegExp jpopScriptRegex = RegExp(r'[\u3040-\u30FF]');

  static const List<String> westernEnglishKeywords = [
    'taylor swift',
    'drake',
    'the weeknd',
    'ed sheeran',
    'billie eilish',
    'ariana grande',
    'dua lipa',
    'post malone',
    'eminem',
    'justin bieber',
    'coldplay',
    'bruno mars',
    'sabrina carpenter',
    'chappell roan',
    'kendrick lamar',
    'travis scott',
    'olivia rodrigo',
    'harry styles',
    'beyonce',
    'rihanna',
    'maroon 5',
    'imagine dragons',
  ];

  // ── Region Resolution ──────────────────────────────────────────────────────

  /// Resolves the effective country code in uppercase without requesting GPS.
  ///
  /// Optional parameters allow overriding values for deterministic unit testing.
  String getActiveRegionCode({
    String? manualSetting,
    String? deviceLocaleCountry,
    ui.Locale? languageLocale,
  }) {
    var manual = manualSetting?.trim() ?? '';
    if (manual.isEmpty) {
      try {
        manual = musicRegionSetting.value.trim();
      } catch (_) {}
    }

    if (manual.isNotEmpty && manual.toLowerCase() != 'auto') {
      return manual.toUpperCase();
    }

    final deviceCountry = (deviceLocaleCountry ??
            ui.PlatformDispatcher.instance.locale.countryCode)
        ?.trim();
    if (deviceCountry != null && deviceCountry.isNotEmpty) {
      return deviceCountry.toUpperCase();
    }

    try {
      final loc = languageLocale ?? languageSetting;
      final langCountry = loc.countryCode?.trim();
      if (langCountry != null && langCountry.isNotEmpty) {
        return langCountry.toUpperCase();
      }

      final langCode = loc.languageCode.toLowerCase().trim();
      if (langCode == 'hi' ||
          langCode == 'ta' ||
          langCode == 'te' ||
          langCode == 'mr' ||
          langCode == 'bn') {
        return 'IN';
      }
      if (langCode == 'ja') return 'JP';
      if (langCode == 'ko') return 'KR';
    } catch (_) {}

    return 'GLOBAL';
  }

  /// Returns the human-readable display name for a region code.
  String getRegionDisplayName(String code) {
    final match = supportedRegions.firstWhere(
      (r) => r.code.toUpperCase() == code.toUpperCase(),
      orElse: () => MusicRegion(code: code, displayName: code),
    );
    if (match.nativeName != null && match.nativeName!.isNotEmpty) {
      return '${match.displayName} (${match.nativeName})';
    }
    return match.displayName;
  }

  // ── Profile Analysis ───────────────────────────────────────────────────────

  /// Analyzes the user's existing history ([recentlyPlayed] and [likedSongs])
  /// to quantify their personal music preferences across languages and regions.
  UserMusicProfile analyzeUserProfile({
    List<dynamic>? recentlyPlayed,
    List<dynamic>? likedSongs,
  }) {
    final allSongs = <Map>[];
    if (recentlyPlayed != null) {
      for (final s in recentlyPlayed) {
        if (s is Map) allSongs.add(s);
      }
    }
    if (likedSongs != null) {
      for (final s in likedSongs) {
        if (s is Map) allSongs.add(s);
      }
    }

    if (allSongs.isEmpty) {
      return const UserMusicProfile(
        isColdStart: true,
        totalSampledSongs: 0,
        topArtists: {},
        languageAffinities: {},
        isEnglishHeavy: false,
        isKPopHeavy: false,
        isIndianHeavy: false,
      );
    }

    final topArtists = <String>{};
    var englishCount = 0;
    var kpopCount = 0;
    var jpopCount = 0;
    var indianTotalCount = 0;
    final regionalCounts = <String, int>{};

    for (final song in allSongs) {
      final title = song['title']?.toString() ?? '';
      final artist = song['artist']?.toString() ?? '';
      final fullText = '$title $artist'.toLowerCase();

      if (artist.trim().isNotEmpty) {
        topArtists.add(artist.trim().toLowerCase());
      }

      // Check K-Pop
      if (_matchesKPop(fullText)) {
        kpopCount++;
      }

      // Check J-Pop
      if (_matchesJPop(fullText)) {
        jpopCount++;
      }

      // Check Indian languages
      var matchedIndian = false;
      for (final pref in indianLanguages) {
        if (pref.matches(fullText)) {
          regionalCounts[pref.code] = (regionalCounts[pref.code] ?? 0) + 1;
          matchedIndian = true;
        }
      }
      if (!matchedIndian) {
        for (final kw in indianGeneralKeywords) {
          if (fullText.contains(kw)) {
            matchedIndian = true;
            break;
          }
        }
      }
      if (matchedIndian) {
        indianTotalCount++;
      }

      // Check Western / English
      if (_matchesEnglish(fullText) || (!matchedIndian && kpopCount == 0 && jpopCount == 0)) {
        englishCount++;
      }
    }

    final total = allSongs.length;
    final affinities = <String, double>{};
    affinities['en'] = (englishCount / total).clamp(0.0, 1.0);
    affinities['ko'] = (kpopCount / total).clamp(0.0, 1.0);
    affinities['ja'] = (jpopCount / total).clamp(0.0, 1.0);
    affinities['in'] = (indianTotalCount / total).clamp(0.0, 1.0);

    for (final pref in indianLanguages) {
      final count = regionalCounts[pref.code] ?? 0;
      affinities[pref.code] = (count / total).clamp(0.0, 1.0);
    }

    return UserMusicProfile(
      isColdStart: false,
      totalSampledSongs: total,
      topArtists: topArtists,
      languageAffinities: affinities,
      isEnglishHeavy: (englishCount / total) >= 0.55,
      isKPopHeavy: (kpopCount / total) >= 0.40,
      isIndianHeavy: (indianTotalCount / total) >= 0.40,
    );
  }

  // ── Candidate Classification & Regional Scoring ───────────────────────────

  /// Detects candidate song language or cultural family.
  String detectCandidateLanguage(Map<String, dynamic> song) {
    final title = song['title']?.toString() ?? '';
    final artist = song['artist']?.toString() ?? '';
    final fullText = '$title $artist'.toLowerCase();

    // Check K-Pop
    if (_matchesKPop(fullText)) return 'ko';

    // Check J-Pop
    if (_matchesJPop(fullText)) return 'ja';

    // Check Indian Languages in priority order
    for (final pref in indianLanguages) {
      if (pref.matches(fullText)) {
        return pref.code;
      }
    }

    for (final kw in indianGeneralKeywords) {
      if (fullText.contains(kw)) return 'in_general';
    }

    // Default to English / International
    return 'en';
  }

  /// Calculates the regional recommendation bonus for a given [song].
  ///
  /// For India (`IN`):
  ///   - If cold-start: Hindi receives the strongest default weight (1.00),
  ///     followed by Punjabi (0.85), Marathi (0.75), etc.
  ///   - If user has history:
  ///     - English / K-Pop preferences are preserved by giving strong personal
  ///       affinity bonuses elsewhere while applying a gentle regional bonus here.
  ///     - Hindi / regional preferences are strongly amplified.
  /// For other regions (e.g. `US`, `GB`):
  ///   - India-specific Hindi bonuses are NOT applied.
  double calculateRegionalBonus({
    required Map<String, dynamic> song,
    required String regionCode,
    required UserMusicProfile userProfile,
  }) {
    final region = regionCode.toUpperCase();
    final lang = detectCandidateLanguage(song);

    if (region == 'IN') {
      // Find matching language preference weight
      final pref = indianLanguages.cast<LanguagePreference?>().firstWhere(
            (p) => p?.code == lang,
            orElse: () => null,
          );

      final baseWeight = pref?.weight ?? (lang == 'in_general' ? 0.40 : 0);

      if (baseWeight == 0) {
        return 0;
      }

      if (userProfile.isColdStart) {
        // Cold start in India: Hindi receives strongest default (35.0 pts),
        // other regional languages scaled by their weights.
        return 35.0 * baseWeight;
      }

      if (userProfile.isEnglishHeavy || userProfile.isKPopHeavy) {
        // User heavily prefers English / K-Pop:
        // Give a moderate regional signal (15 pts * weight) so Indian hits
        // are blended in, but cannot overwhelm their personal preferences.
        return 16.0 * baseWeight;
      }

      if (userProfile.isIndianHeavy) {
        // User already listens to Indian music:
        // If they specifically listen to this sub-language, amplify it!
        final specificAffinity = userProfile.getAffinityForLanguage(lang);
        if (specificAffinity > 0.2) {
          return 38.0 * baseWeight * (1.0 + specificAffinity);
        }
        return 30.0 * baseWeight;
      }

      // Balanced user
      return 25.0 * baseWeight;
    }

    if (region == 'US' || region == 'GB' || region == 'CA' || region == 'AU') {
      if (lang == 'en') return 15;
      return 0;
    }

    if (region == 'JP') {
      if (lang == 'ja') return 30;
      return 0;
    }

    if (region == 'KR') {
      if (lang == 'ko') return 30;
      return 0;
    }

    return 0;
  }

  /// Generates adaptive YouTube search queries combining the user's personal
  /// artist / genre preferences with regional signals.
  List<String> generateSearchQueries({
    required String regionCode,
    required UserMusicProfile userProfile,
  }) {
    final queries = <String>[];
    final region = regionCode.toUpperCase();

    // 1. Personalized queries from user top artists
    if (userProfile.topArtists.isNotEmpty) {
      final topArtistsList = userProfile.topArtists.take(3).toList();
      for (final artist in topArtistsList) {
        if (region == 'IN' && !userProfile.isEnglishHeavy && !userProfile.isKPopHeavy) {
          queries.add('$artist Hindi songs');
        } else {
          queries.add('$artist songs');
        }
      }
    }

    // 2. Regional Discovery queries
    if (region == 'IN') {
      if (userProfile.isColdStart) {
        // Default cold start: Hindi primary + top regional hits
        queries.addAll(const [
          'latest Hindi songs',
          'Bollywood romantic hits',
          'latest Punjabi songs',
          'trending Indian music',
        ]);
      } else if (userProfile.isEnglishHeavy) {
        queries.addAll(const [
          'trending songs',
          'Bollywood acoustic hits',
        ]);
      } else if (userProfile.isKPopHeavy) {
        queries.addAll(const [
          'trending K-Pop hits',
          'latest Hindi songs',
        ]);
      } else {
        // Check which regional language user listens to
        var addedSpecific = false;
        for (final lang in indianLanguages) {
          if (userProfile.getAffinityForLanguage(lang.code) > 0.15) {
            queries.addAll(lang.sampleQueries.take(2));
            addedSpecific = true;
            break;
          }
        }
        if (!addedSpecific) {
          queries.addAll(const [
            'latest Hindi songs',
            'Bollywood hits',
          ]);
        }
      }
    } else if (region == 'JP') {
      queries.addAll(const [
        'latest J-Pop songs',
        'trending Anime songs',
      ]);
    } else if (region == 'KR') {
      queries.addAll(const [
        'latest K-Pop songs',
        'trending K-Drama OST',
      ]);
    } else if (region == 'US' || region == 'GB' || region == 'CA' || region == 'AU') {
      queries.addAll(const [
        'today top hits',
        'trending music',
      ]);
    } else {
      queries.addAll(const [
        'popular songs',
        'top global hits',
      ]);
    }

    return queries.take(5).toList();
  }

  // ── Helper Matching ────────────────────────────────────────────────────────

  bool _matchesKPop(String text) {
    if (kpopHangulRegex.hasMatch(text)) return true;
    for (final kw in kpopKeywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }

  bool _matchesJPop(String text) {
    if (jpopScriptRegex.hasMatch(text)) return true;
    for (final kw in jpopKeywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }

  bool _matchesEnglish(String text) {
    for (final kw in westernEnglishKeywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }
}
