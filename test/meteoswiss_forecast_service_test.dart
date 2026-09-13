import 'dart:convert';

import 'package:bodensee_pegel/meteoswiss_forecast_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('parses Romanshorn point data, timestamps and missing values', () {
    final forecast = MeteoSwissForecastParser.parseJson(
      jsonEncode(
        _payload(
          points: [
            _point('2026-09-12T10:00:00Z', temperature: 15.4, rain: .2),
            _point('2026-09-12T11:00:00Z', temperature: null, rain: null),
          ],
        ),
      ),
    );

    expect(forecast.station.pointId, '859000');
    expect(forecast.station.postalCode, '8590');
    expect(forecast.points, hasLength(2));
    expect(forecast.points[0].timestampUtc, DateTime.utc(2026, 9, 12, 10));
    expect(forecast.points[1].temperatureCelsius, isNull);
    expect(forecast.points[1].precipitationMillimeters, isNull);
    expect(forecast.points[0].windKilometersPerHour, 11.2);
  });

  test('aggregates original Celsius, mm and km/h by Europe/Zurich day', () {
    final forecast = MeteoSwissForecastParser.parsePayload(
      _payload(
        points: [
          _point('2026-09-12T10:00:00Z', temperature: 12, rain: .2, gust: 18),
          _point('2026-09-12T11:00:00Z', temperature: 18, rain: null, gust: 25),
          _point('2026-09-13T10:00:00Z', temperature: 20, rain: 1.5, gust: 30),
        ],
      ),
    );

    final days = MeteoSwissForecastAggregation.aggregate(
      forecast,
      nowUtc: DateTime.utc(2026, 9, 12, 9),
    );
    expect(days, hasLength(2));
    expect(days.first.temperatureMinimumCelsius, 12);
    expect(days.first.temperatureMaximumCelsius, 18);
    expect(days.first.precipitationMillimeters, .2);
    expect(days.first.maximumGustKilometersPerHour, 25);
    expect(days.first.windDirectionAbbreviation, 'SW');
  });

  test(
    'uses Europe/Zurich calendar boundaries across daylight saving time',
    () {
      final forecast = MeteoSwissForecastParser.parsePayload(
        _payload(
          points: [
            _point('2026-03-29T21:00:00Z'),
            _point('2026-03-29T22:00:00Z'),
          ],
        ),
      );
      final days = MeteoSwissForecastAggregation.aggregate(
        forecast,
        nowUtc: DateTime.utc(2026, 3, 28),
      );
      expect(days.map((day) => day.localDate), [
        DateTime(2026, 3, 29),
        DateTime(2026, 3, 30),
      ]);
    },
  );

  test('keeps today limited to still future forecast points', () {
    final forecast = MeteoSwissForecastParser.parsePayload(
      _payload(
        points: [
          _point('2026-09-12T08:00:00Z', temperature: 2),
          _point('2026-09-12T16:00:00Z', temperature: 20),
        ],
      ),
    );
    final day = MeteoSwissForecastAggregation.aggregate(
      forecast,
      nowUtc: DateTime.utc(2026, 9, 12, 12),
    ).single;
    expect(day.temperatureMinimumCelsius, 20);
    expect(day.temperatureMaximumCelsius, 20);
  });

  test('uses only documented MeteoSwiss weather-symbol descriptions', () {
    expect(MeteoSwissWeatherSymbols.germanDescription(1), 'sonnig');
    expect(MeteoSwissWeatherSymbols.germanDescription(28), 'Nebel');
    expect(MeteoSwissWeatherSymbols.germanDescription(101), 'klar');
    expect(
      MeteoSwissWeatherSymbols.germanDescription(142),
      'stark bewölkt, Gewitter und häufige Schneeschauer',
    );
    expect(MeteoSwissWeatherSymbols.germanDescription(0), isNull);
    expect(MeteoSwissWeatherSymbols.germanDescription(999), isNull);
  });

  test('maps wind direction with exact 22.5 degree sectors', () {
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(0), 'N');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(45), 'NO');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(90), 'O');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(135), 'SO');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(180), 'S');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(225), 'SW');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(270), 'W');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(315), 'NW');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(359), 'N');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(22.49), 'N');
    expect(MeteoSwissForecastAggregation.windDirectionAbbreviation(22.5), 'NO');
  });

  test(
    'rejects another MeteoSwiss point and surfaces network failures',
    () async {
      final wrong = _payload(points: const [])
        ..['station'] = {
          ..._payload()['station'] as Map<String, dynamic>,
          'pointId': '1',
        };
      expect(
        () => MeteoSwissForecastParser.parsePayload(wrong),
        throwsFormatException,
      );
      final service = MeteoSwissForecastService(
        client: MockClient((_) async => http.Response('unavailable', 502)),
      );
      expect(service.load(), throwsA(isA<MeteoSwissForecastException>()));
    },
  );
}

Map<String, dynamic> _payload({List<Map<String, dynamic>> points = const []}) =>
    {
      'station': {
        'pointId': '859000',
        'pointTypeId': '2',
        'postalCode': '8590',
        'name': 'Romanshorn',
        'latitude': 47.566578,
        'longitude': 9.370531,
        'elevationMeters': 412,
      },
      'updatedAtUtc': '2026-09-12T05:00:00Z',
      'runAtUtc': '2026-09-12T05:00:00Z',
      'points': points,
    };

Map<String, dynamic> _point(
  String timestamp, {
  double? temperature = 15,
  double? rain = 0,
  double? gust = 16,
}) => {
  'timestampUtc': timestamp,
  'temperatureCelsius': temperature,
  'precipitationMillimeters': rain,
  'windKilometersPerHour': 11.2,
  'gustKilometersPerHour': gust,
  'windDirectionDegrees': 225,
  'weatherCode': 2,
};
