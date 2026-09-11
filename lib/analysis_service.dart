import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bafu_hydro_service.dart';
import 'pegelonline_service.dart';

enum AnalysisPeriod {
  hours24('24 h', Duration(hours: 24)),
  days7('7 Tage', Duration(days: 7)),
  days30('30 Tage', Duration(days: 30)),
  year1('1 Jahr', Duration(days: 365));

  const AnalysisPeriod(this.label, this.duration);

  final String label;
  final Duration duration;
}

class AnalysisReading {
  const AnalysisReading({required this.timestamp, required this.valueCm});

  final DateTime timestamp;
  final double valueCm;
}

class AnalysisSeries {
  const AnalysisSeries({
    required this.readings,
    required this.period,
    this.seasonalReference,
  });

  final List<AnalysisReading> readings;
  final AnalysisPeriod period;
  final SeasonalReference? seasonalReference;
}

class SeasonalReference {
  const SeasonalReference({
    required this.currentCm,
    required this.medianCm,
    this.lowerCm,
    this.upperCm,
  });

  final double currentCm;
  final double medianCm;
  final double? lowerCm;
  final double? upperCm;

  double get differenceCm => currentCm - medianCm;

  bool get isWithinNormalRange =>
      lowerCm != null &&
      upperCm != null &&
      currentCm >= lowerCm! &&
      currentCm <= upperCm!;
}

class AnalysisService {
  static const _pegelOnlineBase =
      'https://pegelonline.wsv.de/webservices/rest-api/v2';
  static const _proxyBase = 'http://127.0.0.1:8787';
  final BafuHydroService _bafuService = BafuHydroService();

  List<AnalysisPeriod> periodsFor(PegelStation station) =>
      switch (station.source) {
        StationSource.pegelOnline => const [
          AnalysisPeriod.hours24,
          AnalysisPeriod.days7,
          AnalysisPeriod.days30,
        ],
        StationSource.bafu => const [
          AnalysisPeriod.hours24,
          AnalysisPeriod.days7,
          AnalysisPeriod.days30,
          AnalysisPeriod.year1,
        ],
        StationSource.vorarlberg => const [
          AnalysisPeriod.days7,
          AnalysisPeriod.days30,
        ],
      };

  Future<AnalysisSeries> fetch(
    PegelStation station,
    AnalysisPeriod period,
  ) async {
    if (!periodsFor(station).contains(period)) {
      throw const AnalysisException();
    }
    final readings = switch (station.source) {
      StationSource.pegelOnline => await _fetchKonstanz(station, period),
      StationSource.bafu => await _fetchRomanshorn(period),
      StationSource.vorarlberg => await _fetchBregenz(period),
    };
    if (readings.length < 2) throw const AnalysisException();
    SeasonalReference? seasonalReference;
    if (station.source == StationSource.bafu) {
      try {
        seasonalReference = await _fetchRomanshornSeasonalReference();
      } on AnalysisException {
        // Die Zeitreihe bleibt nutzbar, auch wenn die zusätzliche Referenz
        // vorübergehend nicht abgerufen werden kann.
      }
    }
    return AnalysisSeries(
      readings: readings,
      period: period,
      seasonalReference: seasonalReference,
    );
  }

  /// Returns the official BAFU calendar-day reference for Romanshorn without
  /// loading a separate chart series.
  Future<SeasonalReference> fetchRomanshornSeasonalReference() =>
      _fetchRomanshornSeasonalReference();

  Future<SeasonalReference> _fetchRomanshornSeasonalReference() async {
    try {
      final current = await _bafuService.fetchRomanshornCurrentReading();
      final referenceYear = DateTime.now().year - 1;
      final body = await _getJson(
        Uri.parse(
          '$_proxyBase/api/bafu/stations/2032/water-level-annual?year=$referenceYear',
        ),
      );
      final plot = body is Map<String, dynamic> ? body['plot'] : null;
      final traces = plot is Map<String, dynamic> ? plot['data'] : null;
      if (traces is! List) throw const AnalysisException();

      final currentDay = current.timestamp.toLocal();
      final median = _valueForCalendarDay(traces, 'Median', currentDay);
      if (median == null) throw const AnalysisException();
      final percentileValues = _valuesForCalendarDay(
        traces,
        '05.-95. Perzentil',
        currentDay,
      );
      final reference = BafuHydroService.romanshornReferenceMasl;
      return SeasonalReference(
        currentCm: (current.waterLevelMasl - reference) * 100,
        medianCm: (median - reference) * 100,
        lowerCm: percentileValues.isEmpty
            ? null
            : (percentileValues.reduce(_min) - reference) * 100,
        upperCm: percentileValues.isEmpty
            ? null
            : (percentileValues.reduce(_max) - reference) * 100,
      );
    } on AnalysisException {
      rethrow;
    } catch (_) {
      throw const AnalysisException();
    }
  }

  double? _valueForCalendarDay(List traces, String traceName, DateTime day) {
    final values = _valuesForCalendarDay(traces, traceName, day);
    return values.length == 1 ? values.single : null;
  }

  List<double> _valuesForCalendarDay(
    List traces,
    String traceName,
    DateTime day,
  ) {
    Map<String, dynamic>? trace;
    for (final candidate in traces.whereType<Map<String, dynamic>>()) {
      if (candidate['name'] == traceName) {
        trace = candidate;
        break;
      }
    }
    final times = trace?['x'];
    final values = trace?['y'];
    if (times is! List || values is! List || times.length != values.length) {
      return const [];
    }
    final matches = <double>[];
    for (var index = 0; index < times.length; index++) {
      final timestamp = _time(times[index]);
      final value = _number(values[index]);
      if (timestamp != null &&
          value != null &&
          timestamp.month == day.month &&
          timestamp.day == day.day) {
        matches.add(value);
      }
    }
    return matches;
  }

  double _min(double a, double b) => a < b ? a : b;

  double _max(double a, double b) => a > b ? a : b;

  Future<List<AnalysisReading>> _fetchKonstanz(
    PegelStation station,
    AnalysisPeriod period,
  ) async {
    final now = DateTime.now();
    final endpoint =
        Uri.parse(
          '$_pegelOnlineBase/stations/${station.uuid}/W/measurements.json',
        ).replace(
          queryParameters: {
            'start': now.subtract(period.duration).toIso8601String(),
            'end': now.toIso8601String(),
          },
        );
    final body = await _getJson(endpoint);
    if (body is! List) throw const AnalysisException();
    return _sortAndFilter(
      body.whereType<Map<String, dynamic>>().map((point) {
        final value = _number(point['value']);
        final timestamp = _time(point['timestamp']);
        if (value == null || timestamp == null) {
          throw const AnalysisException();
        }
        return AnalysisReading(timestamp: timestamp, valueCm: value);
      }),
      period,
    );
  }

  Future<List<AnalysisReading>> _fetchRomanshorn(AnalysisPeriod period) async {
    if (period == AnalysisPeriod.year1) return _fetchRomanshornYear();
    final range = period == AnalysisPeriod.days30 ? '40d' : '7d';
    final body = await _getJson(
      Uri.parse(
        '$_proxyBase/api/bafu/stations/2032/water-level-history?range=$range',
      ),
    );
    final points = body is Map<String, dynamic> ? body['points'] : null;
    if (points is! List) throw const AnalysisException();
    return _sortAndFilter(
      points.whereType<Map<String, dynamic>>().map((point) {
        final valueMasl = _number(point['value']);
        final timestamp = _time(point['timestamp']);
        if (valueMasl == null || timestamp == null) {
          throw const AnalysisException();
        }
        return AnalysisReading(
          timestamp: timestamp,
          valueCm: (valueMasl - BafuHydroService.romanshornReferenceMasl) * 100,
        );
      }),
      period,
    );
  }

  Future<List<AnalysisReading>> _fetchRomanshornYear() async {
    final currentYear = DateTime.now().year;
    final body = await _getJson(
      Uri.parse(
        '$_proxyBase/api/bafu/stations/2032/water-level-annual?year=${currentYear - 1}',
      ),
    );
    final plot = body is Map<String, dynamic> ? body['plot'] : null;
    final traces = plot is Map<String, dynamic> ? plot['data'] : null;
    if (traces is! List) throw const AnalysisException();
    final readings = <AnalysisReading>[];
    for (final trace in traces.whereType<Map<String, dynamic>>()) {
      final label = trace['name'];
      final sourceYear = label is int
          ? label
          : label is String
          ? int.tryParse(label)
          : null;
      if (sourceYear != currentYear && sourceYear != currentYear - 1) {
        continue;
      }
      final times = trace['x'];
      final values = trace['y'];
      if (times is! List || values is! List || times.length != values.length) {
        continue;
      }
      for (var index = 0; index < times.length; index++) {
        final displayedTime = _time(times[index]);
        final valueMasl = _number(values[index]);
        if (displayedTime == null || valueMasl == null) continue;
        final timestamp = DateTime(
          sourceYear!,
          displayedTime.month,
          displayedTime.day,
        );
        readings.add(
          AnalysisReading(
            timestamp: timestamp,
            valueCm:
                (valueMasl - BafuHydroService.romanshornReferenceMasl) * 100,
          ),
        );
      }
    }
    return _sortAndFilter(readings, AnalysisPeriod.year1);
  }

  Future<List<AnalysisReading>> _fetchBregenz(AnalysisPeriod period) async {
    final body = await _getJson(
      Uri.parse(
        '$_proxyBase/api/vorarlberg/stations/200337/water-level-annual',
      ),
    );
    final series = body is Map<String, dynamic> ? body['series'] : null;
    if (series is! List) throw const AnalysisException();
    Map<String, dynamic>? current;
    for (final candidate in series.whereType<Map<String, dynamic>>()) {
      if (candidate['name'] == 'WAktuell') current = candidate;
    }
    final points = current?['data'];
    if (points is! List) throw const AnalysisException();
    final readings = <AnalysisReading>[];
    for (final point in points.whereType<Map<String, dynamic>>()) {
      final value = _number(point['y']);
      final timestamp = _time(point['x']);
      if (value != null && timestamp != null && value != 0) {
        readings.add(AnalysisReading(timestamp: timestamp, valueCm: value));
      }
    }
    return _sortAndFilter(readings, period);
  }

  List<AnalysisReading> _sortAndFilter(
    Iterable<AnalysisReading> source,
    AnalysisPeriod period,
  ) {
    final byTimestamp = <DateTime, AnalysisReading>{};
    for (final reading in source) {
      byTimestamp[reading.timestamp] = reading;
    }
    final threshold = DateTime.now().subtract(period.duration);
    final readings =
        byTimestamp.values
            .where((reading) => !reading.timestamp.isBefore(threshold))
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return readings;
  }

  Future<dynamic> _getJson(Uri endpoint) async {
    try {
      final response = await http
          .get(endpoint)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw const AnalysisException();
      return jsonDecode(response.body);
    } catch (_) {
      throw const AnalysisException();
    }
  }

  double? _number(Object? value) => value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;

  DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

class AnalysisException implements Exception {
  const AnalysisException();
}
