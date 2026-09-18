import 'package:bodensee_pegel/activity_time_window_service.dart';
import 'package:bodensee_pegel/dwd_forecast_service.dart';
import 'package:bodensee_pegel/geosphere_forecast_service.dart';
import 'package:bodensee_pegel/meteoswiss_forecast_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  group('ActivityTimeWindowAggregation.schedule', () {
    test('uses the requested local labels and half-open boundaries', () {
      expect(_labelsAt(2026, 9, 14, 5, 59), [
        'Vormittag 06–12',
        'Nachmittag 12–18',
        'Abend 18–22',
      ]);
      expect(_labelsAt(2026, 9, 14, 6), [
        'Jetzt–12',
        'Nachmittag 12–18',
        'Abend 18–22',
      ]);
      expect(_labelsAt(2026, 9, 14, 10, 37), [
        'Jetzt–12',
        'Nachmittag 12–18',
        'Abend 18–22',
      ]);
      expect(_labelsAt(2026, 9, 14, 12), ['Jetzt–18', 'Abend 18–22']);
      expect(_labelsAt(2026, 9, 14, 14, 30), ['Jetzt–18', 'Abend 18–22']);
      expect(_labelsAt(2026, 9, 14, 18), ['Jetzt–22']);
      expect(_labelsAt(2026, 9, 14, 19, 30), ['Jetzt–22']);
      expect(_labelsAt(2026, 9, 14, 22), isEmpty);
    });

    test('uses local time zones including a summer-time date', () {
      final berlinNow = tz.TZDateTime(
        ActivityTimeWindowAggregation.berlin,
        2026,
        3,
        29,
        10,
      ).toUtc();
      final zurichNow = tz.TZDateTime(
        ActivityTimeWindowAggregation.zurich,
        2026,
        3,
        29,
        10,
      ).toUtc();
      final viennaNow = tz.TZDateTime(
        ActivityTimeWindowAggregation.vienna,
        2026,
        3,
        29,
        10,
      ).toUtc();
      for (final entry in [
        (berlinNow, ActivityTimeWindowAggregation.berlin),
        (zurichNow, ActivityTimeWindowAggregation.zurich),
        (viennaNow, ActivityTimeWindowAggregation.vienna),
      ]) {
        final windows = ActivityTimeWindowAggregation.schedule(
          nowUtc: entry.$1,
          location: entry.$2,
        );
        expect(windows.first.label, 'Jetzt–12');
        expect(windows.first.isCurrent, isTrue);
      }
    });
  });

  group('ActivityTimeWindowAggregation.aggregate', () {
    test('excludes elapsed points and does not double count boundaries', () {
      final now = _berlinUtc(2026, 9, 14, 10, 37);
      final windows = ActivityTimeWindowAggregation.schedule(
        nowUtc: now,
        location: ActivityTimeWindowAggregation.berlin,
      );
      final points = [
        _point(_berlinUtc(2026, 9, 14, 10), temperature: 10),
        _point(_berlinUtc(2026, 9, 14, 11), temperature: 11),
        _point(_berlinUtc(2026, 9, 14, 12), temperature: 12),
        _point(_berlinUtc(2026, 9, 14, 18), temperature: 18),
      ];
      final results = ActivityTimeWindowAggregation.aggregate(
        points: points,
        windows: windows,
      );
      expect(results[0].points.map((point) => point.temperatureCelsius), [11]);
      expect(results[1].points.map((point) => point.temperatureCelsius), [12]);
      expect(results[2].points.map((point) => point.temperatureCelsius), [18]);
    });

    test(
      'aggregates actual values and leaves wholly missing rain unavailable',
      () {
        final window = ActivityTimeWindow(
          label: 'Vormittag 06–12',
          startUtc: _berlinUtc(2026, 9, 14, 6),
          endUtc: _berlinUtc(2026, 9, 14, 12),
          isCurrent: false,
        );
        final result = ActivityTimeWindowAggregation.aggregate(
          windows: [window],
          points: [
            _point(
              _berlinUtc(2026, 9, 14, 7),
              temperature: 9,
              rain: .2,
              wind: 5,
              direction: 90,
              gust: 11,
            ),
            _point(
              _berlinUtc(2026, 9, 14, 9),
              temperature: 12,
              wind: 9,
              direction: 180,
              gust: 19,
            ),
            _point(
              _berlinUtc(2026, 9, 14, 11),
              temperature: 10,
              rain: .4,
              wind: 12,
              direction: 270,
              gust: 15,
            ),
          ],
        ).single;
        expect(result.temperatureMinimumCelsius, 9);
        expect(result.temperatureMaximumCelsius, 12);
        expect(result.precipitationMillimeters, closeTo(.6, .0001));
        // The midpoint is 09:00; speed and direction come from that same point.
        expect(result.representativeWindKilometersPerHour, 9);
        expect(result.windDirectionDegrees, 180);
        expect(result.maximumGustKilometersPerHour, 19);

        final noRain = ActivityTimeWindowAggregation.aggregate(
          windows: [window],
          points: [_point(_berlinUtc(2026, 9, 14, 9), wind: 8)],
        ).single;
        expect(noRain.precipitationMillimeters, isNull);
        expect(
          ActivityTimeWindowAggregation.withForecastPoints([noRain]),
          contains(noRain),
        );
      },
    );

    test('adapts DWD, MeteoSwiss and GeoSphere original points', () {
      final timestamp = DateTime.utc(2026, 9, 14, 10);
      final dwd = ActivityTimeWindowPoint.fromDwd(
        DwdForecastPoint(
          timestampUtc: timestamp,
          temperatureKelvin: 293.15,
          windMetersPerSecond: 2,
          gustMetersPerSecond: 3,
          precipitationMillimeters: .5,
          windDirectionDegrees: 90,
          weatherCode: 61,
        ),
      );
      expect(dwd.temperatureCelsius, closeTo(20, .001));
      expect(dwd.windKilometersPerHour, closeTo(7.2, .001));
      expect(dwd.weatherLabel, 'Regen');

      final meteo = ActivityTimeWindowPoint.fromMeteoSwiss(
        MeteoSwissForecastPoint(
          timestampUtc: timestamp,
          temperatureCelsius: 18,
          windKilometersPerHour: 7,
          gustKilometersPerHour: 13,
          precipitationMillimeters: .2,
          weatherCode: 1,
        ),
      );
      expect(meteo.weatherLabel, 'sonnig');

      final geo = ActivityTimeWindowPoint.fromGeoSphere(
        GeoSphereForecastPoint(
          timestampUtc: timestamp,
          temperatureCelsius: 17,
          windEastwardMetersPerSecond: 0,
          windNorthwardMetersPerSecond: -2,
          gustMetersPerSecond: 4,
          precipitationKilogramsPerSquareMeter: .3,
          weatherSymbolCode: 1,
        ),
      );
      expect(geo.windKilometersPerHour, closeTo(7.2, .001));
      expect(geo.precipitationMillimeters, .3);
      expect(geo.weatherLabel, isNull);
    });

    test(
      'returns an empty interval for a GeoSphere horizon with no points',
      () {
        final window = ActivityTimeWindow(
          label: 'Abend 18–22',
          startUtc: DateTime.utc(2026, 9, 14, 16),
          endUtc: DateTime.utc(2026, 9, 14, 20),
          isCurrent: false,
        );
        final result = ActivityTimeWindowAggregation.aggregate(
          points: const [],
          windows: [window],
        ).single;
        expect(result.hasForecastPoints, isFalse);
        expect(result.temperatureMaximumCelsius, isNull);
        expect(
          ActivityTimeWindowAggregation.withForecastPoints([result]),
          isEmpty,
        );
      },
    );
  });
}

List<String> _labelsAt(
  int year,
  int month,
  int day,
  int hour, [
  int minute = 0,
]) {
  final now = _berlinUtc(year, month, day, hour, minute);
  return ActivityTimeWindowAggregation.schedule(
    nowUtc: now,
    location: ActivityTimeWindowAggregation.berlin,
  ).map((window) => window.label).toList();
}

DateTime _berlinUtc(int year, int month, int day, int hour, [int minute = 0]) =>
    tz.TZDateTime(
      ActivityTimeWindowAggregation.berlin,
      year,
      month,
      day,
      hour,
      minute,
    ).toUtc();

ActivityTimeWindowPoint _point(
  DateTime timestamp, {
  double? temperature,
  double? rain,
  double? wind,
  double? gust,
  double? direction,
}) => ActivityTimeWindowPoint(
  timestampUtc: timestamp,
  temperatureCelsius: temperature,
  precipitationMillimeters: rain,
  windKilometersPerHour: wind,
  gustKilometersPerHour: gust,
  windDirectionDegrees: direction,
);
