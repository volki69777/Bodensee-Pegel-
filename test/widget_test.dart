import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bodensee_pegel/main.dart';
import 'package:bodensee_pegel/favorites_service.dart';
import 'package:bodensee_pegel/station_data_cache.dart';

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

  test(
    'uses all three stations as default favorites and persists changes',
    () async {
      final service = FavoritesService();
      const stations = ['konstanz', 'romanshorn', 'bregenz'];

      expect(
        await service.load(validStationUuids: stations),
        orderedEquals(stations),
      );

      final withoutRomanshorn = await service.toggle(
        stationUuid: 'romanshorn',
        currentFavorites: stations,
      );
      expect(withoutRomanshorn, orderedEquals(['konstanz', 'bregenz']));
      expect(
        await FavoritesService().load(validStationUuids: stations),
        orderedEquals(['konstanz', 'bregenz']),
      );
    },
  );

  test('shares parallel station requests through the cache', () async {
    final cache = StationDataCache<int>();
    final completer = Completer<int>();
    var requests = 0;
    Future<int> load() {
      requests++;
      return completer.future;
    }

    final first = cache.get('konstanz', load);
    final second = cache.get('konstanz', load);
    expect(identical(first, second), isTrue);
    expect(requests, 1);

    completer.complete(42);
    expect(await first, 42);
    cache.invalidate('konstanz');
    expect(await cache.get('konstanz', () async => ++requests), 2);
  });

  testWidgets('shows and clears the favorites empty state with the star', (
    WidgetTester tester,
  ) async {
    await SharedPreferencesAsync().setStringList(
      FavoritesService.preferenceKey,
      const [],
    );
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pump();

    expect(
      find.text('Noch keine Favoriten – Stern bei einer Station wählen.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('favorite-toggle')));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey('favorite-card-aa9179c1-17ef-4c61-a48a-74193fa7bfdf'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('removes and restores the current station with the star', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    const konstanzCard = ValueKey(
      'favorite-card-aa9179c1-17ef-4c61-a48a-74193fa7bfdf',
    );
    expect(find.byKey(const ValueKey('favorite-toggle')), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byKey(konstanzCard), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('favorite-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
    expect(find.byKey(konstanzCard), findsNothing);

    await tester.tap(find.byKey(const ValueKey('favorite-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byKey(konstanzCard), findsOneWidget);
  });

  testWidgets('selects a favorite station directly on the live page', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pump();
    await tester.pump();

    final romanshorn = find.byKey(const ValueKey('favorite-card-bafu-2032'));
    await tester.ensureVisible(romanshorn);
    await tester.tap(romanshorn);
    await tester.pump();

    expect(find.text('ROMANSHORN'), findsWidgets);
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
    final about = find.text('Über Bodensee Pegel+');
    await tester.ensureVisible(about);
    await tester.tap(about);
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
      expect(find.text('INFORMATIONEN'), findsOneWidget);
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
      // The compact map sheet is intentionally not scrollable. Give this
      // interaction test enough vertical room to exercise its button exactly
      // as a normal larger device would, without changing production UI.
      await tester.binding.setSurfaceSize(const Size(430, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BodenseePegelApp());
      await tester.tap(find.byKey(const ValueKey('nav-map')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('map-marker-${station.$1}')));
      await tester.pumpAndSettle();
      final openStation = find.text('Station öffnen');
      await tester.ensureVisible(openStation);
      await tester.tap(openStation);
      await tester.pumpAndSettle();

      expect(find.byType(DashboardPage), findsOneWidget);
      expect(find.text(station.$2), findsWidgets);
    });
  }
}
