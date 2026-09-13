import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:bodensee_pegel/dwd_forecast_service.dart';
import 'package:bodensee_pegel/environment_service.dart';
import 'package:bodensee_pegel/geosphere_forecast_service.dart';
import 'package:bodensee_pegel/main.dart';
import 'package:bodensee_pegel/meteoswiss_forecast_service.dart';
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

    expect(
      find.text('Prognose: Deutscher Wetterdienst (DWD) · MOSMIX'),
      findsOneWidget,
    );
    expect(find.text('Regen'), findsOneWidget);
    expect(find.text('10–10 °C'), findsOneWidget);
    expect(find.textContaining('AB JETZT'), findsOneWidget);
    expect(find.text('0,2 mm'), findsOneWidget);
    expect(find.text('ab jetzt'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-day-1')));
    await tester.pumpAndSettle();
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

    expect(find.text('Prognose: MeteoSwiss'), findsOneWidget);
    expect(find.text('ziemlich sonnig'), findsOneWidget);
    expect(find.text('10–10 °C'), findsOneWidget);
    expect(find.text('0,2 mm'), findsOneWidget);
    expect(find.text('ab jetzt'), findsOneWidget);
    expect(find.text('7 km/h · SW'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-day-1')));
    await tester.pumpAndSettle();
    expect(find.text('20–20 °C'), findsOneWidget);
    expect(find.text('1,5 mm'), findsOneWidget);
    expect(find.text('ab jetzt'), findsNothing);
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

    expect(find.text('Prognose: GeoSphere Austria'), findsOneWidget);
    expect(find.text('10–10 °C'), findsOneWidget);
    expect(find.text('0,2 mm'), findsOneWidget);
    expect(find.text('7 km/h · N'), findsOneWidget);
    expect(find.text('14 km/h'), findsOneWidget);
    expect(find.text('Nicht verfügbar'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('today-day-1')));
    await tester.pumpAndSettle();
    expect(find.text('20–20 °C'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-day-6')));
    await tester.pumpAndSettle();
    expect(find.text('Nicht verfügbar'), findsWidgets);
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

    expect(find.text('22 °C Luft · 20 °C Wasser'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-day-1')));
    await tester.pumpAndSettle();
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

      expect(find.text('Noch keine Bewertung'), findsNothing);
      expect(find.text('Freizeit-Eignung aus Tagesprognosen'), findsOneWidget);
      expect(find.text('Sehr gut'), findsWidgets);
      expect(
        find.byKey(const ValueKey('today-activity-sup_kajak')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('weekly-planner-table')),
        findsOneWidget,
      );
    },
  );
}

Widget _scopedToday({
  required StationSelectionService station,
  required DwdForecastService service,
  MeteoSwissForecastService? meteoSwissService,
  GeoSphereForecastService? geoSphereService,
  Future<BafuForecastData> Function()? bafuForecastLoader,
  Future<StationEnvironmentData> Function(PegelStation)? environmentLoader,
}) => StationSelectionScope(
  notifier: station,
  child: MaterialApp(
    home: TodayPage(
      dwdForecastService: service,
      meteoSwissForecastService: meteoSwissService,
      geoSphereForecastService: geoSphereService,
      bafuForecastLoader: bafuForecastLoader,
      environmentLoader: environmentLoader,
    ),
  ),
);

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

Uint8List _kmz(String kml) {
  final bytes = utf8.encode(kml);
  final archive = Archive()
    ..addFile(
      ArchiveFile('MOSMIX_L_2026091215_10929.kml', bytes.length, bytes),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
