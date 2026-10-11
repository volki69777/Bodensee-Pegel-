import 'dart:math' as math;

import 'activity_rating_service.dart';

import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import 'dwd_forecast_service.dart';
import 'geosphere_forecast_service.dart';
import 'meteoswiss_forecast_service.dart';

/// A future-facing local time interval for the HEUTE activity planner.
///
/// Intervals are half-open: [startUtc, endUtc). For a currently running
/// interval, [startUtc] is the actual current instant, so elapsed hourly
/// forecast points cannot enter the assessment.
class ActivityTimeWindow {
  const ActivityTimeWindow({
    required this.label,
    required this.startUtc,
    required this.endUtc,
    required this.isCurrent,
  });

  final String label;
  final DateTime startUtc;
  final DateTime endUtc;
  final bool isCurrent;

  /// Number of hourly source points required for a fully covered window.
  /// Current partial-day windows do not use this value for rating eligibility.
  int get expectedHourlyPointCount => endUtc.difference(startUtc).inHours;
}

/// A source-independent view of one original hourly forecast point.
/// No values are interpolated or substituted here.
class ActivityTimeWindowPoint {
  const ActivityTimeWindowPoint({
    required this.timestampUtc,
    this.temperatureCelsius,
    this.precipitationMillimeters,
    this.windKilometersPerHour,
    this.gustKilometersPerHour,
    this.windDirectionDegrees,
    this.weatherLabel,
  });

  factory ActivityTimeWindowPoint.fromDwd(DwdForecastPoint point) =>
      ActivityTimeWindowPoint(
        timestampUtc: point.timestampUtc,
        temperatureCelsius: point.temperatureCelsius,
        precipitationMillimeters: point.precipitationMillimeters,
        windKilometersPerHour: point.windKilometersPerHour,
        gustKilometersPerHour: point.gustKilometersPerHour,
        windDirectionDegrees: point.windDirectionDegrees,
        weatherLabel: DwdMosmixAggregation.weatherLabel(point.weatherCode),
      );

  factory ActivityTimeWindowPoint.fromMeteoSwiss(
    MeteoSwissForecastPoint point,
  ) => ActivityTimeWindowPoint(
    timestampUtc: point.timestampUtc,
    temperatureCelsius: point.temperatureCelsius,
    precipitationMillimeters: point.precipitationMillimeters,
    windKilometersPerHour: point.windKilometersPerHour,
    gustKilometersPerHour: point.gustKilometersPerHour,
    windDirectionDegrees: point.windDirectionDegrees,
    weatherLabel: MeteoSwissWeatherSymbols.germanDescription(point.weatherCode),
  );

  factory ActivityTimeWindowPoint.fromGeoSphere(GeoSphereForecastPoint point) =>
      ActivityTimeWindowPoint(
        timestampUtc: point.timestampUtc,
        temperatureCelsius: point.temperatureCelsius,
        precipitationMillimeters: point.precipitationMillimeters,
        windKilometersPerHour: point.windKilometersPerHour,
        gustKilometersPerHour: point.gustKilometersPerHour,
        windDirectionDegrees: point.meteorologicalWindDirectionDegrees,
        // GeoSphere `sy` deliberately remains unavailable until the provider's
        // code-to-text mapping is officially documented.
      );

  final DateTime timestampUtc;
  final double? temperatureCelsius;
  final double? precipitationMillimeters;
  final double? windKilometersPerHour;
  final double? gustKilometersPerHour;
  final double? windDirectionDegrees;
  final String? weatherLabel;
}

/// Aggregated source values for one [ActivityTimeWindow].
class ActivityTimeWindowForecast {
  const ActivityTimeWindowForecast({
    required this.window,
    required this.points,
    this.temperatureMinimumCelsius,
    this.temperatureMaximumCelsius,
    this.precipitationMillimeters,
    this.representativeWindKilometersPerHour,
    this.maximumGustKilometersPerHour,
    this.windDirectionDegrees,
    this.weatherLabel,
  });

  final ActivityTimeWindow window;
  final List<ActivityTimeWindowPoint> points;
  final double? temperatureMinimumCelsius;
  final double? temperatureMaximumCelsius;
  final double? precipitationMillimeters;
  final double? representativeWindKilometersPerHour;
  final double? maximumGustKilometersPerHour;
  final double? windDirectionDegrees;
  final String? weatherLabel;

  bool get hasForecastPoints => points.isNotEmpty;

  /// Future windows are considered rateable only when each expected hourly
  /// source point is present. This intentionally checks availability of
  /// original points, not whether every optional weather parameter exists.
  bool get hasCompleteHourlyCoverage {
    final expected = window.expectedHourlyPointCount;
    if (expected == 0) return hasForecastPoints;
    final actualTimestamps = points
        .map((point) => point.timestampUtc.toUtc().millisecondsSinceEpoch)
        .toSet();
    return Iterable<int>.generate(
      expected,
      (hour) =>
          window.startUtc.add(Duration(hours: hour)).millisecondsSinceEpoch,
    ).every(actualTimestamps.contains);
  }
}

/// The best existing time-window result for one activity.
///
/// This is selection only: it never recalculates an activity score or turns
/// unavailable weather data into a rating. Equal scores deliberately keep the
/// chronologically earlier local window.
class ActivityTimeWindowRecommendation {
  const ActivityTimeWindowRecommendation({
    required this.window,
    required this.rating,
  });

  final ActivityTimeWindow window;
  final ActivityRating rating;
}

abstract final class ActivityTimeWindowRecommendations {
  static ActivityTimeWindowRecommendation? best(
    Map<ActivityTimeWindow, ActivityRating> ratings,
  ) {
    final candidates = ratings.entries
        .where((entry) => entry.value.score != null)
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      final scoreOrder = right.value.score!.compareTo(left.value.score!);
      if (scoreOrder != 0) return scoreOrder;
      return left.key.startUtc.compareTo(right.key.startUtc);
    });
    final best = candidates.first;
    return ActivityTimeWindowRecommendation(
      window: best.key,
      rating: best.value,
    );
  }
}

/// Creates the upcoming local intervals and aggregates existing hourly data.
abstract final class ActivityTimeWindowAggregation {
  static final tz.Location berlin = _location('Europe/Berlin');
  static final tz.Location zurich = _location('Europe/Zurich');
  static final tz.Location vienna = _location('Europe/Vienna');

  static tz.Location _location(String name) {
    timezone_data.initializeTimeZones();
    return tz.getLocation(name);
  }

  static List<ActivityTimeWindow> schedule({
    required DateTime nowUtc,
    required tz.Location location,
  }) {
    final now = nowUtc.toUtc();
    final localNow = tz.TZDateTime.from(now, location);
    tz.TZDateTime boundary(int hour) => tz.TZDateTime(
      location,
      localNow.year,
      localNow.month,
      localNow.day,
      hour,
    );
    ActivityTimeWindow future(String label, int startHour, int endHour) =>
        ActivityTimeWindow(
          label: label,
          startUtc: boundary(startHour).toUtc(),
          endUtc: boundary(endHour).toUtc(),
          isCurrent: false,
        );
    ActivityTimeWindow current(String label, int endHour) => ActivityTimeWindow(
      label: label,
      startUtc: now,
      endUtc: boundary(endHour).toUtc(),
      isCurrent: true,
    );

    final hour = localNow.hour;
    if (hour < 6) {
      return [
        future('Vormittag 06–12', 6, 12),
        future('Nachmittag 12–18', 12, 18),
        future('Abend 18–22', 18, 22),
      ];
    }
    if (hour < 12) {
      return [
        current('Jetzt–12', 12),
        future('Nachmittag 12–18', 12, 18),
        future('Abend 18–22', 18, 22),
      ];
    }
    if (hour < 18) {
      return [current('Jetzt–18', 18), future('Abend 18–22', 18, 22)];
    }
    if (hour < 22) return [current('Jetzt–22', 22)];
    return const [];
  }

  /// Returns only intervals that can still be shown for [selectedDate].
  ///
  /// Today keeps the established future-facing schedule. A later local day
  /// uses its three complete daytime intervals; past days have no intervals.
  static List<ActivityTimeWindow> scheduleForDay({
    required DateTime selectedDate,
    required DateTime nowUtc,
    required tz.Location location,
  }) {
    final now = nowUtc.toUtc();
    final localNow = tz.TZDateTime.from(now, location);
    final selectedLocalDay = tz.TZDateTime(
      location,
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );
    final currentLocalDay = tz.TZDateTime(
      location,
      localNow.year,
      localNow.month,
      localNow.day,
    );
    if (selectedLocalDay.isBefore(currentLocalDay)) return const [];
    if (selectedLocalDay == currentLocalDay) {
      return schedule(nowUtc: now, location: location);
    }

    ActivityTimeWindow future(String label, int startHour, int endHour) =>
        ActivityTimeWindow(
          label: label,
          startUtc: tz.TZDateTime(
            location,
            selectedDate.year,
            selectedDate.month,
            selectedDate.day,
            startHour,
          ).toUtc(),
          endUtc: tz.TZDateTime(
            location,
            selectedDate.year,
            selectedDate.month,
            selectedDate.day,
            endHour,
          ).toUtc(),
          isCurrent: false,
        );
    return [
      future('Morgen 06–12', 6, 12),
      future('Nachmittag 12–18', 12, 18),
      future('Abend 18–22', 18, 22),
    ];
  }

  static List<ActivityTimeWindowForecast> aggregate({
    required Iterable<ActivityTimeWindowPoint> points,
    required Iterable<ActivityTimeWindow> windows,
  }) => windows.map((window) => _aggregate(window, points)).toList();

  /// A time-window chip is useful only when at least one original forecast
  /// point falls within it. Individual missing parameters remain visible as
  /// “–” per activity and are intentionally not filtered here.
  static Iterable<ActivityTimeWindowForecast> withForecastPoints(
    Iterable<ActivityTimeWindowForecast> forecasts,
  ) => forecasts.where((forecast) => forecast.hasForecastPoints);

  static ActivityTimeWindowForecast _aggregate(
    ActivityTimeWindow window,
    Iterable<ActivityTimeWindowPoint> allPoints,
  ) {
    final points = allPoints
        .where(
          (point) =>
              !point.timestampUtc.isBefore(window.startUtc) &&
              point.timestampUtc.isBefore(window.endUtc),
        )
        .toList(growable: false);
    List<double> values(double? Function(ActivityTimeWindowPoint point) pick) =>
        points.map(pick).whereType<double>().toList(growable: false);
    final temperatures = values((point) => point.temperatureCelsius);
    final precipitation = values((point) => point.precipitationMillimeters);
    final gusts = values((point) => point.gustKilometersPerHour);
    final representative = _nearestToMidpoint(
      points.where((point) => point.windKilometersPerHour != null),
      window,
    );
    final weather = _nearestToMidpoint(
      points.where((point) => point.weatherLabel != null),
      window,
    );
    return ActivityTimeWindowForecast(
      window: window,
      points: List.unmodifiable(points),
      temperatureMinimumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce(math.min),
      temperatureMaximumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce(math.max),
      // A missing hourly precipitation value is not a dry hour. A sum is
      // shown only if at least one actual provider value exists.
      precipitationMillimeters: precipitation.isEmpty
          ? null
          : precipitation.reduce((left, right) => left + right),
      representativeWindKilometersPerHour:
          representative?.windKilometersPerHour,
      windDirectionDegrees: representative?.windDirectionDegrees,
      maximumGustKilometersPerHour: gusts.isEmpty
          ? null
          : gusts.reduce(math.max),
      weatherLabel: weather?.weatherLabel,
    );
  }

  static ActivityTimeWindowPoint? _nearestToMidpoint(
    Iterable<ActivityTimeWindowPoint> points,
    ActivityTimeWindow window,
  ) {
    final candidates = points.toList(growable: false);
    if (candidates.isEmpty) return null;
    final midpoint = window.startUtc.add(
      window.endUtc.difference(window.startUtc) ~/ 2,
    );
    return candidates.reduce((closest, candidate) {
      final closestDistance = closest.timestampUtc.difference(midpoint).abs();
      final candidateDistance = candidate.timestampUtc
          .difference(midpoint)
          .abs();
      return candidateDistance < closestDistance ? candidate : closest;
    });
  }
}
