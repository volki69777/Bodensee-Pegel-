import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pegelonline_service.dart';

class VorarlbergLiveData {
  const VorarlbergLiveData({required this.waterLevelCm, required this.timestamp});

  final double waterLevelCm;
  final DateTime timestamp;
}

/// Official Wasserwirtschaft Vorarlberg data for Bregenz (Seepegel), station
/// 200337. The source already reports the relative water level in centimetres.
class VorarlbergHydroService {
  static const bregenz = PegelStation(
    uuid: 'vowis-200337',
    name: 'BREGENZ',
    waterName: 'BODENSEE',
    source: StationSource.vorarlberg,
  );

  static final _liveProxyEndpoint = Uri.parse(
    'http://127.0.0.1:8787/api/vorarlberg/stations/200337/water-level',
  );

  Future<VorarlbergLiveData> fetchBregenzLiveData() async {
    try {
      final response = await http.get(_liveProxyEndpoint).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw const VorarlbergHydroException();
      final body = jsonDecode(response.body);
      final waterstand = body is Map<String, dynamic> ? body['wasserstand'] : null;
      final rawValue = waterstand is Map<String, dynamic> ? waterstand['wert'] : null;
      final rawTimestamp = waterstand is Map<String, dynamic> ? waterstand['datum'] : null;
      final value = rawValue is num ? rawValue.toDouble() : double.tryParse('$rawValue');
      final timestamp = rawTimestamp is String ? DateTime.tryParse(rawTimestamp) : null;
      if (value == null || timestamp == null) throw const VorarlbergHydroException();
      return VorarlbergLiveData(waterLevelCm: value, timestamp: timestamp);
    } on VorarlbergHydroException {
      rethrow;
    } catch (_) {
      throw const VorarlbergHydroException();
    }
  }
}

class VorarlbergHydroException implements Exception {
  const VorarlbergHydroException();
}
