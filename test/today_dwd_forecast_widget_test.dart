import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:bodensee_pegel/dwd_forecast_service.dart';
import 'package:bodensee_pegel/environment_service.dart';
import 'package:bodensee_pegel/geosphere_forecast_service.dart';
import 'package:bodensee_pegel/main.dart';
import 'package:bodensee_pegel/meteoswiss_forecast_service.dart';
import 'package:bodensee_pegel/official_warning_service.dart';
import 'package:bodensee_pegel/pegelonline_service.dart';
import 'package:bodensee_pegel/station_selection_service.dart';
import 'package:bodensee_pegel/vorarlberg_hydro_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('Konstanz renders MOSMIX fixture data and switches days', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final service = DwdForecastService(
      client: MockClient(
        (_) async => http.Response.bytes(
          _kmz(_forecastKml(now)),
          200,
          headers: const {'content-type': 'application/vnd.google-earth.kmz'},
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scopedToday(station: StationSelectionService(), service: service),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);

    expect(
      find.text(
        'Prognose: Deutscher Wetterdienst (DWD) · MOSMIX',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(find.text('Regen'), findsOneWidget);
    expect(find.text('10–10 °C'), findsOneWidget);
    expect(
      find.textContaining('AB JETZT'),
      _fixtureForecastDayIndex(now) == 0 ? findsOneWidget : findsNothing,
    );
    expect(find.text('0,2 mm'), findsOneWidget);
    expect(
      find.text('ab jetzt'),
      _fixtureForecastDayIndex(now) == 0 ? findsOneWidget : findsNothing,
    );

    await _selectFixtureForecastDay(tester, now, offset: 1);
    expect(find.text('20–20 °C'), findsOneWidget);
    expect(find.textContaining('AB JETZT'), findsNothing);
    expect(find.text('1,5 mm'), findsOneWidget);
    expect(find.text('ab jetzt'), findsNothing);
  });

  testWidgets('Romanshorn renders MeteoSwiss fixture data and switches days', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final service = MeteoSwissForecastService(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode(_meteoswissForecastPayload(now)), 200),
      ),
    );
    final selection = StationSelectionService()
      ..select(BafuHydroService.romanshorn, persistLast: false);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scopedToday(
        station: selection,
        service: DwdForecastService(),
        meteoSwissService: service,
      ),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);

    expect(
      find.text('Prognose: MeteoSwiss', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('ziemlich sonnig'), findsOneWidget);
    expect(find.text('10–10 °C'), findsOneWidget);
    expect(find.text('0,2 mm'), findsOneWidget);
    expect(
      find.text('ab jetzt'),
      _fixtureForecastDayIndex(now) == 0 ? findsOneWidget : findsNothing,
    );
    expect(find.text('7 km/h · SW'), findsOneWidget);

    await _selectFixtureForecastDay(tester, now, offset: 1);
    expect(find.text('20–20 °C'), findsOneWidget);
    expect(find.text('1,5 mm'), findsOneWidget);
    expect(find.text('ab jetzt'), findsNothing);
  });

  testWidgets('Konstanz opens official warning details from the warning tile', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final forecastService = DwdForecastService(
      client: MockClient(
        (_) async => http.Response.bytes(_kmz(_forecastKml(now)), 200),
      ),
    );
    final warningService = OfficialWarningService(
      client: MockClient((request) async {
        if (request.url.host == '127.0.0.1') {
          return http.Response.bytes(_warningZip(_dwdWarningCap(now)), 200);
        }
        return http.Response('{}', 200);
      }),
    );
    expect((await warningService.loadDwdKonstanz()).warnings, hasLength(1));
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scopedToday(
        station: StationSelectionService(),
        service: forecastService,
        warningService: warningService,
      ),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);

    final warning = find.text('1 amtliche Warnung', skipOffstage: false);
    expect(warning, findsOneWidget);
    await tester.ensureVisible(warning);
    await tester.tap(warning);
    await tester.pumpAndSettle();
    expect(find.text('AMTLICHE WARNUNGEN'), findsOneWidget);
    expect(find.text('Gewitter'), findsOneWidget);
    await tester.tap(find.byTooltip('Schließen'));
    await tester.pumpAndSettle();
    expect(find.text('AMTLICHE WARNUNGEN'), findsNothing);
  });

  testWidgets('Romanshorn marks official warnings as unavailable', (
    tester,
  ) async {
    final selection = StationSelectionService()
      ..select(BafuHydroService.romanshorn, persistLast: false);
    final now = DateTime.now().toUtc();
    final service = MeteoSwissForecastService(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode(_meteoswissForecastPayload(now)), 200),
      ),
    );
    await tester.pumpWidget(
      _scopedToday(
        station: selection,
        service: DwdForecastService(),
        meteoSwissService: service,
      ),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);
    expect(
      find.text('Keine maschinenlesbaren Amtswarnungen', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Romanshorn shows the official BAFU level forecast by day', (
    tester,
  ) async {
    timezone_data.initializeTimeZones();
    final zurich = tz.getLocation('Europe/Zurich');
    final localTomorrow = tz.TZDateTime.now(zurich)
        .add(const Duration(days: 1));
    final tomorrowNoon = tz.TZDateTime(
      zurich,
      localTomorrow.year,
      localTomorrow.month,
      localTomorrow.day,
      12,
    ).toUtc();
    final bafuForecast = BafuForecastData(
      points: [
        BafuForecastPoint(
          timestamp: tomorrowNoon,
          medianMasl: 394.89,
          minimumMasl: 394.8,
          maximumMasl: 394.98,
        ),
      ],
    );
    final selection = StationSelectionService()
      ..select(BafuHydroService.romanshorn, persistLast: false);
    final weatherService = MeteoSwissForecastService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(_meteoswissForecastPayload(DateTime.now().toUtc())),
          200,
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scopedToday(
        station: selection,
        service: DwdForecastService(),
        meteoSwissService: weatherService,
        bafuForecastLoader: () async => bafuForecast,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('today-day-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('266 cm'), findsOneWidget);
    expect(find.textContaining('Prognose · 12:00'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-day-6')));
    await tester.pumpAndSettle();
    expect(find.text('Nicht verfügbar'), findsWidgets);
  });

  testWidgets('Bregenz renders GeoSphere data and keeps its short horizon', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final service = GeoSphereForecastService(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode(_geoSphereForecastPayload(now)), 200),
      ),
    );
    final selection = StationSelectionService()
      ..select(VorarlbergHydroService.bregenz, persistLast: false);
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scopedToday(
        station: selection,
        service: DwdForecastService(),
        geoSphereService: service,
      ),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);

    expect(
      find.text('Prognose: GeoSphere Austria', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('10–10 °C'), findsOneWidget);
    expect(find.text('0,2 mm'), findsOneWidget);
    expect(find.text('7 km/h · N'), findsOneWidget);
    expect(find.text('14 km/h'), findsOneWidget);
    expect(find.text('Nicht verfügbar'), findsWidgets);

    await _selectFixtureForecastDay(tester, now, offset: 1);
    expect(find.text('20–20 °C'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-day-6')));
    await tester.pumpAndSettle();
    expect(find.text('Nicht verfügbar'), findsWidgets);
  });

  testWidgets('Bregenz shows GeoSphere warnings for the selected day', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final forecastService = GeoSphereForecastService(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode(_geoSphereForecastPayload(now)), 200),
      ),
    );
    final warningService = OfficialWarningService(
      client: MockClient(
        (_) async => http.Response(_geoSphereWarningPayload(now), 200),
      ),
    );
    final selection = StationSelectionService()
      ..select(VorarlbergHydroService.bregenz, persistLast: false);
    await tester.pumpWidget(
      _scopedToday(
        station: selection,
        service: DwdForecastService(),
        geoSphereService: forecastService,
        warningService: warningService,
      ),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);

    final warning = find.text('1 amtliche Warnung', skipOffstage: false);
    expect(warning, findsOneWidget);
    await tester.ensureVisible(warning);
    await tester.tap(warning);
    await tester.pumpAndSettle();
    expect(find.text('Sturm'), findsOneWidget);
    expect(
      find.textContaining('Orange Warnung', skipOffstage: false),
      findsWidgets,
    );
  });

  testWidgets('Bregenz passes local water temperature only to today ratings', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final service = GeoSphereForecastService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(_geoSphereForecastPayload(now, firstTemperature: 22)),
          200,
        ),
      ),
    );
    final selection = StationSelectionService()
      ..select(VorarlbergHydroService.bregenz, persistLast: false);
    await tester.pumpWidget(
      _scopedToday(
        station: selection,
        service: DwdForecastService(),
        geoSphereService: service,
        environmentLoader: (_) async =>
            const StationEnvironmentData(waterTemperatureC: 20),
      ),
    );
    await tester.pumpAndSettle();
    await _selectFixtureForecastDay(tester, now);

    if (_fixtureForecastDayIndex(now) == 0) {
      expect(find.text('22 °C Luft · 20 °C Wasser'), findsOneWidget);
    } else {
      expect(
        find.textContaining('Wassertemperatur nicht verfügbar'),
        findsOneWidget,
      );
    }
    await _selectFixtureForecastDay(tester, now, offset: 1);
    expect(
      find.textContaining('Wassertemperatur nicht verfügbar'),
      findsOneWidget,
    );
  });

  testWidgets('missing MOSMIX values and Bregenz remain neutral', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final missingService = DwdForecastService(
      client: MockClient(
        (_) async =>
            http.Response.bytes(_kmz(_forecastKml(now, missing: true)), 200),
      ),
    );
    await tester.pumpWidget(
      _scopedToday(station: StationSelectionService(), service: missingService),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nicht verfügbar'), findsWidgets);

    final bregenzSelection = StationSelectionService()
      ..select(VorarlbergHydroService.bregenz, persistLast: false);
    await tester.pumpWidget(
      _scopedToday(station: bregenzSelection, service: missingService),
    );
    await tester.pumpAndSettle();
    expect(find.text('Noch keine Prognosedaten verfügbar'), findsWidgets);
    expect(
      find.text('Prognose: Deutscher Wetterdienst (DWD) · MOSMIX'),
      findsNothing,
    );
  });

  testWidgets(
    'Today derives activity ratings and weekly cells from forecasts',
    (tester) async {
      final service = DwdForecastService(
        client: MockClient(
          (_) async => http.Response.bytes(
            _kmz(_forecastKml(DateTime.now().toUtc())),
            200,
          ),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _scopedToday(station: StationSelectionService(), service: service),
      );
      await tester.pumpAndSettle();
      await _selectFixtureForecastDay(tester, DateTime.now().toUtc());

      expect(find.text('Noch keine Bewertung'), findsNothing);
      expect(find.text('Freizeit-Eignung aus Tagesprognosen'), findsOneWidget);
      expect(find.textContaining('· Sehr gut'), findsWidgets);
      expect(
        find.byKey(const ValueKey('today-activity-sup_kajak')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('weekly-planner-table')),
        findsOneWidget,
      );
      final weeklyTable = find.byKey(const ValueKey('weekly-planner-table'));
      await tester.ensureVisible(weeklyTable);
      final wholeScore = find.descendant(
        of: weeklyTable,
        matching: find.text('10'),
      );
      expect(wholeScore, findsWidgets);
      await tester.tap(wholeScore.first);
      await tester.pumpAndSettle();
      expect(find.text('Aktivitätsbewertung'), findsOneWidget);
      expect(find.textContaining('von 10 ·'), findsOneWidget);
      await tester.tap(find.text('Schließen'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Today shows tappable upcoming time-window ratings', (
    tester,
  ) async {
    final today = DateTime.now();
    final windowNow = DateTime(
      today.year,
      today.month,
      today.day,
      10,
      37,
    ).toUtc();
    final service = DwdForecastService(
      client: MockClient(
        (_) async => http.Response.bytes(_kmz(_timeWindowKml(windowNow)), 200),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scopedToday(
        station: StationSelectionService(),
        service: service,
        nowProvider: () => windowNow,
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('time-window-sup_kajak-Jetzt–12'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.textContaining(' · ')),
      findsOneWidget,
    );
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('Jetzt–12'), findsOneWidget);
    expect(find.textContaining('von 10 ·'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Leichter Wind'),
      ),
      findsOneWidget,
    );
  });
}

Widget _scopedToday({
  required StationSelectionService station,
  required DwdForecastService service,
  MeteoSwissForecastService? meteoSwissService,
  GeoSphereForecastService? geoSphereService,
  OfficialWarningService? warningService,
  Future<BafuForecastData> Function()? bafuForecastLoader,
  Future<StationEnvironmentData> Function(PegelStation)? environmentLoader,
  DateTime Function()? nowProvider,
}) => StationSelectionScope(
  notifier: station,
  child: MaterialApp(
    home: TodayPage(
      dwdForecastService: service,
      meteoSwissForecastService: meteoSwissService,
      geoSphereForecastService: geoSphereService,
      officialWarningService: warningService,
      bafuForecastLoader: bafuForecastLoader,
      environmentLoader: environmentLoader,
      nowProvider: nowProvider,
    ),
  ),
);

Future<void> _selectFixtureForecastDay(
  WidgetTester tester,
  DateTime fixtureNow, {
  int offset = 0,
}) async {
  final index = _fixtureForecastDayIndex(fixtureNow) + offset;
  if (index <= 0) return;
  await tester.tap(find.byKey(ValueKey('today-day-$index')));
  await tester.pumpAndSettle();
}

int _fixtureForecastDayIndex(DateTime fixtureNow) {
  final point = fixtureNow.add(const Duration(minutes: 10)).toLocal();
  final today = DateTime.now();
  final todayOnly = DateTime(today.year, today.month, today.day);
  final pointOnly = DateTime(point.year, point.month, point.day);
  return pointOnly.difference(todayOnly).inDays;
}

Uint8List _warningZip(String xml) {
  final archive = Archive()
    ..addFile(ArchiveFile('warning.xml', xml.length, utf8.encode(xml)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _dwdWarningCap(DateTime now) {
  final start = now.add(const Duration(minutes: 10)).toIso8601String();
  final end = now.add(const Duration(hours: 6)).toIso8601String();
  return '''<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>test-warning</identifier><sent>${now.toIso8601String()}</sent>
  <info><event>Gewitter</event><severity>Severe</severity><onset>$start</onset><expires>$end</expires>
  <headline>Amtliche Gewitterwarnung</headline>
  <area><areaDesc>Konstanz</areaDesc><geocode><valueName>WARNCELLID</valueName><value>808335043</value></geocode></area>
  </info></alert>''';
}

String _geoSphereWarningPayload(DateTime now) => jsonEncode({
  'properties': {
    'location': {
      'properties': {'name': 'Bregenz'},
    },
    'warnings': [
      {
        'warnid': 'fixture-storm',
        'warnstufeid': 2,
        'warntypid': 1,
        'create': now.toIso8601String(),
        'begin': now.add(const Duration(minutes: 5)).toIso8601String(),
        'end': now.add(const Duration(hours: 4)).toIso8601String(),
        'text': 'Amtliche Sturmwarnung',
      },
    ],
  },
});

Map<String, dynamic> _meteoswissForecastPayload(DateTime now) {
  final first = now.add(const Duration(minutes: 10));
  final second = first.add(const Duration(days: 1));
  Map<String, dynamic> point(
    DateTime timestamp,
    double temperature,
    double rain,
  ) => {
    'timestampUtc': timestamp.toIso8601String(),
    'temperatureCelsius': temperature,
    'precipitationMillimeters': rain,
    'windKilometersPerHour': 7,
    'gustKilometersPerHour': 14,
    'windDirectionDegrees': 225,
    'weatherCode': 2,
  };
  return {
    'station': {
      'pointId': '859000',
      'pointTypeId': '2',
      'postalCode': '8590',
      'name': 'Romanshorn',
      'latitude': 47.566578,
      'longitude': 9.370531,
      'elevationMeters': 412,
    },
    'updatedAtUtc': now.toIso8601String(),
    'runAtUtc': now.toIso8601String(),
    'points': [point(first, 10, .2), point(second, 20, 1.5)],
  };
}

Map<String, dynamic> _geoSphereForecastPayload(
  DateTime now, {
  double firstTemperature = 10,
}) {
  final first = now.add(const Duration(minutes: 10));
  final second = first.add(const Duration(days: 1));
  List<Object?> values(Object? firstValue, Object? secondValue) => [
    firstValue,
    secondValue,
  ];
  Map<String, dynamic> parameter(
    String name,
    String unit,
    List<Object?> data,
  ) => {'name': name, 'unit': unit, 'data': data};
  return {
    'reference_time': now.toIso8601String(),
    'timestamps': [first.toIso8601String(), second.toIso8601String()],
    'features': [
      {
        'geometry': {
          'type': 'Point',
          'coordinates': [9.7432, 47.502],
        },
        'properties': {
          'parameters': {
            '2t': parameter(
              '2m temperature',
              'degree Celsius',
              values(firstTemperature, 20),
            ),
            '10u': parameter('eastward wind', 'm s-1', values(0, 0)),
            '10v': parameter('northward wind', 'm s-1', values(-2, -2)),
            '10fg': parameter('gust', 'm s-1', values(4, 5)),
            'tp': parameter('precipitation', 'kg m-2', values(.2, 1.5)),
            'sy': parameter('weather symbol', '1', values(7, 7)),
            'tcc': parameter('cloud cover', '%', values(20, 20)),
          },
        },
      },
    ],
  };
}

String _forecastKml(DateTime now, {bool missing = false}) {
  final first = now.add(const Duration(minutes: 10));
  final second = first.add(const Duration(days: 1));
  final ttt = missing ? '- -' : '283.15 293.15';
  return '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:dwd="https://opendata.dwd.de/weather/lib/pointforecast_dwd_extension_V1_0.xsd">
<dwd:ProductDefinition><dwd:ForecastTimeSteps><dwd:TimeStep>${first.toIso8601String()}</dwd:TimeStep><dwd:TimeStep>${second.toIso8601String()}</dwd:TimeStep></dwd:ForecastTimeSteps></dwd:ProductDefinition>
<Document><Placemark><name>10929</name><description>KONSTANZ</description><Point><coordinates>9.18,47.68,443</coordinates></Point>
<dwd:Forecast dwd:elementName="TTT"><dwd:value>$ttt</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="FF"><dwd:value>2 3</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="FX1"><dwd:value>4 5</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="DD"><dwd:value>225 180</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="RR1c"><dwd:value>0.2 1.5</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="ww"><dwd:value>61 61</dwd:value></dwd:Forecast>
</Placemark></Document></kml>''';
}

String _timeWindowKml(DateTime now) {
  final eleven = now.add(const Duration(minutes: 23));
  final noon = now.add(const Duration(hours: 1, minutes: 23));
  final evening = now.add(const Duration(hours: 7, minutes: 23));
  return '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:dwd="https://opendata.dwd.de/weather/lib/pointforecast_dwd_extension_V1_0.xsd">
<dwd:ProductDefinition><dwd:ForecastTimeSteps><dwd:TimeStep>${eleven.toIso8601String()}</dwd:TimeStep><dwd:TimeStep>${noon.toIso8601String()}</dwd:TimeStep><dwd:TimeStep>${evening.toIso8601String()}</dwd:TimeStep></dwd:ForecastTimeSteps></dwd:ProductDefinition>
<Document><Placemark><name>10929</name><description>KONSTANZ</description><Point><coordinates>9.18,47.68,443</coordinates></Point>
<dwd:Forecast dwd:elementName="TTT"><dwd:value>293.15 294.15 290.15</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="FF"><dwd:value>2 3 4</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="FX1"><dwd:value>4 5 6</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="DD"><dwd:value>90 180 270</dwd:value></dwd:Forecast>
<dwd:Forecast dwd:elementName="RR1c"><dwd:value>0.2 0.2 0.1</dwd:value></dwd:Forecast>
</Placemark></Document></kml>''';
}

Uint8List _kmz(String kml) {
  final bytes = utf8.encode(kml);
  final archive = Archive()
    ..addFile(
      ArchiveFile('MOSMIX_L_2026091215_10929.kml', bytes.length, bytes),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
