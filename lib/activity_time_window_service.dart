import 'dart:math' as math;

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

  static List<ActivityTimeWindowForecast> aggregate({
    required Iterable<ActivityTimeWindowPoint> points,
    required Iterable<ActivityTimeWindow> windows,
  }) => windows.map((window) => _aggregate(window, points)).toList();

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
