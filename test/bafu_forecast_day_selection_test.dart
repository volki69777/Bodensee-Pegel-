import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.Location zurich;

  setUpAll(() {
    timezone_data.initializeTimeZones();
    zurich = tz.getLocation('Europe/Zurich');
  });

  BafuForecastPoint point(DateTime timestamp, double median) =>
      BafuForecastPoint(
        timestamp: timestamp,
        medianMasl: median,
        minimumMasl: median - .1,
        maximumMasl: median + .1,
      );

  test('selects the future point nearest noon for today', () {
    final day = tz.TZDateTime(zurich, 2026, 9, 13);
    final forecast = BafuForecastData(
      points: [
        point(tz.TZDateTime(zurich, 2026, 9, 13, 11, 0).toUtc(), 394.8),
        point(tz.TZDateTime(zurich, 2026, 9, 13, 12, 15).toUtc(), 394.9),
        point(tz.TZDateTime(zurich, 2026, 9, 13, 13, 0).toUtc(), 395.0),
      ],
    );

    final selected = BafuForecastDaySelection.representativePoint(
      forecast: forecast,
      localDate: day,
      nowUtc: tz.TZDateTime(zurich, 2026, 9, 13, 11, 30).toUtc(),
    );

    expect(selected?.medianMasl, 394.9);
  });

  test('selects the next future point after noon for today', () {
    final day = tz.TZDateTime(zurich, 2026, 9, 13);
    final forecast = BafuForecastData(
      points: [
        point(tz.TZDateTime(zurich, 2026, 9, 13, 12, 0).toUtc(), 394.8),
        point(tz.TZDateTime(zurich, 2026, 9, 13, 15, 0).toUtc(), 394.9),
        point(tz.TZDateTime(zurich, 2026, 9, 13, 16, 0).toUtc(), 395.0),
      ],
    );

    final selected = BafuForecastDaySelection.representativePoint(
      forecast: forecast,
      localDate: day,
      nowUtc: tz.TZDateTime(zurich, 2026, 9, 13, 14, 15).toUtc(),
    );

    expect(selected?.medianMasl, 394.9);
  });

  test('selects the point nearest noon for a future day', () {
    final day = tz.TZDateTime(zurich, 2026, 9, 14);
    final forecast = BafuForecastData(
      points: [
        point(tz.TZDateTime(zurich, 2026, 9, 14, 9).toUtc(), 394.8),
        point(tz.TZDateTime(zurich, 2026, 9, 14, 12).toUtc(), 394.9),
        point(tz.TZDateTime(zurich, 2026, 9, 14, 15).toUtc(), 395.0),
      ],
    );

    final selected = BafuForecastDaySelection.representativePoint(
      forecast: forecast,
      localDate: day,
      nowUtc: tz.TZDateTime(zurich, 2026, 9, 13, 10).toUtc(),
    );

    expect(selected?.medianMasl, 394.9);
  });

  test('returns null outside the official forecast horizon', () {
    final forecast = BafuForecastData(points: const []);

    expect(
      BafuForecastDaySelection.representativePoint(
        forecast: forecast,
        localDate: tz.TZDateTime(zurich, 2026, 9, 20),
        nowUtc: tz.TZDateTime(zurich, 2026, 9, 13).toUtc(),
      ),
      isNull,
    );
  });

  test(
    'converts the official absolute value with the Romanshorn reference',
    () {
      final forecastPoint = point(DateTime.utc(2026, 9, 14, 10), 394.89);

      expect(
        BafuForecastDaySelection.medianLevelCentimeters(forecastPoint),
        closeTo(266, .0001),
      );
    },
  );
}
