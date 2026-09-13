import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import 'meteoswiss_forecast_service.dart' show MeteoSwissForecastAggregation;

/// Official GeoSphere Austria NWP v2 forecast at the Bregenz lake-level
/// location. The Dataset API returns the nearest 1 km model grid point.
abstract final class GeoSphereForecastLocation {
  static const requestedLatitude = 47.5037;
  static const requestedLongitude = 9.7432;
  static const expectedGridLatitude = 47.5020;
  static const expectedGridLongitude = 9.7432;
}

class GeoSphereForecastPoint {
  const GeoSphereForecastPoint({
    required this.timestampUtc,
    this.temperatureCelsius,
    this.windEastwardMetersPerSecond,
    this.windNorthwardMetersPerSecond,
    this.gustMetersPerSecond,
    this.precipitationKilogramsPerSquareMeter,
    this.weatherSymbolCode,
    this.cloudCoverPercent,
  });

  final DateTime timestampUtc;
  final double? temperatureCelsius;
  final double? windEastwardMetersPerSecond;
  final double? windNorthwardMetersPerSecond;
  final double? gustMetersPerSecond;
  final double? precipitationKilogramsPerSquareMeter;
  final int? weatherSymbolCode;
  final double? cloudCoverPercent;

  /// Wind vector magnitude. GeoSphere publishes both components in m/s.
  double? get windKilometersPerHour {
    final east = windEastwardMetersPerSecond;
    final north = windNorthwardMetersPerSecond;
    if (east == null || north == null) return null;
    return math.sqrt(east * east + north * north) * 3.6;
  }

  double? get gustKilometersPerHour =>
      gustMetersPerSecond == null ? null : gustMetersPerSecond! * 3.6;

  /// Meteorological direction: the direction the wind comes *from*, derived
  /// from the eastward/northward movement vector supplied by GeoSphere.
  double? get meteorologicalWindDirectionDegrees {
    final east = windEastwardMetersPerSecond;
    final north = windNorthwardMetersPerSecond;
    if (east == null || north == null) return null;
    final degrees = math.atan2(-east, -north) * 180 / math.pi;
    return (degrees % 360 + 360) % 360;
  }

  /// For liquid-water equivalent, 1 kg/m² equals 1 mm. The conversion is
  /// explicit because the source unit remains available in the raw model.
  double? get precipitationMillimeters => precipitationKilogramsPerSquareMeter;
}

class GeoSphereForecast {
  const GeoSphereForecast({
    required this.referenceTimeUtc,
    required this.gridLatitude,
    required this.gridLongitude,
    required this.points,
  });

  final DateTime referenceTimeUtc;
  final double gridLatitude;
  final double gridLongitude;
  final List<GeoSphereForecastPoint> points;
}

class GeoSphereDailyForecast {
  const GeoSphereDailyForecast({
    required this.localDate,
    required this.points,
    this.temperatureMinimumCelsius,
    this.temperatureMaximumCelsius,
    this.precipitationMillimeters,
    this.representativeWindKilometersPerHour,
    this.maximumGustKilometersPerHour,
    this.windDirectionDegrees,
    this.weatherSymbolCode,
  });

  final DateTime localDate;
  final List<GeoSphereForecastPoint> points;
  final double? temperatureMinimumCelsius;
  final double? temperatureMaximumCelsius;
  final double? precipitationMillimeters;
  final double? representativeWindKilometersPerHour;
  final double? maximumGustKilometersPerHour;
  final double? windDirectionDegrees;
  final int? weatherSymbolCode;

  String? get windDirectionAbbreviation =>
      MeteoSwissForecastAggregation.windDirectionAbbreviation(
        windDirectionDegrees,
      );

  /// GeoSphere's `sy` values are retained, but no weather text is exposed
  /// until an official GeoSphere code-to-text table is available.
  String? get weatherLabel => null;
}

class GeoSphereForecastParser {
  static GeoSphereForecast parseJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GeoSphere-Antwort ist kein Objekt.');
    }
    final referenceTime = _date(decoded['reference_time']);
    final timestamps = decoded['timestamps'];
    final features = decoded['features'];
    if (referenceTime == null ||
        timestamps is! List ||
        features is! List ||
        features.isEmpty) {
      throw const FormatException(
        'GeoSphere-Antwort enthält keine Forecast-Daten.',
      );
    }
    final feature = features.first;
    if (feature is! Map) {
      throw const FormatException('GeoSphere-Antwort enthält keinen Punkt.');
    }
    final geometry = feature['geometry'];
    final properties = feature['properties'];
    if (geometry is! Map || properties is! Map) {
      throw const FormatException('GeoSphere-Punkt ist unvollständig.');
    }
    final coordinates = geometry['coordinates'];
    final parameters = properties['parameters'];
    if (coordinates is! List || coordinates.length < 2 || parameters is! Map) {
      throw const FormatException(
        'GeoSphere-Punkt enthält keine Koordinaten oder Parameter.',
      );
    }
    final longitude = _number(coordinates[0]);
    final latitude = _number(coordinates[1]);
    if (latitude == null ||
        longitude == null ||
        (latitude - GeoSphereForecastLocation.expectedGridLatitude).abs() >
            .02 ||
        (longitude - GeoSphereForecastLocation.expectedGridLongitude).abs() >
            .02) {
      throw const FormatException(
        'GeoSphere-Antwort gehört nicht zum Bregenzer Gitterpunkt.',
      );
    }
    final parsedTimes = timestamps
        .map(
          (value) => value is String ? DateTime.tryParse(value)?.toUtc() : null,
        )
        .toList(growable: false);
    if (parsedTimes.isEmpty || parsedTimes.any((value) => value == null)) {
      throw const FormatException(
        'GeoSphere-Antwort enthält ungültige Forecast-Zeitpunkte.',
      );
    }
    List<double?> values(String name) {
      final parameter = parameters[name];
      final data = parameter is Map ? parameter['data'] : null;
      if (data == null) return List<double?>.filled(parsedTimes.length, null);
      if (data is! List || data.length != parsedTimes.length) {
        throw const FormatException(
          'GeoSphere-Parameter enthält unpassende Werte.',
        );
      }
      return data.map(_number).toList(growable: false);
    }

    final temperature = values('2t');
    final eastward = values('10u');
    final northward = values('10v');
    final gust = values('10fg');
    final precipitation = values('tp');
    final weatherSymbol = values('sy');
    final cloudCover = values('tcc');
    final points = List<GeoSphereForecastPoint>.generate(
      parsedTimes.length,
      (index) => GeoSphereForecastPoint(
        timestampUtc: parsedTimes[index]!,
        temperatureCelsius: temperature[index],
        windEastwardMetersPerSecond: eastward[index],
        windNorthwardMetersPerSecond: northward[index],
        gustMetersPerSecond: gust[index],
        precipitationKilogramsPerSquareMeter: precipitation[index],
        weatherSymbolCode: weatherSymbol[index]?.round(),
        cloudCoverPercent: cloudCover[index],
      ),
    )..sort((a, b) => a.timestampUtc.compareTo(b.timestampUtc));
    return GeoSphereForecast(
      referenceTimeUtc: referenceTime,
      gridLatitude: latitude,
      gridLongitude: longitude,
      points: List.unmodifiable(points),
    );
  }

  static double? _number(Object? value) => switch (value) {
    num() => value.toDouble().isFinite ? value.toDouble() : null,
    String() =>
      double.tryParse(value)?.isFinite == true ? double.tryParse(value) : null,
    _ => null,
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

class GeoSphereForecastAggregation {
  static final tz.Location _vienna = (() {
    timezone_data.initializeTimeZones();
    return tz.getLocation('Europe/Vienna');
  })();

  static List<GeoSphereDailyForecast> aggregate(
    GeoSphereForecast forecast, {
    DateTime? nowUtc,
  }) {
    final currentUtc = (nowUtc ?? DateTime.now()).toUtc();
    final currentLocal = tz.TZDateTime.from(currentUtc, _vienna);
    final groups = <String, List<GeoSphereForecastPoint>>{};
    final dates = <String, DateTime>{};
    for (final point in forecast.points) {
      final local = tz.TZDateTime.from(point.timestampUtc, _vienna);
      final isToday =
          local.year == currentLocal.year &&
          local.month == currentLocal.month &&
          local.day == currentLocal.day;
      if (isToday && point.timestampUtc.isBefore(currentUtc)) continue;
      final key = '${local.year}-${local.month}-${local.day}';
      groups.putIfAbsent(key, () => []).add(point);
      dates[key] = DateTime(local.year, local.month, local.day);
    }
    return groups.entries
        .map((entry) => _daily(dates[entry.key]!, entry.value))
        .toList(growable: false);
  }

  static GeoSphereDailyForecast _daily(
    DateTime date,
    List<GeoSphereForecastPoint> points,
  ) {
    List<double> values(double? Function(GeoSphereForecastPoint) select) =>
        points.map(select).whereType<double>().toList(growable: false);
    final temperatures = values((point) => point.temperatureCelsius);
    final precipitation = values((point) => point.precipitationMillimeters);
    final gusts = values((point) => point.gustKilometersPerHour);
    final representative = _nearestToLocalNoon(
      points.where((point) => point.windKilometersPerHour != null).toList(),
    );
    final weather = _nearestToLocalNoon(
      points.where((point) => point.weatherSymbolCode != null).toList(),
    );
    return GeoSphereDailyForecast(
      localDate: date,
      points: List.unmodifiable(points),
      temperatureMinimumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce(math.min),
      temperatureMaximumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce(math.max),
      precipitationMillimeters: precipitation.isEmpty
          ? null
          : precipitation.reduce((a, b) => a + b),
      representativeWindKilometersPerHour:
          representative?.windKilometersPerHour,
      maximumGustKilometersPerHour: gusts.isEmpty
          ? null
          : gusts.reduce(math.max),
      windDirectionDegrees: representative?.meteorologicalWindDirectionDegrees,
      weatherSymbolCode: weather?.weatherSymbolCode,
    );
  }

  static GeoSphereForecastPoint? _nearestToLocalNoon(
    List<GeoSphereForecastPoint> points,
  ) {
    if (points.isEmpty) return null;
    return points.reduce((closest, candidate) {
      final closestLocal = tz.TZDateTime.from(closest.timestampUtc, _vienna);
      final candidateLocal = tz.TZDateTime.from(
        candidate.timestampUtc,
        _vienna,
      );
      final closestDistance =
          (closestLocal.hour * 60 + closestLocal.minute - 720).abs();
      final candidateDistance =
          (candidateLocal.hour * 60 + candidateLocal.minute - 720).abs();
      return candidateDistance < closestDistance ? candidate : closest;
    });
  }
}

class GeoSphereForecastService {
  GeoSphereForecastService({http.Client? client})
    : _client = client ?? http.Client();

  static const endpoint =
      'https://dataset.api.hub.geosphere.at/v1/timeseries/forecast/nwp-v2-1h-1km?parameters=2t,10u,10v,10fg,tp,sy,tcc&lat_lon=47.5037,9.7432';
  static const _cacheDuration = Duration(minutes: 30);

  final http.Client _client;
  GeoSphereForecast? _cached;
  DateTime? _cachedAt;
  Future<GeoSphereForecast>? _inFlight;

  Future<GeoSphereForecast> load({bool forceRefresh = false}) {
    if (!forceRefresh &&
        _cached != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheDuration) {
      return Future.value(_cached);
    }
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<GeoSphereForecast> _load() async {
    final response = await _client
        .get(Uri.parse(endpoint), headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const GeoSphereForecastException(
        'GeoSphere-Prognose ist derzeit nicht verfügbar.',
      );
    }
    final forecast = GeoSphereForecastParser.parseJson(response.body);
    _cached = forecast;
    _cachedAt = DateTime.now();
    return forecast;
  }
}

class GeoSphereForecastException implements Exception {
  const GeoSphereForecastException(this.message);
  final String message;

  @override
  String toString() => message;
}
