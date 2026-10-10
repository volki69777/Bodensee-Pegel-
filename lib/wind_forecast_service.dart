import 'dwd_forecast_service.dart';
import 'geosphere_forecast_service.dart';
import 'meteoswiss_forecast_service.dart';

import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

/// A source-neutral, original forecast point for the LIVE wind display.
///
/// Values stay nullable all the way to the chart. This prevents unavailable
/// official forecast values from being rendered as zero or connected across a
/// gap.
class WindForecastPoint {
  const WindForecastPoint({
    required this.timestampUtc,
    this.windKilometersPerHour,
    this.gustKilometersPerHour,
    this.directionDegrees,
  });

  final DateTime timestampUtc;
  final double? windKilometersPerHour;
  final double? gustKilometersPerHour;
  final double? directionDegrees;
}

enum WindForecastSource { dwd, meteoSwiss, geoSphere }

class WindForecast {
  const WindForecast({
    required this.source,
    required this.points,
    this.issuedAtUtc,
  });

  final WindForecastSource source;
  final DateTime? issuedAtUtc;
  final List<WindForecastPoint> points;

  String get sourceLabel => switch (source) {
    WindForecastSource.dwd => 'Deutscher Wetterdienst (DWD) · MOSMIX',
    WindForecastSource.meteoSwiss => 'MeteoSwiss',
    WindForecastSource.geoSphere => 'GeoSphere Austria',
  };

  factory WindForecast.fromDwd(DwdMosmixForecast forecast) => WindForecast(
    source: WindForecastSource.dwd,
    issuedAtUtc: forecast.issuedAtUtc,
    points: forecast.points
        .map(
          (point) => WindForecastPoint(
            timestampUtc: point.timestampUtc,
            windKilometersPerHour: point.windKilometersPerHour,
            gustKilometersPerHour: point.gustKilometersPerHour,
            directionDegrees: point.windDirectionDegrees,
          ),
        )
        .toList(growable: false),
  );

  factory WindForecast.fromMeteoSwiss(MeteoSwissForecast forecast) =>
      WindForecast(
        source: WindForecastSource.meteoSwiss,
        issuedAtUtc: forecast.updatedAtUtc ?? forecast.runAtUtc,
        points: forecast.points
            .map(
              (point) => WindForecastPoint(
                timestampUtc: point.timestampUtc,
                windKilometersPerHour: point.windKilometersPerHour,
                gustKilometersPerHour: point.gustKilometersPerHour,
                directionDegrees: point.windDirectionDegrees,
              ),
            )
            .toList(growable: false),
      );

  factory WindForecast.fromGeoSphere(GeoSphereForecast forecast) =>
      WindForecast(
        source: WindForecastSource.geoSphere,
        issuedAtUtc: forecast.referenceTimeUtc,
        points: forecast.points
            .map(
              (point) => WindForecastPoint(
                timestampUtc: point.timestampUtc,
                windKilometersPerHour: point.windKilometersPerHour,
                gustKilometersPerHour: point.gustKilometersPerHour,
                directionDegrees: point.meteorologicalWindDirectionDegrees,
              ),
            )
            .toList(growable: false),
      );
}

/// International Beaufort scale for *mean* wind speed, expressed in km/h.
/// Gusts deliberately never determine the displayed Beaufort value.
abstract final class BeaufortScale {
  static int? fromKilometersPerHour(double? windKilometersPerHour) {
    if (windKilometersPerHour == null || windKilometersPerHour < 0) return null;
    const upperBounds = <double>[
      1,
      5,
      11,
      19,
      28,
      38,
      49,
      61,
      74,
      88,
      102,
      117,
    ];
    for (var index = 0; index < upperBounds.length; index++) {
      if (windKilometersPerHour <= upperBounds[index]) return index;
    }
    return 12;
  }

  static String? label(int? beaufort) => switch (beaufort) {
    0 => 'Windstille',
    1 => 'leiser Zug',
    2 => 'leichte Brise',
    3 => 'schwache Brise',
    4 => 'mäßige Brise',
    5 => 'frische Brise',
    6 => 'starker Wind',
    7 => 'steifer Wind',
    8 => 'stürmischer Wind',
    9 => 'Sturm',
    10 => 'schwerer Sturm',
    11 => 'orkanartiger Sturm',
    12 => 'Orkan',
    _ => null,
  };
}

abstract final class WindDirection {
  /// Maps the meteorological direction the wind comes *from* into tested
  /// eight-sector compass labels. `90°` therefore means `O`.
  static String? abbreviation(double? degrees) {
    if (degrees == null || !degrees.isFinite) return null;
    const directions = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    final normalized = (degrees % 360 + 360) % 360;
    return directions[((normalized + 22.5) / 45).floor() % directions.length];
  }
}

abstract final class WindForecastSelection {
  /// Returns only genuine future points in the requested time span. No point
  /// is interpolated or carried forward beyond the source horizon.
  static List<WindForecastPoint> forDuration({
    required Iterable<WindForecastPoint> points,
    required DateTime nowUtc,
    required Duration duration,
  }) {
    final end = nowUtc.add(duration);
    return points
        .where(
          (point) =>
              !point.timestampUtc.isBefore(nowUtc) &&
              !point.timestampUtc.isAfter(end),
        )
        .toList(growable: false);
  }

  static WindForecastPoint? nextUsable(Iterable<WindForecastPoint> points) {
    for (final point in points) {
      if (point.windKilometersPerHour != null ||
          point.gustKilometersPerHour != null) {
        return point;
      }
    }
    return null;
  }
}

abstract final class WindForecastTimeZones {
  static tz.Location forSource(WindForecastSource source) {
    timezone_data.initializeTimeZones();
    return tz.getLocation(switch (source) {
      WindForecastSource.dwd => 'Europe/Berlin',
      WindForecastSource.meteoSwiss => 'Europe/Zurich',
      WindForecastSource.geoSphere => 'Europe/Vienna',
    });
  }
}
