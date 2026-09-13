import 'dart:convert';

import 'package:bodensee_pegel/geosphere_forecast_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('parses GeoSphere point JSON, timestamps and missing values', () {
    final forecast = GeoSphereForecastParser.parseJson(
      jsonEncode(_payload([DateTime.utc(2026, 9, 13, 10)])),
    );

    expect(forecast.referenceTimeUtc, DateTime.utc(2026, 9, 13, 3));
    expect(forecast.gridLatitude, closeTo(47.502, .0001));
    expect(forecast.gridLongitude, closeTo(9.7432, .0001));
    expect(forecast.points.single.temperatureCelsius, 20);
    expect(forecast.points.single.weatherSymbolCode, 7);
    expect(forecast.points.single.cloudCoverPercent, isNull);
  });

  test('converts GeoSphere U/V to speed and meteorological direction', () {
    GeoSphereForecastPoint point(double u, double v) => GeoSphereForecastPoint(
      timestampUtc: DateTime.utc(2026, 9, 13, 10),
      windEastwardMetersPerSecond: u,
      windNorthwardMetersPerSecond: v,
    );

    expect(point(0, -1).meteorologicalWindDirectionDegrees, closeTo(0, .001));
    expect(point(-1, -1).meteorologicalWindDirectionDegrees, closeTo(45, .001));
    expect(point(-1, 0).meteorologicalWindDirectionDegrees, closeTo(90, .001));
    expect(point(-1, 1).meteorologicalWindDirectionDegrees, closeTo(135, .001));
    expect(point(0, 1).meteorologicalWindDirectionDegrees, closeTo(180, .001));
    expect(point(1, 1).meteorologicalWindDirectionDegrees, closeTo(225, .001));
    expect(point(1, 0).meteorologicalWindDirectionDegrees, closeTo(270, .001));
    expect(point(1, -1).meteorologicalWindDirectionDegrees, closeTo(315, .001));
    expect(point(3, 4).windKilometersPerHour, closeTo(18, .001));
  });

  test(
    'aggregates original Celsius, precipitation and gusts by Vienna day',
    () {
      final times = [
        DateTime.utc(2026, 9, 13, 10),
        DateTime.utc(2026, 9, 13, 11),
        DateTime.utc(2026, 9, 13, 12),
      ];
      final forecast = GeoSphereForecastParser.parseJson(
        jsonEncode(_payload(times)),
      );
      final days = GeoSphereForecastAggregation.aggregate(
        forecast,
        nowUtc: DateTime.utc(2026, 9, 13, 9),
      );
      final day = days.single;

      expect(day.temperatureMinimumCelsius, 20);
      expect(day.temperatureMaximumCelsius, 22);
      expect(day.precipitationMillimeters, closeTo(1.5, .0001));
      expect(day.maximumGustKilometersPerHour, closeTo(21.6, .0001));
      expect(day.representativeWindKilometersPerHour, closeTo(7.2, .0001));
      expect(day.windDirectionAbbreviation, 'N');
    },
  );

  test('keeps only future points for the incomplete current Vienna day', () {
    final times = [DateTime.utc(2026, 9, 13, 8), DateTime.utc(2026, 9, 13, 10)];
    final forecast = GeoSphereForecastParser.parseJson(
      jsonEncode(_payload(times)),
    );
    final days = GeoSphereForecastAggregation.aggregate(
      forecast,
      nowUtc: DateTime.utc(2026, 9, 13, 9),
    );

    expect(days.single.points, hasLength(1));
    expect(days.single.precipitationMillimeters, closeTo(.5, .0001));
  });

  test('maps meteorological bearings into the tested eight sectors', () {
    String? abbreviation(double degrees) => GeoSphereDailyForecast(
      localDate: DateTime(2026, 9, 13),
      points: const [],
      windDirectionDegrees: degrees,
    ).windDirectionAbbreviation;

    expect(abbreviation(0), 'N');
    expect(abbreviation(45), 'NO');
    expect(abbreviation(90), 'O');
    expect(abbreviation(135), 'SO');
    expect(abbreviation(180), 'S');
    expect(abbreviation(225), 'SW');
    expect(abbreviation(270), 'W');
    expect(abbreviation(315), 'NW');
    expect(abbreviation(359), 'N');
  });

  test('handles Vienna daylight saving calendar boundaries', () {
    final times = [
      DateTime.utc(2026, 10, 24, 22),
      DateTime.utc(2026, 10, 25, 22),
    ];
    final forecast = GeoSphereForecastParser.parseJson(
      jsonEncode(_payload(times)),
    );
    final days = GeoSphereForecastAggregation.aggregate(
      forecast,
      nowUtc: DateTime.utc(2026, 10, 24, 20),
    );

    expect(days, hasLength(1));
    expect(days.single.localDate.day, 25);
    expect(days.single.points, hasLength(2));
  });

  test('retains missing parameters as unavailable values', () {
    final payload = _payload([DateTime.utc(2026, 9, 13, 10)])
      ..['features'][0]['properties']['parameters'].remove('10fg');
    final forecast = GeoSphereForecastParser.parseJson(jsonEncode(payload));

    expect(forecast.points.single.gustMetersPerSecond, isNull);
  });

  test('surfaces parser and network errors', () async {
    expect(
      () => GeoSphereForecastParser.parseJson('{invalid'),
      throwsFormatException,
    );
    final service = GeoSphereForecastService(
      client: MockClient((_) async => http.Response('Unavailable', 503)),
    );
    expect(service.load(), throwsA(isA<GeoSphereForecastException>()));
  });
}

Map<String, dynamic> _payload(List<DateTime> timestamps) {
  List<Object?> series(Object? Function(int) value) =>
      List<Object?>.generate(timestamps.length, value);
  Map<String, dynamic> parameter(
    String name,
    String unit,
    List<Object?> data,
  ) => {'name': name, 'unit': unit, 'data': data};
  return {
    'reference_time': '2026-09-13T03:00+00:00',
    'timestamps': timestamps.map((time) => time.toIso8601String()).toList(),
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
              series((index) => 20 + index),
            ),
            '10u': parameter('eastward wind', 'm s-1', series((_) => 0)),
            '10v': parameter('northward wind', 'm s-1', series((_) => -2)),
            '10fg': parameter('gust', 'm s-1', series((index) => 4 + index)),
            'tp': parameter('precipitation', 'kg m-2', series((_) => .5)),
            'sy': parameter('weather symbol', '1', series((_) => 7)),
            'tcc': parameter('cloud cover', '%', series((_) => null)),
          },
        },
      },
    ],
  };
}
