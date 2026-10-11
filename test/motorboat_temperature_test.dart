import 'dart:math' as math;

import 'package:bodensee_pegel/activity_rating_service.dart';
import 'package:bodensee_pegel/activity_time_window_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  ActivityRating rate(
    MotorboatRatingProfile? profile,
    double? temperature, {
    double wind = 5,
    double gust = 10,
    double rain = 0,
  }) => ActivityRatingService.rate(
    activityId: 'motorboot',
    data: ActivityForecastData(
      temperatureMinimumCelsius: -5,
      temperatureMaximumCelsius: temperature,
      windKilometersPerHour: wind,
      gustKilometersPerHour: gust,
      precipitationMillimeters: rain,
      motorboatProfile: profile,
    ),
  );

  for (final profile in [null, ...MotorboatRatingProfile.values]) {
    group('motorboat temperature cap $profile', () {
      for (final (temperature, cap, level) in [
        (-5.0, 3.0, ActivityRatingLevel.unsuitable),
        (0.0, 3.0, ActivityRatingLevel.unsuitable),
        (9.999, 3.0, ActivityRatingLevel.unsuitable),
        (10.0, 4.0, ActivityRatingLevel.limited),
        (10.001, 4.0, ActivityRatingLevel.limited),
        (14.999, 4.0, ActivityRatingLevel.limited),
        (15.0, 5.9, ActivityRatingLevel.limited),
        (15.001, 5.9, ActivityRatingLevel.limited),
        (17.999, 5.9, ActivityRatingLevel.limited),
        (18.0, 7.9, ActivityRatingLevel.good),
        (18.001, 7.9, ActivityRatingLevel.good),
        (20.999, 7.9, ActivityRatingLevel.good),
        (21.0, 10.0, ActivityRatingLevel.veryGood),
        (21.001, 10.0, ActivityRatingLevel.veryGood),
      ]) {
        test('$temperature Celsius caps at $cap with matching category', () {
          final result = rate(profile, temperature);
          expect(result.score, cap);
          expect(result.level, level);
          expect(result.reason.contains('Niedrige Lufttemperatur'), cap < 10);
        });
      }

      test('missing maximum does not use the minimum or zero', () {
        final missing = rate(profile, null);
        final warm = rate(profile, 21);
        expect(missing.score, warm.score);
        expect(missing.level, warm.level);
        expect(missing.reason, warm.reason);
      });

      test('wind, gusts and rain can still produce a lower score', () {
        for (final (wind, gust, rain) in [
          (60.0, 65.0, 0.0),
          (5.0, 80.0, 0.0),
          (5.0, 10.0, 8.0),
        ]) {
          final original = rate(
            profile,
            null,
            wind: wind,
            gust: gust,
            rain: rain,
          );
          for (final (temperature, cap) in [
            (9.0, 3.0),
            (16.0, 5.9),
            (19.0, 7.9),
            (21.0, 10.0),
          ]) {
            final result = rate(
              profile,
              temperature,
              wind: wind,
              gust: gust,
              rain: rain,
            );
            expect(result.score, math.min(original.score!, cap));
            if (original.score! <= cap) {
              expect(result.level, original.level);
              expect(result.reason, original.reason);
            } else {
              expect(result.reason, contains(original.reason));
            }
          }
        }
      });

      test('does not invent a score when wind data is missing', () {
        final result = ActivityRatingService.rate(
          activityId: 'motorboot',
          data: ActivityForecastData(
            temperatureMaximumCelsius: 5,
            motorboatProfile: profile,
          ),
        );
        expect(result.level, ActivityRatingLevel.unavailable);
        expect(result.score, isNull);
      });

      test(
        'uses each time window temperature instead of the daily maximum',
        () {
          final location = ActivityTimeWindowAggregation.berlin;
          final date = DateTime(2026, 10, 12);
          final windows = ActivityTimeWindowAggregation.scheduleForDay(
            selectedDate: date,
            nowUtc: DateTime.utc(2026, 10, 11),
            location: location,
          );
          final points = [
            for (var hour = 6; hour < 22; hour++)
              ActivityTimeWindowPoint(
                timestampUtc: tz.TZDateTime(
                  location,
                  2026,
                  10,
                  12,
                  hour,
                ).toUtc(),
                temperatureCelsius: hour < 12
                    ? 9
                    : hour < 18
                    ? 22
                    : 16,
                windKilometersPerHour: 5,
                gustKilometersPerHour: 10,
                precipitationMillimeters: 0,
              ),
          ];
          final forecasts = ActivityTimeWindowAggregation.aggregate(
            points: points,
            windows: windows,
          );
          final scores = [
            for (final forecast in forecasts)
              ActivityRatingService.rate(
                activityId: 'motorboot',
                data: ActivityForecastData(
                  temperatureMinimumCelsius: forecast.temperatureMinimumCelsius,
                  temperatureMaximumCelsius: forecast.temperatureMaximumCelsius,
                  windKilometersPerHour:
                      forecast.representativeWindKilometersPerHour,
                  gustKilometersPerHour: forecast.maximumGustKilometersPerHour,
                  precipitationMillimeters: forecast.precipitationMillimeters,
                  motorboatProfile: profile,
                ),
              ).score,
          ];
          expect(scores, [3.0, 10.0, 5.9]);
          expect(rate(profile, 22).score, 10);
        },
      );
    });
  }
}
