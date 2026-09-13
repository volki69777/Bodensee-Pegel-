import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

/// Official MeteoSwiss local point forecast for Romanshorn.
///
/// The verified point is the postal-code centre 8590 / point type 2 /
/// point id 859000 (Romanshorn, 47.566578 N, 9.370531 E, 412 m).
class MeteoSwissForecastStation {
  const MeteoSwissForecastStation({
    required this.pointId,
    required this.pointTypeId,
    required this.postalCode,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.elevationMeters,
  });

  final String pointId;
  final String pointTypeId;
  final String postalCode;
  final String name;
  final double latitude;
  final double longitude;
  final double elevationMeters;

  static const romanshorn = MeteoSwissForecastStation(
    pointId: '859000',
    pointTypeId: '2',
    postalCode: '8590',
    name: 'Romanshorn',
    latitude: 47.566578,
    longitude: 9.370531,
    elevationMeters: 412,
  );
}

/// One hourly MeteoSwiss local forecast point. The documented source units are
/// already Celsius, km/h, mm and degrees, so no unit conversion is applied.
class MeteoSwissForecastPoint {
  const MeteoSwissForecastPoint({
    required this.timestampUtc,
    this.temperatureCelsius,
    this.precipitationMillimeters,
    this.windKilometersPerHour,
    this.gustKilometersPerHour,
    this.windDirectionDegrees,
    this.weatherCode,
  });

  final DateTime timestampUtc;
  final double? temperatureCelsius;
  final double? precipitationMillimeters;
  final double? windKilometersPerHour;
  final double? gustKilometersPerHour;
  final double? windDirectionDegrees;
  final int? weatherCode;
}

class MeteoSwissForecast {
  const MeteoSwissForecast({
    required this.station,
    required this.points,
    this.updatedAtUtc,
    this.runAtUtc,
  });

  final MeteoSwissForecastStation station;
  final DateTime? updatedAtUtc;
  final DateTime? runAtUtc;
  final List<MeteoSwissForecastPoint> points;
}

class MeteoSwissDailyForecast {
  const MeteoSwissDailyForecast({
    required this.localDate,
    required this.points,
    this.temperatureMinimumCelsius,
    this.temperatureMaximumCelsius,
    this.precipitationMillimeters,
    this.representativeWindKilometersPerHour,
    this.maximumGustKilometersPerHour,
    this.windDirectionDegrees,
    this.weatherCode,
  });

  final DateTime localDate;
  final List<MeteoSwissForecastPoint> points;
  final double? temperatureMinimumCelsius;
  final double? temperatureMaximumCelsius;
  final double? precipitationMillimeters;
  final double? representativeWindKilometersPerHour;
  final double? maximumGustKilometersPerHour;
  final double? windDirectionDegrees;
  final int? weatherCode;

  String? get windDirectionAbbreviation =>
      MeteoSwissForecastAggregation.windDirectionAbbreviation(
        windDirectionDegrees,
      );

  /// MeteoSwiss publishes this as a pictogram code. We intentionally expose
  /// only the corresponding official German symbol text. Unknown values stay
  /// unavailable rather than receiving an inferred weather description.
  String? get weatherLabel =>
      MeteoSwissWeatherSymbols.germanDescription(weatherCode);
}

/// Official German descriptions for MeteoSwiss weather-symbol keys.
///
/// Source: MeteoSwiss, "Wettersymbole: Texte/Übersetzungen", version 2024.
/// The `jww003i0` point-forecast parameter is the MeteoSwiss icon number for
/// the preceding three hours. The graphics themselves are proprietary; this
/// application uses only the published text descriptions.
abstract final class MeteoSwissWeatherSymbols {
  static const _germanDescriptions = <int, String>{
    1: 'sonnig',
    2: 'ziemlich sonnig',
    3: 'teilweise sonnig',
    4: 'wechselnd bewölkt',
    5: 'bedeckt',
    6: 'Aufhellungen, einzelne Regenschauer',
    7: 'Aufhellungen, einzelne Regen- oder Schneeschauer',
    8: 'Aufhellungen, einzelne Schneeschauer',
    9: 'bewölkt, einige Regenschauer',
    10: 'bewölkt, einige Regen- oder Schneeschauer',
    11: 'bewölkt, einige Schneeschauer',
    12: 'Aufhellungen, leicht gewitterhaft',
    13: 'Aufhellungen und gewitterhaft',
    14: 'stark bewölkt, schwacher Regen',
    15: 'stark bewölkt, schwacher Schnee oder Regen',
    16: 'stark bewölkt, schwacher Schnee',
    17: 'stark bewölkt, zeitweise Regen',
    18: 'stark bewölkt, zeitweise Schnee oder Regen',
    19: 'stark bewölkt, zeitweise Schnee',
    20: 'stark bewölkt, anhaltender Regen',
    21: 'stark bewölkt, anhaltender Regen oder Schnee',
    22: 'stark bewölkt, anhaltender Schnee',
    23: 'stark bewölkt, leicht gewitterhaft',
    24: 'stark bewölkt, gewitterhaft',
    25: 'stark bewölkt, stark gewitterhaft',
    26: 'Hohe Bewölkung',
    27: 'Hochnebel',
    28: 'Nebel',
    29: 'leicht bewölkt, einzelne Regenschauer',
    30: 'leicht bewölkt, leichter Schneefall',
    31: 'teilweise sonnig, einige Schnee- oder Regenschauer',
    32: 'teilweise sonnig, einige Regenschauer',
    33: 'bewölkt, häufige Regenschauer',
    34: 'bewölkt, häufige Schneeschauer',
    35: 'bedeckt und trocken',
    36: 'teilweise sonnig, gewitterhaft',
    37: 'teilweise sonnig, Gewitter und Schneeschauer',
    38: 'bewölkt, Gewitter und häufige Regenschauer',
    39: 'bewölkt, Gewitter und häufige Schneeschauer',
    40: 'stark bewölkt, leicht gewitterhaft',
    41: 'bewölkt, leicht gewitterhaft',
    42: 'stark bewölkt, Gewitter und häufige Schneeschauer',
    101: 'klar',
    102: 'leicht bewölkt',
    103: 'zum Teil bewölkt',
    104: 'wechselnd bewölkt',
    105: 'bedeckt',
    106: 'Aufhellungen, einzelne Regenschauer',
    107: 'Aufhellungen, einzelne Regen- oder Schneeschauer',
    108: 'Aufhellungen, einzelne Schneeschauer',
    109: 'bewölkt, einige Regenschauer',
    110: 'bewölkt, einige Regen- oder Schneeschauer',
    111: 'bewölkt, einige Schneeschauer',
    112: 'Aufhellungen, leicht gewitterhaft',
    113: 'Aufhellungen und gewitterhaft',
    114: 'stark bewölkt, schwacher Regen',
    115: 'stark bewölkt, schwacher Schnee oder Regen',
    116: 'stark bewölkt, schwacher Schnee',
    117: 'stark bewölkt, zeitweise Regen',
    118: 'stark bewölkt, zeitweise Schnee oder Regen',
    119: 'stark bewölkt, zeitweise Schnee',
    120: 'stark bewölkt, anhaltender Regen',
    121: 'stark bewölkt, anhaltender Regen oder Schnee',
    122: 'stark bewölkt, anhaltender Schnee',
    123: 'stark bewölkt, leicht gewitterhaft',
    124: 'stark bewölkt, gewitterhaft',
    125: 'stark bewölkt, stark gewitterhaft',
    126: 'Hohe Bewölkung',
    127: 'Hochnebel',
    128: 'Nebel',
    129: 'leicht bewölkt, einzelne Regenschauer',
    130: 'leicht bewölkt, leichter Schneefall',
    131: 'leicht bewölkt, einige Schnee- oder Regenschauer',
    132: 'leicht bewölkt, einige Regenschauer',
    133: 'bewölkt, häufige Regenschauer',
    134: 'bewölkt, häufige Schneeschauer',
    135: 'bedeckt und trocken',
    136: 'Aufhellungen, gewitterhaft',
    137: 'leicht bewölkt, Gewitter und Schneeschauer',
    138: 'bewölkt, Gewitter und häufige Regenschauer',
    139: 'bewölkt, Gewitter und häufige Schneeschauer',
    140: 'stark bewölkt, leicht gewitterhaft',
    141: 'bewölkt, leicht gewitterhaft',
    142: 'stark bewölkt, Gewitter und häufige Schneeschauer',
  };

  static String? germanDescription(int? code) =>
      code == null ? null : _germanDescriptions[code];
}

class MeteoSwissForecastParser {
  static MeteoSwissForecast parseJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('MeteoSwiss-Antwort ist kein Objekt.');
    }
    return parsePayload(decoded);
  }

  static MeteoSwissForecast parsePayload(Map<String, dynamic> payload) {
    final stationPayload = payload['station'];
    final pointPayload = payload['points'];
    if (stationPayload is! Map || pointPayload is! List) {
      throw const FormatException(
        'MeteoSwiss-Antwort enthält keine Punktdaten.',
      );
    }
    final station = MeteoSwissForecastStation(
      pointId: _string(stationPayload['pointId']) ?? '',
      pointTypeId: _string(stationPayload['pointTypeId']) ?? '',
      postalCode: _string(stationPayload['postalCode']) ?? '',
      name: _string(stationPayload['name']) ?? '',
      latitude: _number(stationPayload['latitude']) ?? double.nan,
      longitude: _number(stationPayload['longitude']) ?? double.nan,
      elevationMeters: _number(stationPayload['elevationMeters']) ?? double.nan,
    );
    if (station.pointId != MeteoSwissForecastStation.romanshorn.pointId ||
        station.pointTypeId !=
            MeteoSwissForecastStation.romanshorn.pointTypeId ||
        station.name.toLowerCase() != 'romanshorn' ||
        !station.latitude.isFinite ||
        !station.longitude.isFinite ||
        !station.elevationMeters.isFinite) {
      throw const FormatException(
        'MeteoSwiss-Antwort gehört nicht zu Romanshorn.',
      );
    }

    final points =
        pointPayload
            .whereType<Map>()
            .map((raw) {
              final timestamp = DateTime.tryParse(
                _string(raw['timestampUtc']) ?? '',
              );
              if (timestamp == null) return null;
              return MeteoSwissForecastPoint(
                timestampUtc: timestamp.toUtc(),
                temperatureCelsius: _number(raw['temperatureCelsius']),
                precipitationMillimeters: _number(
                  raw['precipitationMillimeters'],
                ),
                windKilometersPerHour: _number(raw['windKilometersPerHour']),
                gustKilometersPerHour: _number(raw['gustKilometersPerHour']),
                windDirectionDegrees: _number(raw['windDirectionDegrees']),
                weatherCode: _number(raw['weatherCode'])?.round(),
              );
            })
            .whereType<MeteoSwissForecastPoint>()
            .toList(growable: false)
          ..sort((a, b) => a.timestampUtc.compareTo(b.timestampUtc));
    if (points.isEmpty) {
      throw const FormatException(
        'MeteoSwiss-Antwort enthält keine Forecast-Zeitpunkte.',
      );
    }
    return MeteoSwissForecast(
      station: station,
      updatedAtUtc: _date(payload['updatedAtUtc']),
      runAtUtc: _date(payload['runAtUtc']),
      points: List.unmodifiable(points),
    );
  }

  static String? _string(Object? value) => value is String ? value : null;

  static double? _number(Object? value) => switch (value) {
    num() => value.toDouble().isFinite ? value.toDouble() : null,
    String() =>
      double.tryParse(value)?.isFinite == true ? double.tryParse(value) : null,
    _ => null,
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

class MeteoSwissForecastAggregation {
  static final tz.Location _zurich = (() {
    timezone_data.initializeTimeZones();
    return tz.getLocation('Europe/Zurich');
  })();

  /// Groups the original hourly values on local Europe/Zurich calendar days.
  /// Points of an already elapsed part of today are deliberately excluded.
  static List<MeteoSwissDailyForecast> aggregate(
    MeteoSwissForecast forecast, {
    DateTime? nowUtc,
  }) {
    final currentUtc = (nowUtc ?? DateTime.now()).toUtc();
    final currentLocal = tz.TZDateTime.from(currentUtc, _zurich);
    final groups = <String, List<MeteoSwissForecastPoint>>{};
    final dates = <String, DateTime>{};
    for (final point in forecast.points) {
      final local = tz.TZDateTime.from(point.timestampUtc, _zurich);
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

  static MeteoSwissDailyForecast _daily(
    DateTime date,
    List<MeteoSwissForecastPoint> points,
  ) {
    final temperatures = points
        .map((point) => point.temperatureCelsius)
        .whereType<double>()
        .toList(growable: false);
    final precipitation = points
        .map((point) => point.precipitationMillimeters)
        .whereType<double>()
        .toList(growable: false);
    final gusts = points
        .map((point) => point.gustKilometersPerHour)
        .whereType<double>()
        .toList(growable: false);
    final representative = _nearestToLocalNoon(
      points.where((point) => point.windKilometersPerHour != null).toList(),
    );
    final weather = _nearestToLocalNoon(
      points.where((point) => point.weatherCode != null).toList(),
    );
    return MeteoSwissDailyForecast(
      localDate: date,
      points: List.unmodifiable(points),
      temperatureMinimumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce(_min),
      temperatureMaximumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce(_max),
      precipitationMillimeters: precipitation.isEmpty
          ? null
          : precipitation.reduce((a, b) => a + b),
      representativeWindKilometersPerHour:
          representative?.windKilometersPerHour,
      maximumGustKilometersPerHour: gusts.isEmpty ? null : gusts.reduce(_max),
      windDirectionDegrees: representative?.windDirectionDegrees,
      weatherCode: weather?.weatherCode,
    );
  }

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;

  static MeteoSwissForecastPoint? _nearestToLocalNoon(
    List<MeteoSwissForecastPoint> points,
  ) {
    if (points.isEmpty) return null;
    return points.reduce((closest, candidate) {
      final closestLocal = tz.TZDateTime.from(closest.timestampUtc, _zurich);
      final candidateLocal = tz.TZDateTime.from(
        candidate.timestampUtc,
        _zurich,
      );
      final closestDistance =
          (closestLocal.hour * 60 + closestLocal.minute - 720).abs();
      final candidateDistance =
          (candidateLocal.hour * 60 + candidateLocal.minute - 720).abs();
      return candidateDistance < closestDistance ? candidate : closest;
    });
  }

  static String? windDirectionAbbreviation(double? degrees) {
    if (degrees == null) return null;
    const directions = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    // Eight sectors of 45° with boundaries at ±22.5° around each direction.
    final normalized = (degrees % 360 + 360) % 360;
    final index = ((normalized + 22.5) / 45).floor() % directions.length;
    return directions[index];
  }
}

class MeteoSwissForecastService {
  MeteoSwissForecastService({http.Client? client})
    : _client = client ?? http.Client();

  static const proxyUrl =
      'http://127.0.0.1:8787/api/meteoswiss/forecast/romanshorn';
  static const _cacheDuration = Duration(minutes: 30);

  final http.Client _client;
  MeteoSwissForecast? _cached;
  DateTime? _cachedAt;
  Future<MeteoSwissForecast>? _inFlight;

  Future<MeteoSwissForecast> load({bool forceRefresh = false}) {
    if (!forceRefresh &&
        _cached != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheDuration) {
      return Future.value(_cached);
    }
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<MeteoSwissForecast> _load() async {
    final response = await _client
        .get(Uri.parse(proxyUrl))
        .timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw MeteoSwissForecastException(
        'MeteoSwiss-Prognose ist derzeit nicht verfügbar.',
      );
    }
    final forecast = MeteoSwissForecastParser.parseJson(response.body);
    _cached = forecast;
    _cachedAt = DateTime.now();
    return forecast;
  }
}

class MeteoSwissForecastException implements Exception {
  const MeteoSwissForecastException(this.message);
  final String message;

  @override
  String toString() => message;
}
