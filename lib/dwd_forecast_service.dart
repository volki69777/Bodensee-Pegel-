import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:xml/xml.dart';

/// Official DWD MOSMIX-L point forecast for Konstanz.
///
/// The point is verified against the DWD MOSMIX station catalogue:
/// 10929 / EDTZ / KONSTANZ, 47°41′ N, 9°11′ E, 443 m. The KML itself uses
/// decimal degrees (9.18 E, 47.68 N, 443 m).
class DwdMosmixStation {
  const DwdMosmixStation({
    required this.id,
    required this.icao,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.elevationMeters,
  });

  final String id;
  final String icao;
  final String name;
  final double latitude;
  final double longitude;
  final double elevationMeters;

  static const konstanz = DwdMosmixStation(
    id: '10929',
    icao: 'EDTZ',
    name: 'KONSTANZ',
    latitude: 47.68,
    longitude: 9.18,
    elevationMeters: 443,
  );
}

class DwdForecastPoint {
  const DwdForecastPoint({
    required this.timestampUtc,
    this.temperatureKelvin,
    this.windMetersPerSecond,
    this.gustMetersPerSecond,
    this.windDirectionDegrees,
    this.precipitationMillimeters,
    this.weatherCode,
    this.cloudCoverPercent,
  });

  final DateTime timestampUtc;
  final double? temperatureKelvin;
  final double? windMetersPerSecond;
  final double? gustMetersPerSecond;
  final double? windDirectionDegrees;
  final double? precipitationMillimeters;
  final int? weatherCode;
  final double? cloudCoverPercent;

  double? get temperatureCelsius =>
      temperatureKelvin == null ? null : temperatureKelvin! - 273.15;
  double? get windKilometersPerHour =>
      windMetersPerSecond == null ? null : windMetersPerSecond! * 3.6;
  double? get gustKilometersPerHour =>
      gustMetersPerSecond == null ? null : gustMetersPerSecond! * 3.6;
}

class DwdMosmixForecast {
  const DwdMosmixForecast({
    required this.station,
    required this.issuedAtUtc,
    required this.points,
  });

  final DwdMosmixStation station;
  final DateTime? issuedAtUtc;
  final List<DwdForecastPoint> points;
}

class DwdDailyForecast {
  const DwdDailyForecast({
    required this.localDate,
    required this.points,
    this.temperatureMinimumCelsius,
    this.temperatureMaximumCelsius,
    this.representativeWindKilometersPerHour,
    this.maximumWindKilometersPerHour,
    this.maximumGustKilometersPerHour,
    this.windDirectionDegrees,
    this.precipitationMillimeters,
    this.weatherCode,
    this.cloudCoverPercent,
  });

  final DateTime localDate;
  final List<DwdForecastPoint> points;
  final double? temperatureMinimumCelsius;
  final double? temperatureMaximumCelsius;
  final double? representativeWindKilometersPerHour;
  final double? maximumWindKilometersPerHour;
  final double? maximumGustKilometersPerHour;
  final double? windDirectionDegrees;
  final double? precipitationMillimeters;
  final int? weatherCode;
  final double? cloudCoverPercent;

  /// The representative value is the actual MOSMIX point nearest local noon
  /// that contains wind speed; direction is taken from the same point.
  String? get windDirectionAbbreviation =>
      DwdMosmixAggregation.windDirectionAbbreviation(windDirectionDegrees);

  /// This uses only the DWD `ww` code. It intentionally has no free-text
  /// meteorological interpretation beyond the documented weather-code groups.
  String? get weatherLabel => DwdMosmixAggregation.weatherLabel(weatherCode);
}

class DwdMosmixParser {
  static DwdMosmixForecast parseKmz(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final kml = archive.files.firstWhere(
      (file) => file.isFile && file.name.toLowerCase().endsWith('.kml'),
      orElse: () =>
          throw const FormatException('DWD-KMZ enthält keine KML-Datei.'),
    );
    final content = kml.content;
    return parseKml(String.fromCharCodes(content), archiveFileName: kml.name);
  }

  static DwdMosmixForecast parseKml(String source, {String? archiveFileName}) {
    final document = XmlDocument.parse(source);
    final timeSteps = document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'TimeStep')
        .map((element) => DateTime.parse(element.innerText.trim()).toUtc())
        .toList(growable: false);
    if (timeSteps.isEmpty) {
      throw const FormatException('DWD-KML enthält keine Forecast-Zeitpunkte.');
    }

    final placemark = document.descendants.whereType<XmlElement>().firstWhere(
      (element) => element.name.local == 'Placemark',
      orElse: () => throw const FormatException(
        'DWD-KML enthält keinen Vorhersagepunkt.',
      ),
    );
    final id = _childText(placemark, 'name');
    final name = _childText(placemark, 'description');
    if (id != DwdMosmixStation.konstanz.id ||
        name?.toUpperCase() != 'KONSTANZ') {
      throw const FormatException(
        'DWD-KML gehört nicht zum Konstanz-Vorhersagepunkt.',
      );
    }

    final coordinates = placemark.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'coordinates')
        .map((element) => element.innerText.trim())
        .firstOrNull
        ?.split(',');
    if (coordinates == null || coordinates.length < 3) {
      throw const FormatException(
        'DWD-KML enthält keine gültigen Stationskoordinaten.',
      );
    }
    final longitude = double.tryParse(coordinates[0]);
    final latitude = double.tryParse(coordinates[1]);
    final elevation = double.tryParse(coordinates[2]);
    if (longitude == null || latitude == null || elevation == null) {
      throw const FormatException(
        'DWD-KML enthält ungültige Stationskoordinaten.',
      );
    }

    final parameterValues = <String, List<double?>>{};
    for (final forecast in placemark.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'Forecast',
    )) {
      final elementName = forecast.attributes
          .where((attribute) => attribute.name.local == 'elementName')
          .map((attribute) => attribute.value)
          .firstOrNull;
      if (elementName == null || !_parameters.contains(elementName)) continue;
      final valueElement = forecast.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'value')
          .firstOrNull;
      if (valueElement == null) continue;
      parameterValues[elementName] = _values(
        valueElement.innerText,
        timeSteps.length,
      );
    }

    final points = List<DwdForecastPoint>.generate(
      timeSteps.length,
      (index) => DwdForecastPoint(
        timestampUtc: timeSteps[index],
        temperatureKelvin: parameterValues['TTT']?[index],
        windMetersPerSecond: parameterValues['FF']?[index],
        gustMetersPerSecond: parameterValues['FX1']?[index],
        windDirectionDegrees: parameterValues['DD']?[index],
        precipitationMillimeters: parameterValues['RR1c']?[index],
        weatherCode: parameterValues['ww']?[index]?.round(),
        cloudCoverPercent: parameterValues['N']?[index],
      ),
      growable: false,
    );

    return DwdMosmixForecast(
      station: DwdMosmixStation(
        id: id!,
        icao: DwdMosmixStation.konstanz.icao,
        name: name!,
        latitude: latitude,
        longitude: longitude,
        elevationMeters: elevation,
      ),
      issuedAtUtc: _issuedAt(archiveFileName),
      points: points,
    );
  }

  static const _parameters = {'TTT', 'FF', 'FX1', 'DD', 'RR1c', 'ww', 'N'};

  static String? _childText(XmlElement parent, String localName) => parent
      .children
      .whereType<XmlElement>()
      .where((element) => element.name.local == localName)
      .map((element) => element.innerText)
      .firstOrNull;

  static List<double?> _values(String source, int expectedLength) {
    final values = source
        .trim()
        .split(RegExp(r'\s+'))
        .map((raw) {
          if (raw == '-') return null;
          return double.tryParse(raw);
        })
        .toList(growable: false);
    if (values.length != expectedLength) {
      throw FormatException(
        'DWD-Parameter enthält ${values.length} statt $expectedLength Werte.',
      );
    }
    return values;
  }

  static DateTime? _issuedAt(String? archiveFileName) {
    final match = RegExp(r'MOSMIX_L_(\d{4})(\d{2})(\d{2})(\d{2})_')
        .firstMatch(archiveFileName ?? '');
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
    );
  }
}

class DwdMosmixAggregation {
  static final tz.Location _berlin = (() {
    timezone_data.initializeTimeZones();
    return tz.getLocation('Europe/Berlin');
  })();

  /// For today, retain only forecast instants that are still ahead of the
  /// current local time. A partly elapsed day must not be presented as if
  /// 00:00–23:59 were completely forecast.
  static List<DwdDailyForecast> aggregate(
    DwdMosmixForecast forecast, {
    DateTime? nowUtc,
  }) {
    final effectiveNowUtc = (nowUtc ?? DateTime.now()).toUtc();
    final currentLocal = tz.TZDateTime.from(effectiveNowUtc, _berlin);
    final groups = <String, List<DwdForecastPoint>>{};
    final localDates = <String, DateTime>{};
    for (final point in forecast.points) {
      final local = tz.TZDateTime.from(point.timestampUtc, _berlin);
      final isCurrentLocalDay =
          local.year == currentLocal.year &&
          local.month == currentLocal.month &&
          local.day == currentLocal.day;
      if (isCurrentLocalDay && point.timestampUtc.isBefore(effectiveNowUtc)) {
        continue;
      }
      final key = '${local.year}-${local.month}-${local.day}';
      groups.putIfAbsent(key, () => []).add(point);
      localDates[key] = DateTime(local.year, local.month, local.day);
    }
    return groups.entries
        .map((entry) => _daily(localDates[entry.key]!, entry.value))
        .toList(growable: false);
  }

  static DwdDailyForecast _daily(
    DateTime localDate,
    List<DwdForecastPoint> points,
  ) {
    final temperatures = points
        .map((point) => point.temperatureCelsius)
        .whereType<double>()
        .toList(growable: false);
    final winds = points
        .map((point) => point.windKilometersPerHour)
        .whereType<double>()
        .toList(growable: false);
    final gusts = points
        .map((point) => point.gustKilometersPerHour)
        .whereType<double>()
        .toList(growable: false);
    final precipitation = points
        .map((point) => point.precipitationMillimeters)
        .whereType<double>()
        .toList(growable: false);
    final representative = _nearestToLocalNoon(
      points.where((point) => point.windMetersPerSecond != null).toList(),
    );
    final weatherPoint = _nearestToLocalNoon(
      points.where((point) => point.weatherCode != null).toList(),
    );
    final cloudPoint = _nearestToLocalNoon(
      points.where((point) => point.cloudCoverPercent != null).toList(),
    );
    return DwdDailyForecast(
      localDate: localDate,
      points: List.unmodifiable(points),
      temperatureMinimumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce((a, b) => a < b ? a : b),
      temperatureMaximumCelsius: temperatures.isEmpty
          ? null
          : temperatures.reduce((a, b) => a > b ? a : b),
      representativeWindKilometersPerHour:
          representative?.windKilometersPerHour,
      maximumWindKilometersPerHour: winds.isEmpty
          ? null
          : winds.reduce((a, b) => a > b ? a : b),
      maximumGustKilometersPerHour: gusts.isEmpty
          ? null
          : gusts.reduce((a, b) => a > b ? a : b),
      windDirectionDegrees: representative?.windDirectionDegrees,
      precipitationMillimeters: precipitation.isEmpty
          ? null
          : precipitation.reduce((a, b) => a + b),
      weatherCode: weatherPoint?.weatherCode,
      cloudCoverPercent: cloudPoint?.cloudCoverPercent,
    );
  }

  static DwdForecastPoint? _nearestToLocalNoon(List<DwdForecastPoint> points) {
    if (points.isEmpty) return null;
    return points.reduce((closest, candidate) {
      final closestLocal = tz.TZDateTime.from(closest.timestampUtc, _berlin);
      final candidateLocal = tz.TZDateTime.from(
        candidate.timestampUtc,
        _berlin,
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
    final index = ((degrees % 360) / 45).round() % directions.length;
    return directions[index];
  }

  static String? weatherLabel(int? code) {
    if (code == null) return null;
    // The lower WMO present-weather codes describe cloud development, not a
    // directly displayable weather state. Keep them unavailable instead of
    // turning them into an invented condition such as "heiter" or "wolkig".
    if (code == 45 || code == 48) return 'Nebel';
    if (code >= 51 && code <= 57) return 'Nieselregen';
    if (code >= 61 && code <= 67) return 'Regen';
    if (code >= 71 && code <= 77) return 'Schnee';
    if (code >= 80 && code <= 82) return 'Regenschauer';
    if (code >= 95 && code <= 99) return 'Gewitter';
    return null;
  }
}

class DwdForecastService {
  DwdForecastService({http.Client? client}) : _client = client ?? http.Client();

  static const proxyUrl = 'http://127.0.0.1:8787/api/dwd/mosmix/konstanz';
  static const _cacheDuration = Duration(minutes: 30);

  final http.Client _client;
  DwdMosmixForecast? _cached;
  DateTime? _cachedAt;
  Future<DwdMosmixForecast>? _inFlight;

  Future<DwdMosmixForecast> load({bool forceRefresh = false}) {
    if (!forceRefresh &&
        _cached != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheDuration) {
      return Future.value(_cached);
    }
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<DwdMosmixForecast> _load() async {
    final response = await _client
        .get(Uri.parse(proxyUrl))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw DwdForecastException('DWD MOSMIX ist derzeit nicht verfügbar.');
    }
    final forecast = DwdMosmixParser.parseKmz(response.bodyBytes);
    _cached = forecast;
    _cachedAt = DateTime.now();
    return forecast;
  }
}

class DwdForecastException implements Exception {
  const DwdForecastException(this.message);
  final String message;

  @override
  String toString() => message;
}
