import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bodensee_pegel/main.dart';
import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:bodensee_pegel/activities_boats_service.dart';
import 'package:bodensee_pegel/favorites_service.dart';
import 'package:bodensee_pegel/station_data_cache.dart';
import 'package:bodensee_pegel/station_selection_service.dart';

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

  testWidgets('navigates through all primary destinations including Today', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-today')));
    await tester.pumpAndSettle();
    expect(find.byType(TodayPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-live')));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-analysis')));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-map')));
    await tester.pumpAndSettle();
    expect(find.byType(MapPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-more')));
    await tester.pumpAndSettle();
    expect(find.byType(MorePage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-today')));
    await tester.pumpAndSettle();
    expect(find.byType(TodayPage), findsOneWidget);
  });

  testWidgets('Today day picker selects another day', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: TodayPage()));
    await tester.pumpAndSettle();

    final tomorrow = find.byKey(const ValueKey('today-day-1'));
    await tester.tap(tomorrow);
    await tester.pump();

    expect(
      tester
          .widget<ChoiceChip>(
            find.descendant(of: tomorrow, matching: find.byType(ChoiceChip)),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.descendant(
              of: find.byKey(const ValueKey('today-day-0')),
              matching: find.byType(ChoiceChip),
            ),
          )
          .selected,
      isFalse,
    );
  });

  testWidgets('weekly planner keeps all seven day columns inside its card', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: TodayPage()));
    await tester.pumpAndSettle();

    final planner = find.byKey(const ValueKey('weekly-planner-table'));
    await tester.ensureVisible(planner);
    final table = tester.widget<Table>(planner);

    expect(table.columnWidths, hasLength(8));
    for (var index = 0; index <= 7; index++) {
      expect(table.columnWidths![index], isA<FixedColumnWidth>());
    }
  });

  testWidgets('Today uses the shared selected station', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('live-station-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ROMANSHORN').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-today')));
    await tester.pumpAndSettle();

    expect(find.byType(TodayPage), findsOneWidget);
    expect(find.text('ROMANSHORN'), findsWidgets);
  });

  testWidgets('opens activities and boats settings from Mehr', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-more')));
    await tester.pumpAndSettle();

    final entry = find.text('Meine Aktivitäten & Boote');
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ActivitiesBoatsPage), findsOneWidget);
    expect(find.text('MEINE AKTIVITÄTEN'), findsOneWidget);
    expect(find.text('MEINE BOOTE'), findsOneWidget);
  });

  testWidgets('activities and multiple boats persist after a widget rebuild', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: ActivitiesBoatsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('activity-segeln')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('activity-segeln')))
          .value,
      isTrue,
    );

    Future<void> addBoat(String name) async {
      await tester.tap(find.byKey(const ValueKey('add-boat-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('boat-name-field')),
        name,
      );
      await tester.tap(find.byKey(const ValueKey('boat-add-submit')));
      await tester.pumpAndSettle();
    }

    await addBoat('Seestern');
    await addBoat('Albatros');
    expect(find.text('Seestern'), findsOneWidget);
    expect(find.text('Albatros'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: ActivitiesBoatsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Seestern'), findsOneWidget);
    expect(find.text('Albatros'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('activity-segeln')))
          .value,
      isTrue,
    );
  });

  testWidgets('edits an existing boat without creating a duplicate', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = ActivitiesBoatsService();
    await service.saveBoats(const [
      BoatProfile(
        id: 'seestern',
        name: 'Seestern',
        bootType: BoatType.motorboat,
        lengthMeters: 6,
        widthMeters: 2.2,
        draftMeters: .6,
        heightAboveWaterlineMeters: 1.8,
      ),
    ]);

    await tester.pumpWidget(const MaterialApp(home: ActivitiesBoatsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('boat-row-seestern')));
    await tester.pumpAndSettle();

    expect(find.text('Boot bearbeiten'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('boat-name-field')))
          .controller!
          .text,
      'Seestern',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('boat-length-field')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '6',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('boat-width-field')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '2,2',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('boat-draft-field')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '0,6',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('boat-height-field')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '1,8',
    );

    await tester.enterText(
      find.byKey(const ValueKey('boat-name-field')),
      'Seestern II',
    );
    await tester.tap(find.byKey(const ValueKey('boat-add-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Seestern II'), findsOneWidget);
    expect(find.text('Seestern'), findsNothing);
    expect(find.byKey(const ValueKey('boat-row-seestern')), findsOneWidget);
  });

  testWidgets('cancels or confirms deletion of a boat', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await ActivitiesBoatsService().saveBoats(const [
      BoatProfile(
        id: 'albatros',
        name: 'Albatros',
        bootType: BoatType.sailboat,
      ),
    ]);
    await tester.pumpWidget(const MaterialApp(home: ActivitiesBoatsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('boat-row-albatros')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('boat-delete-button')));
    await tester.pumpAndSettle();
    expect(find.text('Boot wirklich löschen?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(find.text('Boot bearbeiten'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Albatros'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('boat-row-albatros')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('boat-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('boat-confirm-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Albatros'), findsNothing);
    expect(find.text('Noch keine Boote gespeichert.'), findsOneWidget);
  });

  testWidgets('Today filters activities and weekly rows from saved choices', (
    WidgetTester tester,
  ) async {
    await ActivitiesBoatsService().saveActivities(['segeln', 'wandern']);
    await tester.pumpWidget(const MaterialApp(home: TodayPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('today-activity-segeln')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('today-activity-wandern')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('today-activity-motorboot')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('weekly-activity-segeln')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('weekly-activity-wandern')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('weekly-activity-motorboot')),
      findsNothing,
    );
  });

  testWidgets('Today shows all activities when none are selected', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: TodayPage()));
    await tester.pumpAndSettle();

    for (final activity in plannerActivities) {
      expect(
        find.byKey(ValueKey('today-activity-${activity.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('weekly-activity-${activity.id}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('opens and closes the Romanshorn forecast detail view', (
    WidgetTester tester,
  ) async {
    final forecast = BafuForecastData(
      points: List.generate(
        3,
        (index) => BafuForecastPoint(
          timestamp: DateTime.utc(2026, 9, 12, 7).add(Duration(days: index)),
          medianMasl: 394.86 - index * .02,
          minimumMasl: 394.84 - index * .02,
          maximumMasl: 394.88 - index * .02,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForecastCard(
            station: BafuHydroService.romanshorn,
            forecast: forecast,
            waiting: false,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('forecast-detail-button')));
    await tester.pumpAndSettle();

    expect(find.byType(ForecastDetailPage), findsOneWidget);
    expect(find.text('PROGNOSE · ROMANSHORN'), findsOneWidget);
    expect(find.text('Quelle: BAFU'), findsOneWidget);
    expect(find.textContaining('Start '), findsOneWidget);
    expect(
      find.text(
        'Der hellblaue Bereich zeigt die Unsicherheit der BAFU-Prognose.',
      ),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(180, 250));
    await tester.pump();
    expect(find.textContaining('Median:'), findsOneWidget);
    expect(find.textContaining('Untergrenze:'), findsOneWidget);
    expect(find.textContaining('Obergrenze:'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('forecast-detail-close')));
    await tester.pumpAndSettle();

    expect(find.byType(ForecastDetailPage), findsNothing);
    expect(
      find.byKey(const ValueKey('forecast-detail-button')),
      findsOneWidget,
    );
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

  test(
    'restores the last station before the configured start station',
    () async {
      final preferences = SharedPreferencesAsync();
      await preferences.setString(
        StationSelectionService.startStationPreferenceKey,
        'aa9179c1-17ef-4c61-a48a-74193fa7bfdf',
      );
      await preferences.setString(
        StationSelectionService.lastSelectedStationPreferenceKey,
        'bafu-2032',
      );

      final selection = StationSelectionService(preferences: preferences);
      await selection.restoreInitialStation();

      expect(selection.currentStation.uuid, 'bafu-2032');
    },
  );

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
    await tester.pumpAndSettle();

    expect(find.byType(MapPage), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Analyse'), findsOneWidget);
    expect(find.text('Karte'), findsOneWidget);
    expect(find.text('Mehr'), findsOneWidget);
  });

  testWidgets('switches every bottom navigation destination repeatedly', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());

    await tester.tap(find.text('Analyse'));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisPage), findsOneWidget);

    await tester.tap(find.text('Karte'));
    await tester.pumpAndSettle();
    expect(find.byType(MapPage), findsOneWidget);

    await tester.tap(find.text('Mehr'));
    await tester.pumpAndSettle();
    expect(find.byType(MorePage), findsOneWidget);

    await tester.tap(find.text('Analyse'));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisPage), findsOneWidget);

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardPage), findsOneWidget);

    await tester.tap(find.text('Karte'));
    await tester.pumpAndSettle();
    expect(find.byType(MapPage), findsOneWidget);
  });

  testWidgets('keeps the live station while navigating to analysis and back', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('live-station-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ROMANSHORN').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-analysis')));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisPage), findsOneWidget);
    expect(find.text('ROMANSHORN'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-live')));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.text('ROMANSHORN'), findsWidgets);
  });

  testWidgets('uses an analysis station as the live station', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-analysis')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('analysis-station-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BREGENZ').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-live')));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.text('BREGENZ'), findsWidgets);
  });

  testWidgets('keeps an available analysis period when changing stations', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-analysis')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '30 Tage'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('analysis-station-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ROMANSHORN').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 Tage'))
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('analysis-station-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BREGENZ').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 Tage'))
          .selected,
      isTrue,
    );
  });

  testWidgets(
    'keeps the annual analysis range between Romanshorn and Bregenz',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BodenseePegelApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('nav-analysis')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('analysis-station-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ROMANSHORN').last);
      await tester.pumpAndSettle();
      final yearTab = find.widgetWithText(ChoiceChip, '1 Jahr');
      expect(yearTab, findsOneWidget);
      await tester.ensureVisible(yearTab);
      await tester.tap(yearTab);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('analysis-station-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BREGENZ').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1 Jahr'))
            .selected,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('analysis-station-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('KONSTANZ').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '1 Jahr'), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '24 h'))
            .selected,
        isTrue,
      );
    },
  );

  testWidgets('keeps a map-opened station across live and analysis', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('map-marker-bafu-2032')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Station öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('ROMANSHORN'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('nav-analysis')));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisPage), findsOneWidget);
    expect(find.text('ROMANSHORN'), findsOneWidget);
  });

  testWidgets('navigation alone never resets the selected station', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BodenseePegelApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('live-station-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ROMANSHORN').last);
    await tester.pumpAndSettle();

    for (final key in const [
      ValueKey('nav-analysis'),
      ValueKey('nav-map'),
      ValueKey('nav-more'),
      ValueKey('nav-live'),
    ]) {
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }
    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.text('ROMANSHORN'), findsWidgets);
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

    final sources = find.text('Datenquellen & Messstationen').first;
    await tester.ensureVisible(sources);
    await tester.tap(sources);
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

    await tester.tap(find.byKey(const ValueKey('about-data-sources-link')));
    await tester.pumpAndSettle();
    expect(find.byType(DataSourcesPage), findsOneWidget);
    expect(find.text('PEGELONLINE / WSV'), findsOneWidget);
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
