import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bodensee_pegel/dwd_forecast_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const first = '2026-09-12T16:00:00.000Z';
  const second = '2026-09-12T17:00:00.000Z';
  const third = '2026-09-13T10:00:00.000Z';

  test('parses KMZ points, their time steps and missing DWD values', () {
    final forecast = DwdMosmixParser.parseKmz(
      _kmz(
        _kml(
          times: const [first, second, third],
          values: const {
            'TTT': '283.15 - 293.15',
            'FF': '1.5 2 3',
            'FX1': '3 4 5',
            'DD': '180 190 200',
            'RR1c': '0.1 - 2.4',
            'ww': '2 61 3',
            'N': '10 90 50',
          },
        ),
      ),
    );

    expect(forecast.station.id, '10929');
    expect(forecast.station.name, 'KONSTANZ');
    expect(forecast.issuedAtUtc, DateTime.utc(2026, 9, 12, 15));
    expect(forecast.points, hasLength(3));
    expect(forecast.points[0].timestampUtc, DateTime.parse(first).toUtc());
    expect(forecast.points[1].temperatureKelvin, isNull);
    expect(forecast.points[1].precipitationMillimeters, isNull);
    expect(forecast.points[2].weatherCode, 3);
  });

  test('converts documented MOSMIX Kelvin and metres per second centrally', () {
    final point = DwdForecastPoint(
      timestampUtc: DateTime.utc(2026, 9, 12),
      temperatureKelvin: 293.15,
      windMetersPerSecond: 5,
      gustMetersPerSecond: 7.5,
    );
    expect(point.temperatureCelsius, closeTo(20, .0001));
    expect(point.windKilometersPerHour, closeTo(18, .0001));
    expect(point.gustKilometersPerHour, closeTo(27, .0001));
  });

  test(
    'aggregates local forecast days without treating missing rain as zero',
    () {
      final forecast = _forecast([
        DwdForecastPoint(
          timestampUtc: DateTime.utc(2026, 9, 12, 16),
          temperatureKelvin: 283.15,
          windMetersPerSecond: 2,
          gustMetersPerSecond: 4,
          windDirectionDegrees: 225,
          precipitationMillimeters: .3,
          weatherCode: 2,
        ),
        DwdForecastPoint(
          timestampUtc: DateTime.utc(2026, 9, 12, 17),
          temperatureKelvin: 293.15,
          windMetersPerSecond: 4,
          gustMetersPerSecond: 7,
          windDirectionDegrees: 225,
          precipitationMillimeters: null,
          weatherCode: 61,
        ),
        DwdForecastPoint(
          timestampUtc: DateTime.utc(2026, 9, 13, 10),
          temperatureKelvin: 288.15,
          windMetersPerSecond: 3,
          gustMetersPerSecond: 8,
          windDirectionDegrees: 180,
          precipitationMillimeters: 1.2,
          weatherCode: 3,
        ),
      ]);

      final days = DwdMosmixAggregation.aggregate(
        forecast,
        nowUtc: DateTime.utc(2026, 9, 12, 15),
      );
      expect(days, hasLength(2));
      final today = days.first;
      expect(today.temperatureMinimumCelsius, closeTo(10, .001));
      expect(today.temperatureMaximumCelsius, closeTo(20, .001));
      expect(today.precipitationMillimeters, closeTo(.3, .001));
      expect(today.maximumGustKilometersPerHour, closeTo(25.2, .001));
      expect(today.windDirectionAbbreviation, 'SW');
      expect(today.weatherLabel, isNull);
    },
  );

  test(
    'uses Europe/Berlin calendar boundaries across daylight saving time',
    () {
      final days = DwdMosmixAggregation.aggregate(
        _forecast([
          DwdForecastPoint(timestampUtc: DateTime.utc(2026, 3, 29, 21)),
          DwdForecastPoint(timestampUtc: DateTime.utc(2026, 3, 29, 22)),
        ]),
        nowUtc: DateTime.utc(2026, 3, 28),
      );
      expect(days.map((day) => day.localDate), [
        DateTime(2026, 3, 29),
        DateTime(2026, 3, 30),
      ]);
    },
  );

  test(
    'keeps an incomplete current day limited to remaining forecast points',
    () {
      final days = DwdMosmixAggregation.aggregate(
        _forecast([
          DwdForecastPoint(
            timestampUtc: DateTime.utc(2026, 9, 12, 8),
            temperatureKelvin: 273.15,
          ),
          DwdForecastPoint(
            timestampUtc: DateTime.utc(2026, 9, 12, 16),
            temperatureKelvin: 293.15,
          ),
        ]),
        nowUtc: DateTime.utc(2026, 9, 12, 12),
      );
      expect(days.single.temperatureMinimumCelsius, closeTo(20, .001));
      expect(days.single.temperatureMaximumCelsius, closeTo(20, .001));
    },
  );

  test(
    'allows omitted MOSMIX parameters and reports unavailable daily values',
    () {
      final forecast = DwdMosmixParser.parseKmz(
        _kmz(_kml(times: const [first], values: const {'TTT': '-'})),
      );
      final day = DwdMosmixAggregation.aggregate(
        forecast,
        nowUtc: DateTime.utc(2026, 9, 12),
      ).single;
      expect(day.temperatureMinimumCelsius, isNull);
      expect(day.representativeWindKilometersPerHour, isNull);
      expect(day.precipitationMillimeters, isNull);
    },
  );

  test(
    'surfaces malformed KMZ and network failures as forecast errors',
    () async {
      expect(
        () => DwdMosmixParser.parseKmz(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      final service = DwdForecastService(
        client: MockClient((_) async => http.Response('unavailable', 502)),
      );
      expect(service.load(), throwsA(isA<DwdForecastException>()));
    },
  );
}

DwdMosmixForecast _forecast(List<DwdForecastPoint> points) => DwdMosmixForecast(
  station: DwdMosmixStation.konstanz,
  issuedAtUtc: DateTime.utc(2026, 9, 12, 15),
  points: points,
);

Uint8List _kmz(String kml) {
  final data = utf8.encode(kml);
  final archive = Archive()
    ..addFile(ArchiveFile('MOSMIX_L_2026091215_10929.kml', data.length, data));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _kml({
  required List<String> times,
  required Map<String, String> values,
}) {
  final forecasts = values.entries
      .map(
        (entry) =>
            '<dwd:Forecast dwd:elementName="${entry.key}">'
            '<dwd:value>${entry.value}</dwd:value></dwd:Forecast>',
      )
      .join();
  final timeSteps = times
      .map((time) => '<dwd:TimeStep>$time</dwd:TimeStep>')
      .join();
  return '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"
     xmlns:dwd="https://opendata.dwd.de/weather/lib/pointforecast_dwd_extension_V1_0.xsd">
  <dwd:ProductDefinition><dwd:ForecastTimeSteps>$timeSteps</dwd:ForecastTimeSteps></dwd:ProductDefinition>
  <Document><Placemark><name>10929</name><description>KONSTANZ</description>
  <Point><coordinates>9.18,47.68,443.0</coordinates></Point>$forecasts</Placemark></Document>
</kml>''';
}
