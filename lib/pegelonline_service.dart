import 'dart:convert';

import 'package:http/http.dart' as http;

class PegelStation {
  const PegelStation({
    required this.uuid,
    required this.name,
    this.waterName,
    this.source = StationSource.pegelOnline,
    this.unit = 'cm',
    this.waterLevelReferenceMasl,
  });

  final String uuid;
  final String name;
  final String? waterName;
  final StationSource source;
  final String unit;
  final double? waterLevelReferenceMasl;
}

enum StationSource { pegelOnline, bafu, vorarlberg }

class PegelReading {
  const PegelReading({
    required this.waterLevelCm,
    required this.timestamp,
    this.officialState,
  });

  final double waterLevelCm;
  final DateTime timestamp;
  final String? officialState;

  String get formattedWaterLevel => waterLevelCm == waterLevelCm.roundToDouble()
      ? waterLevelCm.round().toString()
      : waterLevelCm.toStringAsFixed(1).replaceAll('.', ',');

  String get formattedTime {
    final localTime = timestamp.toLocal();
    final hour = localTime.hour.toString().padLeft(2, '0');
    final minute = localTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class PegelLiveData {
  const PegelLiveData({
    required this.current,
    this.history24Hours,
    this.change24Hours,
  });

  final PegelReading current;
  final List<PegelReading>? history24Hours;
  final double? change24Hours;
}

class PegelOnlineService {
  static const konstanz = PegelStation(
    uuid: 'aa9179c1-17ef-4c61-a48a-74193fa7bfdf',
    name: 'KONSTANZ',
    waterName: 'BODENSEE',
  );

  static const _baseUrl = 'https://pegelonline.wsv.de/webservices/rest-api/v2';

  Future<List<PegelStation>> fetchBodenseeStations() async {
    final endpoint = Uri.parse('$_baseUrl/stations.json').replace(
      queryParameters: const {
        'waters': 'BODENSEE',
        'includeTimeseries': 'true',
        'includeCurrentMeasurement': 'true',
      },
    );
    try {
      final response = await http.get(endpoint).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw const PegelOnlineException();
      }
      final body = jsonDecode(response.body);
      if (body is! List) {
        throw const PegelOnlineException();
      }
      final stations = body
          .whereType<Map<String, dynamic>>()
          .map((json) {
            final uuid = json['uuid'];
            final name = json['longname'];
            final water = json['water'];
            final waterName = water is Map<String, dynamic>
                ? water['longname'] as String?
                : null;
            return uuid is String && name is String
                ? PegelStation(
                    uuid: uuid,
                    name: name,
                    waterName: waterName,
                  )
                : null;
          })
          .whereType<PegelStation>()
          .toList();
      if (stations.isEmpty) {
        throw const PegelOnlineException();
      }
      return stations;
    } on PegelOnlineException {
      rethrow;
    } catch (_) {
      throw const PegelOnlineException();
    }
  }

  Future<PegelLiveData> fetchLiveData(PegelStation station) async {
    final current = await _fetchCurrentMeasurement(station.uuid);
    List<PegelReading>? history;
    try {
      history = await _fetchHistory24Hours(
        station.uuid,
        current.timestamp,
      );
    } on PegelOnlineException {
      history = null;
    }
    final reference = history == null
        ? null
        : _closestReading(history, current.timestamp.subtract(const Duration(hours: 24)));
    return PegelLiveData(
      current: current,
      history24Hours: history,
      change24Hours: reference == null ? null : current.waterLevelCm - reference.waterLevelCm,
    );
  }

  Future<PegelReading> _fetchCurrentMeasurement(String stationUuid) async {
    final endpoint = Uri.parse('$_baseUrl/stations/$stationUuid/W/currentmeasurement.json');
    final response = await _get(endpoint);
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const PegelOnlineException();
    }
    return _readingFromJson(body, includeOfficialState: true);
  }

  Future<List<PegelReading>> _fetchHistory24Hours(
    String stationUuid,
    DateTime currentTimestamp,
  ) async {
    final startTimestamp = currentTimestamp.subtract(const Duration(hours: 24));
    final endpoint = Uri.parse('$_baseUrl/stations/$stationUuid/W/measurements.json').replace(
      queryParameters: {
        'start': startTimestamp.toIso8601String(),
        'end': currentTimestamp.toIso8601String(),
      },
    );
    final response = await _get(endpoint);
    final body = jsonDecode(response.body);
    if (body is! List) {
      throw const PegelOnlineException();
    }

    final readings = body
        .whereType<Map<String, dynamic>>()
        .map(_readingFromJson)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (readings.isEmpty) {
      throw const PegelOnlineException();
    }
    return readings;
  }

  PegelReading? _closestReading(List<PegelReading> readings, DateTime targetTimestamp) {
    PegelReading? closest;
    for (final reading in readings) {
      if (closest == null ||
          reading.timestamp.difference(targetTimestamp).inMilliseconds.abs() <
              closest.timestamp.difference(targetTimestamp).inMilliseconds.abs()) {
        closest = reading;
      }
    }
    return closest;
  }

  Future<http.Response> _get(Uri endpoint) async {
    try {
      final response = await http.get(endpoint).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw const PegelOnlineException();
      }
      return response;
    } on PegelOnlineException {
      rethrow;
    } catch (_) {
      throw const PegelOnlineException();
    }
  }

  PegelReading _readingFromJson(
    Map<String, dynamic> json, {
    bool includeOfficialState = false,
  }) {
    final rawValue = json['value'];
    final rawTimestamp = json['timestamp'];
    final value = rawValue is num ? rawValue.toDouble() : double.tryParse('$rawValue');
    final timestamp = rawTimestamp is String ? DateTime.tryParse(rawTimestamp) : null;
    if (value == null || timestamp == null) {
      throw const PegelOnlineException();
    }
    final state = includeOfficialState && json['stateMnwMhw'] is String
        ? json['stateMnwMhw'] as String
        : null;
    return PegelReading(
      waterLevelCm: value,
      timestamp: timestamp,
      officialState: state,
    );
  }
}

class PegelOnlineException implements Exception {
  const PegelOnlineException();
}
