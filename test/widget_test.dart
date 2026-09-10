import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bodensee_pegel/main.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    PackageInfo.setMockInitialValues(
      appName: 'Bodensee Pegel+',
      packageName: 'de.bodenseepegel.app',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('shows the live Bodensee Pegel view', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BodenseePegelApp());

    expect(find.text('Bodensee Pegel+'), findsOneWidget);
    expect(find.byType(DashboardPage), findsOneWidget);
  });

  testWidgets('shows the analysis view', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AnalysisPage()));

    expect(find.text('ANALYSE'), findsOneWidget);
  });

  testWidgets('opens the map from bottom navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BodenseePegelApp());

    await tester.tap(find.byKey(const ValueKey('nav-map')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MapPage), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Analyse'), findsOneWidget);
    expect(find.text('Karte'), findsOneWidget);
    expect(find.text('Mehr'), findsOneWidget);
  });

  testWidgets('opens Mehr and persists its configured start station', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BodenseePegelApp());

    await tester.tap(find.byKey(const ValueKey('nav-more')));
    await tester.pumpAndSettle();

    expect(find.byType(MorePage), findsOneWidget);
    expect(find.text('EINSTELLUNGEN'), findsOneWidget);

    await tester.tap(find.text('Startstation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ROMANSHORN'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(home: MorePage()));
    await tester.pumpAndSettle();

    expect(find.text('ROMANSHORN'), findsOneWidget);
  });

  testWidgets('opens Mehr information subpages', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MorePage()));

    await tester.tap(find.text('Datenquellen & Messstationen'));
    await tester.pumpAndSettle();
    expect(find.byType(DataSourcesPage), findsOneWidget);
    expect(find.text('PEGELONLINE / WSV'), findsOneWidget);

    await tester.tap(find.byTooltip('Zurück'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Über Bodensee Pegel+'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('BODENSEE PEGEL+'), findsOneWidget);
    expect(find.text('Version 1.0.0 (1)'), findsOneWidget);
  });

  for (final width in [320.0, 430.0]) {
    testWidgets('keeps Mehr responsive at ${width.toInt()} px', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(const MaterialApp(home: MorePage()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('DATENQUELLEN & MESSSTATIONEN'), findsOneWidget);
    });
  }

  for (final station in const [
    ('aa9179c1-17ef-4c61-a48a-74193fa7bfdf', 'KONSTANZ'),
    ('bafu-2032', 'ROMANSHORN'),
    ('vowis-200337', 'BREGENZ'),
  ]) {
    testWidgets('opens ${station.$2} from its map panel', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BodenseePegelApp());
      await tester.tap(find.byKey(const ValueKey('nav-map')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(ValueKey('map-marker-${station.$1}')));
      await tester.pump();
      await tester.tap(find.text('Station öffnen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.text(station.$2), findsWidgets);
    });
  }
}
