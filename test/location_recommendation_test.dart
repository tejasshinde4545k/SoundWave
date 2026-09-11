import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/services/music_region_service.dart';
import 'package:soundwave/services/recommendation_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Location-Based Music Recommendation Tests', () {
    final hindiSong = {
      'ytid': 'hindi_01',
      'title': 'Kesariya - Official Lyric Video',
      'artist': 'Arijit Singh, Pritam',
      '_rec_score': 50.0,
    };

    final punjabiSong = {
      'ytid': 'punjabi_01',
      'title': 'Softly - Official Music Video',
      'artist': 'Karan Aujla, Ikky',
      '_rec_score': 50.0,
    };

    final englishSong = {
      'ytid': 'english_01',
      'title': 'Blinding Lights - Official Music Video',
      'artist': 'The Weeknd',
      '_rec_score': 50.0,
    };

    final kpopSong = {
      'ytid': 'kpop_01',
      'title': 'Dynamite - Official Music Video',
      'artist': 'BTS',
      '_rec_score': 50.0,
    };

    // Test 1: IN + no listening history → Hindi/Indian music receives higher priority
    test('1. IN + no listening history -> Hindi/Indian music receives higher priority', () {
      final coldProfile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: [],
        likedSongs: [],
      );

      expect(coldProfile.isColdStart, isTrue);

      final candidates = [
        Map<String, dynamic>.from(englishSong),
        Map<String, dynamic>.from(hindiSong),
        Map<String, dynamic>.from(punjabiSong),
      ];

      final ranked = RecommendationEngine.instance.rankCandidates(
        candidates,
        regionCode: 'IN',
        userProfile: coldProfile,
      );

      expect(ranked.isNotEmpty, isTrue);
      // Hindi has weight 1.00 (+35 pts), Punjabi has weight 0.85 (+29.75 pts), English (+0 pts)
      expect(ranked.first['ytid'], equals('hindi_01'));
      expect(ranked[1]['ytid'], equals('punjabi_01'));
      expect(ranked.last['ytid'], equals('english_01'));
    });

    // Test 2: IN + Hindi-heavy history → Hindi recommendations strongly prioritized
    test('2. IN + Hindi-heavy history -> Hindi recommendations strongly prioritized', () {
      final hindiHistory = [
        {'ytid': 'h1', 'title': 'Tum Hi Ho', 'artist': 'Arijit Singh'},
        {'ytid': 'h2', 'title': 'Channa Mereya', 'artist': 'Pritam'},
        {'ytid': 'h3', 'title': 'Raataan Lambiyan', 'artist': 'Jubin Nautiyal'},
        {'ytid': 'h4', 'title': 'Apna Bana Le', 'artist': 'Arijit Singh'},
      ];

      final profile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: hindiHistory,
        likedSongs: hindiHistory,
      );

      expect(profile.isIndianHeavy, isTrue);
      expect(profile.isColdStart, isFalse);

      final candidates = [
        Map<String, dynamic>.from(englishSong),
        Map<String, dynamic>.from(hindiSong),
      ];

      final ranked = RecommendationEngine.instance.rankCandidates(
        candidates,
        regionCode: 'IN',
        userProfile: profile,
      );

      expect(ranked.first['ytid'], equals('hindi_01'));
    });

    // Test 3: IN + English-heavy history → English remains strongly represented
    test('3. IN + English-heavy history -> English remains strongly represented', () {
      final englishHistory = [
        {'ytid': 'e1', 'title': 'Save Your Tears', 'artist': 'The Weeknd'},
        {'ytid': 'e2', 'title': 'Shape of You', 'artist': 'Ed Sheeran'},
        {'ytid': 'e3', 'title': 'Cruel Summer', 'artist': 'Taylor Swift'},
        {'ytid': 'e4', 'title': 'As It Was', 'artist': 'Harry Styles'},
        {'ytid': 'e5', 'title': 'Levitating', 'artist': 'Dua Lipa'},
      ];

      final profile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: englishHistory,
        likedSongs: englishHistory,
      );

      expect(profile.isEnglishHeavy, isTrue);

      final candidates = [
        Map<String, dynamic>.from(englishSong),
        Map<String, dynamic>.from(hindiSong),
      ];

      final ranked = RecommendationEngine.instance.rankCandidates(
        candidates,
        regionCode: 'IN',
        userProfile: profile,
      );

      // Personal affinity for English & artist (The Weeknd) keeps English represented at the top
      expect(ranked.first['ytid'], equals('english_01'));
    });

    // Test 4: IN + K-Pop-heavy history → K-Pop remains represented
    test('4. IN + K-Pop-heavy history -> K-Pop remains represented', () {
      final kpopHistory = [
        {'ytid': 'k1', 'title': 'Butter', 'artist': 'BTS'},
        {'ytid': 'k2', 'title': 'Pink Venom', 'artist': 'BLACKPINK'},
        {'ytid': 'k3', 'title': 'Hype Boy', 'artist': 'NewJeans'},
        {'ytid': 'k4', 'title': 'Super Shy', 'artist': 'NewJeans'},
      ];

      final profile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: kpopHistory,
        likedSongs: kpopHistory,
      );

      expect(profile.isKPopHeavy, isTrue);

      final candidates = [
        Map<String, dynamic>.from(kpopSong),
        Map<String, dynamic>.from(hindiSong),
      ];

      final ranked = RecommendationEngine.instance.rankCandidates(
        candidates,
        regionCode: 'IN',
        userProfile: profile,
      );

      // Personal affinity for K-Pop (BTS) keeps K-Pop represented at the top
      expect(ranked.first['ytid'], equals('kpop_01'));
    });

    // Test 5: US → India-specific regional bonus is NOT applied
    test('5. US -> India-specific regional bonus is NOT applied', () {
      final coldProfile = MusicRegionService.instance.analyzeUserProfile(
        recentlyPlayed: [],
        likedSongs: [],
      );

      final hindiBonusUS = MusicRegionService.instance.calculateRegionalBonus(
        song: hindiSong,
        regionCode: 'US',
        userProfile: coldProfile,
      );

      final hindiBonusIN = MusicRegionService.instance.calculateRegionalBonus(
        song: hindiSong,
        regionCode: 'IN',
        userProfile: coldProfile,
      );

      expect(hindiBonusUS, equals(0.0));
      expect(hindiBonusIN, greaterThan(0.0));
    });

    // Test 6: Manual region = India + device locale = US → India setting wins
    test('6. Manual region = India + device locale = US -> India setting wins', () {
      final resolved = MusicRegionService.instance.getActiveRegionCode(
        manualSetting: 'IN',
        deviceLocaleCountry: 'US',
      );

      expect(resolved, equals('IN'));
    });

    // Test 7: Manual region = auto + device locale = IN → India is detected
    test('7. Manual region = auto + device locale = IN -> India is detected', () {
      final resolved = MusicRegionService.instance.getActiveRegionCode(
        manualSetting: 'auto',
        deviceLocaleCountry: 'IN',
      );

      expect(resolved, equals('IN'));
    });

    // Test 8: Unknown locale → GLOBAL fallback
    test('8. Unknown locale -> GLOBAL fallback', () {
      final resolved = MusicRegionService.instance.getActiveRegionCode(
        manualSetting: 'auto',
        deviceLocaleCountry: '',
      );

      expect(resolved, equals('GLOBAL'));
    });

    // Test 9: Non-song candidate → rejected
    test('9. Non-song candidate -> rejected', () {
      const nonSongs = [
        'Latent Season 2 Bonus Episode',
        'Joe Rogan Experience Podcast #2100',
        'Tech Review: iPhone 16 Pro Max',
        'My Daily Morning Routine Vlog 2026',
        'GTA VI Official Trailer 2',
        'Elden Ring Gameplay Walkthrough Part 1',
        'Reacting to Best Moments of the Year | Reaction',
      ];

      for (final title in nonSongs) {
        expect(
          RecommendationEngine.isLikelySong(title),
          isFalse,
          reason: 'Expected "$title" to be rejected as non-song',
        );
      }

      // Valid songs should be accepted
      const validSongs = [
        'Kesariya - Official Music Video',
        'Starboy (Official Audio)',
        'Apna Bana Le - Full Audio Song',
        'Diljit Dosanjh - Lover (Lyric Video)',
        'Coldplay - Fix You (Live Performance)',
        'Taylor Swift - cardigan (Acoustic Version)',
      ];

      for (final title in validSongs) {
        expect(
          RecommendationEngine.isLikelySong(title),
          isTrue,
          reason: 'Expected "$title" to be accepted as valid song',
        );
      }
    });

    // Test 10: Duplicate candidate → rejected
    test('10. Duplicate candidate -> rejected', () {
      final candidates = [
        Map<String, dynamic>.from(hindiSong),
        Map<String, dynamic>.from(hindiSong), // duplicate ytid
        Map<String, dynamic>.from(hindiSong), // duplicate ytid
      ];

      final ranked = RecommendationEngine.instance.rankCandidates(
        candidates,
        regionCode: 'IN',
      );

      expect(ranked.length, equals(1));
    });

    // Test 11: Invalid YouTube ID → rejected
    test('11. Invalid YouTube ID -> rejected', () {
      final candidates = [
        {
          'ytid': '', // empty ID
          'title': 'Empty Song - Official Audio',
          '_rec_score': 50.0,
        },
        {
          'ytid': 'jamendo:12345', // Jamendo ID rejected in YouTube rec engine
          'title': 'Jamendo Song - Official Audio',
          '_rec_score': 50.0,
        },
        Map<String, dynamic>.from(hindiSong),
      ];

      final ranked = RecommendationEngine.instance.rankCandidates(
        candidates,
        regionCode: 'IN',
      );

      expect(ranked.length, equals(1));
      expect(ranked.first['ytid'], equals('hindi_01'));
    });

    // Test 12: Indian language priority weights match specifications
    test('12. Indian language hierarchy weights match specification', () {
      final map = {
        for (final l in MusicRegionService.indianLanguages) l.code: l.weight
      };

      expect(map['hi'], equals(1.00));
      expect(map['pa'], equals(0.85));
      expect(map['mr'], equals(0.75));
      expect(map['ta'], equals(0.70));
      expect(map['te'], equals(0.65));
      expect(map['bn'], equals(0.60));
      expect(map['kn'], equals(0.55));
      expect(map['ml'], equals(0.50));
      expect(map['gu'], equals(0.45));
    });
  });
}
