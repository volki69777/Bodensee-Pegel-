import 'package:bodensee_pegel/activity_rating_service.dart';
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

    test('creates three complete intervals for a future local day', () {
      final now = _berlinUtc(2026, 9, 14, 10, 37);
      final today = ActivityTimeWindowAggregation.scheduleForDay(
        selectedDate: DateTime(2026, 9, 14),
        nowUtc: now,
        location: ActivityTimeWindowAggregation.berlin,
      );
      final tomorrow = ActivityTimeWindowAggregation.scheduleForDay(
        selectedDate: DateTime(2026, 9, 15),
        nowUtc: now,
        location: ActivityTimeWindowAggregation.berlin,
      );
      final yesterday = ActivityTimeWindowAggregation.scheduleForDay(
        selectedDate: DateTime(2026, 9, 13),
        nowUtc: now,
        location: ActivityTimeWindowAggregation.berlin,
      );

      expect(today.map((window) => window.label), [
        'Jetzt–12',
        'Nachmittag 12–18',
        'Abend 18–22',
      ]);
      expect(tomorrow.map((window) => window.label), [
        'Morgen 06–12',
        'Nachmittag 12–18',
        'Abend 18–22',
      ]);
      expect(tomorrow.map((window) => window.expectedHourlyPointCount), [
        6,
        6,
        4,
      ]);
      expect(yesterday, isEmpty);
    });

    test('uses the selected future local day across summer time', () {
      final location = ActivityTimeWindowAggregation.zurich;
      final tomorrow = ActivityTimeWindowAggregation.scheduleForDay(
        selectedDate: DateTime(2026, 3, 30),
        nowUtc: tz.TZDateTime(location, 2026, 3, 29, 10).toUtc(),
        location: location,
      );

      final morningStart = tz.TZDateTime.from(
        tomorrow.first.startUtc,
        location,
      );
      final morningEnd = tz.TZDateTime.from(tomorrow.first.endUtc, location);
      expect(morningStart, tz.TZDateTime(location, 2026, 3, 30, 6));
      expect(morningEnd, tz.TZDateTime(location, 2026, 3, 30, 12));
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

    test('requires all original hourly points for a future rating', () {
      final window = _window('Morgen 06–12', 6, 12);
      List<ActivityTimeWindowPoint> hourlyPoints(int count) => List.generate(
        count,
        (index) => _point(
          _berlinUtc(2026, 9, 14, 6 + index),
          temperature: 18,
          rain: 0,
          wind: 10,
          gust: 16,
        ),
      );

      final complete = ActivityTimeWindowAggregation.aggregate(
        points: hourlyPoints(6),
        windows: [window],
      ).single;
      final partial = ActivityTimeWindowAggregation.aggregate(
        points: hourlyPoints(5),
        windows: [window],
      ).single;

      expect(complete.hasForecastPoints, isTrue);
      expect(complete.hasCompleteHourlyCoverage, isTrue);
      expect(partial.hasForecastPoints, isTrue);
      expect(partial.hasCompleteHourlyCoverage, isFalse);
    });

    test('does not turn missing values into a future-day rating', () {
      final window = _window('Morgen 06–12', 6, 12);
      final forecast = ActivityTimeWindowAggregation.aggregate(
        points: List.generate(
          6,
          (index) => _point(_berlinUtc(2026, 9, 14, 6 + index)),
        ),
        windows: [window],
      ).single;
      final rating = ActivityRatingService.rate(
        activityId: 'sup_kajak',
        data: ActivityForecastData(
          temperatureMaximumCelsius: forecast.temperatureMaximumCelsius,
          precipitationMillimeters: forecast.precipitationMillimeters,
          windKilometersPerHour: forecast.representativeWindKilometersPerHour,
          gustKilometersPerHour: forecast.maximumGustKilometersPerHour,
        ),
      );

      expect(forecast.hasCompleteHourlyCoverage, isTrue);
      expect(rating.level, ActivityRatingLevel.unavailable);
      expect(rating.score, isNull);
    });
  });

  group('ActivityTimeWindowRecommendations.best', () {
    test('selects the unique highest existing score', () {
      final morning = _window('Vormittag 06–12', 6, 12);
      final afternoon = _window('Nachmittag 12–18', 12, 18);
      final result = ActivityTimeWindowRecommendations.best({
        morning: _rating(ActivityRatingLevel.good, 7.2),
        afternoon: _rating(ActivityRatingLevel.veryGood, 8.6),
      });

      expect(result?.window, afternoon);
      expect(result?.rating.score, 8.6);
    });

    test('keeps the earlier window when scores are equal', () {
      final morning = _window('Vormittag 06–12', 6, 12);
      final afternoon = _window('Nachmittag 12–18', 12, 18);
      final result = ActivityTimeWindowRecommendations.best({
        afternoon: _rating(ActivityRatingLevel.good, 7.4),
        morning: _rating(ActivityRatingLevel.good, 7.4),
      });

      expect(result?.window, morning);
    });

    test('does not recommend unavailable or absent time windows', () {
      final morning = _window('Vormittag 06–12', 6, 12);
      expect(
        ActivityTimeWindowRecommendations.best({
          morning: const ActivityRating(
            ActivityRatingLevel.unavailable,
            'Nicht genügend Wetterdaten verfügbar',
          ),
        }),
        isNull,
      );
      expect(ActivityTimeWindowRecommendations.best(const {}), isNull);
    });

    test(
      'uses the existing motorboat profile ratings without recalculation',
      () {
        final current = _window('Jetzt–12', 10, 12);
        final afternoon = _window('Nachmittag 12–18', 12, 18);
        ActivityRating rating(MotorboatRatingProfile profile, double wind) =>
            ActivityRatingService.rate(
              activityId: 'motorboot',
              data: ActivityForecastData(
                windKilometersPerHour: wind,
                gustKilometersPerHour: wind + 8,
                precipitationMillimeters: 0,
                motorboatProfile: profile,
              ),
            );
        double maximumScore(Map<ActivityTimeWindow, ActivityRating> ratings) =>
            ratings.values
                .map((rating) => rating.score)
                .whereType<double>()
                .reduce((left, right) => left > right ? left : right);

        for (final profile in MotorboatRatingProfile.values) {
          final ratings = {
            current: rating(profile, 20),
            afternoon: rating(profile, 10),
          };
          expect(
            ActivityTimeWindowRecommendations.best(ratings)?.rating.score,
            maximumScore(ratings),
          );
        }
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

ActivityTimeWindow _window(String label, int startHour, int endHour) =>
    ActivityTimeWindow(
      label: label,
      startUtc: _berlinUtc(2026, 9, 14, startHour),
      endUtc: _berlinUtc(2026, 9, 14, endHour),
      isCurrent: false,
    );

ActivityRating _rating(ActivityRatingLevel level, double score) =>
    ActivityRating(level, 'Fixture', score: score);
