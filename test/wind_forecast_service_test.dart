import 'package:bodensee_pegel/dwd_forecast_service.dart';
import 'package:bodensee_pegel/geosphere_forecast_service.dart';
import 'package:bodensee_pegel/meteoswiss_forecast_service.dart';
import 'package:bodensee_pegel/wind_forecast_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps international Beaufort boundaries from mean wind only', () {
    expect(BeaufortScale.fromKilometersPerHour(null), isNull);
    expect(BeaufortScale.fromKilometersPerHour(0), 0);
    expect(BeaufortScale.fromKilometersPerHour(1), 0);
    expect(BeaufortScale.fromKilometersPerHour(1.1), 1);
    expect(BeaufortScale.fromKilometersPerHour(5), 1);
    expect(BeaufortScale.fromKilometersPerHour(5.1), 2);
    expect(BeaufortScale.fromKilometersPerHour(19), 3);
    expect(BeaufortScale.fromKilometersPerHour(20), 4);
    expect(BeaufortScale.fromKilometersPerHour(39), 6);
    expect(BeaufortScale.fromKilometersPerHour(62), 8);
    expect(BeaufortScale.label(3), 'schwache Brise');
    expect(BeaufortScale.label(7), 'steifer Wind');
  });

  test('maps meteorological source directions to eight compass sectors', () {
    expect(WindDirection.abbreviation(0), 'N');
    expect(WindDirection.abbreviation(22.49), 'N');
    expect(WindDirection.abbreviation(22.5), 'NO');
    expect(WindDirection.abbreviation(90), 'O');
    expect(WindDirection.abbreviation(180), 'S');
    expect(WindDirection.abbreviation(270), 'W');
    expect(WindDirection.abbreviation(315), 'NW');
    expect(WindDirection.abbreviation(359), 'N');
    expect(WindDirection.abbreviation(null), isNull);
  });

  test('selects only genuine points in 24 and 48 hour ranges', () {
    final now = DateTime.utc(2026, 10, 11, 10);
    final points = [
      _point(now.subtract(const Duration(minutes: 1)), wind: 5),
      _point(now, wind: 6),
      _point(now.add(const Duration(hours: 24)), wind: 7),
      _point(now.add(const Duration(hours: 25)), wind: 8),
      _point(now.add(const Duration(hours: 48)), wind: 9),
      _point(now.add(const Duration(hours: 49)), wind: 10),
    ];
    expect(
      WindForecastSelection.forDuration(
        points: points,
        nowUtc: now,
        duration: const Duration(hours: 24),
      ).map((point) => point.windKilometersPerHour),
      [6, 7],
    );
    expect(
      WindForecastSelection.forDuration(
        points: points,
        nowUtc: now,
        duration: const Duration(hours: 48),
      ).map((point) => point.windKilometersPerHour),
      [6, 7, 8, 9],
    );
  });

  test('keeps missing official values null instead of inventing zeroes', () {
    final point = _point(DateTime.utc(2026, 10, 11, 12));
    expect(point.windKilometersPerHour, isNull);
    expect(point.gustKilometersPerHour, isNull);
    expect(WindForecastSelection.nextUsable([point]), isNull);
  });

  test('normalizes DWD, MeteoSwiss and GeoSphere original units centrally', () {
    final dwd = WindForecast.fromDwd(
      DwdMosmixForecast(
        station: DwdMosmixStation.konstanz,
        issuedAtUtc: DateTime.utc(2026, 10, 11),
        points: [
          DwdForecastPoint(
            timestampUtc: DateTime.utc(2026, 10, 11, 12),
            windMetersPerSecond: 5,
            gustMetersPerSecond: 8,
            windDirectionDegrees: 315,
          ),
        ],
      ),
    );
    final swiss = WindForecast.fromMeteoSwiss(
      MeteoSwissForecast(
        station: MeteoSwissForecastStation.romanshorn,
        points: [
          MeteoSwissForecastPoint(
            timestampUtc: DateTime.utc(2026, 10, 11, 12),
            windKilometersPerHour: 18,
            gustKilometersPerHour: 25,
            windDirectionDegrees: 90,
          ),
        ],
      ),
    );
    final geo = WindForecast.fromGeoSphere(
      GeoSphereForecast(
        referenceTimeUtc: DateTime.utc(2026, 10, 11),
        gridLatitude: 47.502,
        gridLongitude: 9.7432,
        points: [
          GeoSphereForecastPoint(
            timestampUtc: DateTime.utc(2026, 10, 11, 12),
            windEastwardMetersPerSecond: -5,
            windNorthwardMetersPerSecond: 0,
            gustMetersPerSecond: 7,
          ),
        ],
      ),
    );
    expect(dwd.points.single.windKilometersPerHour, 18);
    expect(dwd.points.single.gustKilometersPerHour, 28.8);
    expect(swiss.points.single.windKilometersPerHour, 18);
    expect(geo.points.single.windKilometersPerHour, 18);
    expect(geo.points.single.gustKilometersPerHour, 25.2);
    expect(geo.points.single.directionDegrees, 90);
  });
}

WindForecastPoint _point(DateTime timestamp, {double? wind, double? gust}) =>
    WindForecastPoint(
      timestampUtc: timestamp,
      windKilometersPerHour: wind,
      gustKilometersPerHour: gust,
    );
