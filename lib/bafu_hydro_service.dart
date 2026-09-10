import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pegelonline_service.dart';

class BafuReading {
  const BafuReading({required this.waterLevelMasl, required this.timestamp});

  /// Originalwert in Metern über Meer; er wird bewusst nicht umgerechnet.
  final double waterLevelMasl;
  final DateTime timestamp;
}

class BafuLiveData {
  const BafuLiveData({
    required this.current,
    this.history24Hours,
    this.change24Hours,
  });

  final BafuReading current;
  final List<BafuReading>? history24Hours;
  final double? change24Hours;
}

class BafuForecastPoint {
  const BafuForecastPoint({
    required this.timestamp,
    required this.medianMasl,
    required this.minimumMasl,
    required this.maximumMasl,
  });

  final DateTime timestamp;
  final double medianMasl;
  final double minimumMasl;
  final double maximumMasl;
}

class BafuForecastData {
  const BafuForecastData({required this.points, this.issuedLabel});

  final List<BafuForecastPoint> points;
  final String? issuedLabel;
}

class BafuHydroService {
  /// Official conversion offset documented by the former Swiss National
  /// Hydrological and Geological Survey: Romanshorn = Konstanz + 392.23 m.
  static const romanshornReferenceMasl = 392.23;

  static const romanshorn = PegelStation(
    uuid: 'bafu-2032',
    name: 'ROMANSHORN',
    waterName: 'BODENSEE (OBERSEE)',
    source: StationSource.bafu,
    waterLevelReferenceMasl: romanshornReferenceMasl,
  );

  static const _lindasEndpoint = 'https://politics.ld.admin.ch/query/';
  static final _historyProxyEndpoint = Uri.parse(
    'http://127.0.0.1:8787/api/bafu/stations/2032/water-level-history',
  );
  static final _forecastProxyEndpoint = Uri.parse(
    'http://127.0.0.1:8787/api/bafu/stations/2032/water-level-forecast',
  );
  static const _currentQuery = '''
SELECT ?value ?time
FROM <https://lindas.admin.ch/foen/hydro>
WHERE {
  <https://environment.ld.admin.ch/foen/hydro/lake/observation/2032>
    <https://environment.ld.admin.ch/foen/hydro/dimension/waterLevel> ?value ;
    <https://environment.ld.admin.ch/foen/hydro/dimension/measurementTime> ?time .
}''';

  Future<BafuLiveData> fetchRomanshornLiveData() async {
    final current = await _fetchCurrentFromLindas();
    try {
      final availableHistory = await _fetchHistoryFromProxy();
      final target = current.timestamp.subtract(const Duration(hours: 24));
      final history = availableHistory
          .where(
            (reading) =>
                !reading.timestamp.isBefore(target) &&
                !reading.timestamp.isAfter(current.timestamp),
          )
          .toList();
      if (history.length < 2) throw const BafuHydroException();
      final reference = _closestReading(availableHistory, target);
      return BafuLiveData(
        current: current,
        history24Hours: history,
        change24Hours: current.waterLevelMasl - reference.waterLevelMasl,
      );
    } on BafuHydroException {
      // A history outage must never hide the independent LINDAS live reading.
      return BafuLiveData(current: current);
    }
  }

  /// Aktuelle Originalmessung aus dem offiziellen LINDAS-Dienst.
  /// Diese separate Abfrage wird auch für tagesgenaue saisonale Vergleiche
  /// verwendet; eine Jahresreferenz ersetzt niemals eine Live-Messung.
  Future<BafuReading> fetchRomanshornCurrentReading() =>
      _fetchCurrentFromLindas();

  Future<BafuReading> _fetchCurrentFromLindas() async {
    final endpoint = Uri.parse(_lindasEndpoint).replace(
      queryParameters: const {'query': _currentQuery, 'format': 'json'},
    );
    try {
      final response = await http
          .get(endpoint, headers: const {'Accept': 'application/sparql-results+json'})
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw const BafuHydroException();
      final body = jsonDecode(response.body);
      final results = body is Map<String, dynamic> ? body['results'] : null;
      final bindings = results is Map<String, dynamic> ? results['bindings'] : null;
      if (bindings is! List || bindings.isEmpty || bindings.first is! Map<String, dynamic>) {
        throw const BafuHydroException();
      }
      final binding = bindings.first as Map<String, dynamic>;
      final rawValue = binding['value'];
      final rawTime = binding['time'];
      final value = rawValue is Map<String, dynamic> ? double.tryParse('${rawValue['value']}') : null;
      final timestamp = rawTime is Map<String, dynamic> ? DateTime.tryParse('${rawTime['value']}') : null;
      if (value == null || timestamp == null) throw const BafuHydroException();
      return BafuReading(waterLevelMasl: value, timestamp: timestamp);
    } on BafuHydroException {
      rethrow;
    } catch (_) {
      throw const BafuHydroException();
    }
  }

  Future<BafuForecastData> fetchRomanshornForecast() async {
    try {
      final response = await http.get(_forecastProxyEndpoint).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw const BafuHydroException();
      final body = jsonDecode(response.body);
      final plot = body is Map<String, dynamic> ? body['plot'] : null;
      final traces = plot is Map<String, dynamic> ? plot['data'] : null;
      if (traces is! List) throw const BafuHydroException();

      final median = _valuesByTimestamp(_traceWithName(traces, 'Median'));
      final minMaxTraces = traces
          .whereType<Map<String, dynamic>>()
          .where((trace) => trace['name'] == 'Min. / Max.')
          .toList();
      if (median.isEmpty || minMaxTraces.length < 2) throw const BafuHydroException();
      final boundA = _valuesByTimestamp(minMaxTraces[0]);
      final boundB = _valuesByTimestamp(minMaxTraces[1]);
      final points = median.entries
          .where((entry) => boundA.containsKey(entry.key) && boundB.containsKey(entry.key))
          .map(
            (entry) => BafuForecastPoint(
              timestamp: entry.key,
              medianMasl: entry.value,
              minimumMasl: _min(boundA[entry.key]!, boundB[entry.key]!),
              maximumMasl: _max(boundA[entry.key]!, boundB[entry.key]!),
            ),
          )
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (points.length < 2) throw const BafuHydroException();
      final layout = plot['layout'];
      final title = layout is Map<String, dynamic> ? layout['title'] : null;
      return BafuForecastData(points: points, issuedLabel: title is String ? title : null);
    } on BafuHydroException {
      rethrow;
    } catch (_) {
      throw const BafuHydroException();
    }
  }

  Map<DateTime, double> _valuesByTimestamp(Map<String, dynamic>? trace) {
    if (trace == null) throw const BafuHydroException();
    final rawTimes = trace['x'];
    final rawValues = trace['y'];
    if (rawTimes is! List || rawValues is! List || rawTimes.length != rawValues.length) {
      throw const BafuHydroException();
    }
    final values = <DateTime, double>{};
    for (var index = 0; index < rawTimes.length; index++) {
      final rawTime = rawTimes[index];
      final rawValue = rawValues[index];
      final timestamp = rawTime is String ? DateTime.tryParse(rawTime) : null;
      final value = rawValue is num ? rawValue.toDouble() : double.tryParse('$rawValue');
      if (timestamp == null || value == null) throw const BafuHydroException();
      values[timestamp] = value;
    }
    return values;
  }

  Map<String, dynamic>? _traceWithName(List traces, String name) {
    for (final trace in traces) {
      if (trace is Map<String, dynamic> && trace['name'] == name) return trace;
    }
    return null;
  }

  double _min(double a, double b) => a < b ? a : b;

  double _max(double a, double b) => a > b ? a : b;

  Future<List<BafuReading>> _fetchHistoryFromProxy() async {
    try {
      final response = await http.get(_historyProxyEndpoint).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw const BafuHydroException();
      final body = jsonDecode(response.body);
      final rawPoints = body is Map<String, dynamic> ? body['points'] : null;
      if (rawPoints is! List) throw const BafuHydroException();
      final readings = rawPoints.whereType<Map<String, dynamic>>().map((point) {
        final rawValue = point['value'];
        final rawTimestamp = point['timestamp'];
        final value = rawValue is num ? rawValue.toDouble() : double.tryParse('$rawValue');
        final timestamp = rawTimestamp is String ? DateTime.tryParse(rawTimestamp) : null;
        if (value == null || timestamp == null) throw const BafuHydroException();
        return BafuReading(waterLevelMasl: value, timestamp: timestamp);
      }).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (readings.length < 2) throw const BafuHydroException();
      return readings;
    } on BafuHydroException {
      rethrow;
    } catch (_) {
      throw const BafuHydroException();
    }
  }

  BafuReading _closestReading(List<BafuReading> readings, DateTime target) {
    return readings.reduce(
      (closest, candidate) => candidate.timestamp.difference(target).inMilliseconds.abs() <
              closest.timestamp.difference(target).inMilliseconds.abs()
          ? candidate
          : closest,
    );
  }

}

class BafuHydroException implements Exception {
  const BafuHydroException();
}
