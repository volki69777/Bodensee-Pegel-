import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:bodensee_pegel/dwd_forecast_service.dart';
import 'package:bodensee_pegel/main.dart';
import 'package:bodensee_pegel/station_selection_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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
    expect(find.text('0,2 mm · ab jetzt'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('today-day-1')));
    await tester.pumpAndSettle();
    expect(find.text('20–20 °C'), findsOneWidget);
    expect(find.textContaining('AB JETZT'), findsNothing);
    expect(find.text('1,5 mm'), findsOneWidget);
    expect(find.text('1,5 mm · ab jetzt'), findsNothing);
  });

  testWidgets('missing MOSMIX values and non-Konstanz remain neutral', (
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

    final romanshornSelection = StationSelectionService()
      ..select(BafuHydroService.romanshorn, persistLast: false);
    await tester.pumpWidget(
      _scopedToday(station: romanshornSelection, service: missingService),
    );
    await tester.pumpAndSettle();
    expect(find.text('Noch keine Prognosedaten verfügbar'), findsWidgets);
    expect(
      find.text('Prognose: Deutscher Wetterdienst (DWD) · MOSMIX'),
      findsNothing,
    );
  });
}

Widget _scopedToday({
  required StationSelectionService station,
  required DwdForecastService service,
}) => StationSelectionScope(
  notifier: station,
  child: MaterialApp(home: TodayPage(dwdForecastService: service)),
);

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
