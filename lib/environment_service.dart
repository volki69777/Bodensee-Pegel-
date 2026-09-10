import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pegelonline_service.dart';

class EnvironmentStationConfig {
  const EnvironmentStationConfig({
    required this.stationUuid,
    required this.windSourceLabel,
    required this.airSourceLabel,
    this.waterTemperatureDepthLabel,
  });

  final String stationUuid;
  final String windSourceLabel;
  final String airSourceLabel;
  final String? waterTemperatureDepthLabel;
}

class StationEnvironmentData {
  const StationEnvironmentData({
    this.waterTemperatureC,
    this.windSpeedMetersPerSecond,
    this.windDirectionDegrees,
    this.airTemperatureC,
  });

  final double? waterTemperatureC;
  final double? windSpeedMetersPerSecond;
  final double? windDirectionDegrees;
  final double? airTemperatureC;
}

/// Official, station-specific environmental data sources. The local proxy
/// normalises the different authorities' data formats for Flutter Web.
class EnvironmentService {
  static const _proxyBaseUrl = 'http://127.0.0.1:8787/api/environment';

  static const konstanz = EnvironmentStationConfig(
    stationUuid: 'aa9179c1-17ef-4c61-a48a-74193fa7bfdf',
    windSourceLabel: 'DWD 02712',
    airSourceLabel: 'DWD 02712',
  );
  static const romanshorn = EnvironmentStationConfig(
    stationUuid: 'bafu-2032',
    windSourceLabel: 'Güttingen',
    airSourceLabel: 'Güttingen',
  );
  static const bregenz = EnvironmentStationConfig(
    stationUuid: 'vowis-200337',
    windSourceLabel: 'See-Messstation',
    airSourceLabel: 'See-Messstation',
    waterTemperatureDepthLabel: '0,5 m Tiefe',
  );

  static const stationConfigs = <EnvironmentStationConfig>[konstanz, romanshorn, bregenz];

  EnvironmentStationConfig configFor(PegelStation station) => stationConfigs.firstWhere(
        (config) => config.stationUuid == station.uuid,
      );

  Future<StationEnvironmentData> fetchFor(PegelStation station) async {
    final config = configFor(station);
    final endpoint = Uri.parse('$_proxyBaseUrl/${config.stationUuid}');
    try {
      final response = await http.get(endpoint).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw const EnvironmentException();
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) throw const EnvironmentException();
      return StationEnvironmentData(
        waterTemperatureC: _numberIn(body, 'waterTemperatureC'),
        windSpeedMetersPerSecond: _numberIn(body, 'windSpeedMetersPerSecond'),
        windDirectionDegrees: _numberIn(body, 'windDirectionDegrees'),
        airTemperatureC: _numberIn(body, 'airTemperatureC'),
      );
    } on EnvironmentException {
      rethrow;
    } catch (_) {
      throw const EnvironmentException();
    }
  }

  double? _numberIn(Map<String, dynamic> body, String key) {
    final value = body[key];
    return value is num ? value.toDouble() : double.tryParse('$value');
  }
}

class EnvironmentException implements Exception {
  const EnvironmentException();
}
