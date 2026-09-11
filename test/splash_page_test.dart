import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundwave/screens/splash_page.dart';
import 'package:soundwave/services/router_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Splash Screen Tests', () {
    test('splashPath is registered correctly', () {
      expect(NavigationManager.splashPath, equals('/splash'));
      expect(NavigationManager.homePath, equals('/home'));
    });

    testWidgets('SplashPage renders SoundWave title and logo image',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SplashPage(),
        ),
      );

      // Verify SoundWave title is displayed
      expect(find.text('SoundWave'), findsOneWidget);
      expect(find.text('Feel the rhythm'), findsOneWidget);

      // Verify Image.asset is targeting assets/icons/soundwave.png
      final imageFinder = find.byType(Image);
      expect(imageFinder, findsOneWidget);

      final imageWidget = tester.widget<Image>(imageFinder);
      expect(imageWidget.image, isA<AssetImage>());
      final assetImage = imageWidget.image as AssetImage;
      expect(assetImage.assetName, equals('assets/icons/soundwave.png'));

      // Let animations run and dispose properly
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
