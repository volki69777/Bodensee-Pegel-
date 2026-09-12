import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'bafu_hydro_service.dart';
import 'pegelonline_service.dart';
import 'station_data_cache.dart';

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
    this.annualComparison,
  });

  final List<AnalysisReading> readings;
  final AnalysisPeriod period;
  final SeasonalReference? seasonalReference;
  final AnnualComparison? annualComparison;
}

/// Official comparison series published for a calendar-year chart.
///
/// All values are already in the station's displayed centimetre reference.
/// No values are interpolated or derived for the chart.
class AnnualComparison {
  const AnnualComparison({
    required this.current,
    this.previous,
    this.reference,
    this.band,
    required this.referenceLabel,
  });

  final List<AnalysisReading> current;
  final List<AnalysisReading>? previous;
  final List<AnalysisReading>? reference;
  final List<AnalysisBandPoint>? band;
  final String referenceLabel;
}

class AnalysisBandPoint {
  const AnalysisBandPoint({
    required this.timestamp,
    required this.lowerCm,
    required this.upperCm,
  });

  final DateTime timestamp;
  final double lowerCm;
  final double upperCm;
}

class AnnualAnalysisSummary {
  const AnnualAnalysisSummary({
    required this.currentCm,
    required this.minimumCm,
    required this.maximumCm,
    this.referenceDifferenceCm,
  });

  final double currentCm;
  final double minimumCm;
  final double maximumCm;
  final double? referenceDifferenceCm;

  static AnnualAnalysisSummary from(AnnualComparison comparison) {
    final current = comparison.current.last;
    final values = comparison.current.map((reading) => reading.valueCm);
    final reference = _valueOnCalendarDay(
      comparison.reference,
      current.timestamp,
    );
    return AnnualAnalysisSummary(
      currentCm: current.valueCm,
      minimumCm: values.reduce(math.min),
      maximumCm: values.reduce(math.max),
      referenceDifferenceCm: reference == null
          ? null
          : current.valueCm - reference,
    );
  }

  static double? _valueOnCalendarDay(
    List<AnalysisReading>? readings,
    DateTime timestamp,
  ) {
    if (readings == null) return null;
    for (final reading in readings) {
      if (reading.timestamp.month == timestamp.month &&
          reading.timestamp.day == timestamp.day) {
        return reading.valueCm;
      }
    }
    return null;
  }
}

/// Produces a calmer, display-only version of an analysis series.
///
/// The source readings are never changed. All aggregated and moving-average
/// values stay inside the original value range, so the visual line cannot
/// invent an extreme above the observed maximum or below the observed minimum.
abstract final class AnalysisDisplaySmoother {
  static List<AnalysisReading> smooth(
    List<AnalysisReading> readings,
    AnalysisPeriod period,
  ) {
    if (readings.length < 3) return readings;
    final condensed = _condense(readings, _targetPointCount(period));
    final radius = switch (period) {
      AnalysisPeriod.hours24 => 1,
      AnalysisPeriod.days7 => 2,
      AnalysisPeriod.days30 => 3,
      AnalysisPeriod.year1 => 1,
    };
    if (radius == 0 || condensed.length < 3) return condensed;

    return List.generate(condensed.length, (index) {
      // Keep the endpoints exact so the chart still begins and ends at the
      // actual displayed time and latest measured value.
      if (index == 0 || index == condensed.length - 1) return condensed[index];
      final from = math.max(0, index - radius);
      final to = math.min(condensed.length - 1, index + radius);
      var total = 0.0;
      for (var point = from; point <= to; point++) {
        total += condensed[point].valueCm;
      }
      return AnalysisReading(
        timestamp: condensed[index].timestamp,
        valueCm: total / (to - from + 1),
      );
    });
  }

  static int _targetPointCount(AnalysisPeriod period) => switch (period) {
    AnalysisPeriod.hours24 => 1000000,
    AnalysisPeriod.days7 => 220,
    AnalysisPeriod.days30 => 260,
    AnalysisPeriod.year1 => 1000000,
  };

  static List<AnalysisReading> _condense(
    List<AnalysisReading> readings,
    int targetCount,
  ) {
    if (readings.length <= targetCount) return readings;
    final result = <AnalysisReading>[];
    for (var bucket = 0; bucket < targetCount; bucket++) {
      final from = (bucket * readings.length / targetCount).floor();
      final to = math.min(
        readings.length,
        ((bucket + 1) * readings.length / targetCount).ceil(),
      );
      if (to <= from) continue;
      final bucketReadings = readings.sublist(from, to);
      if (bucket == 0) {
        result.add(readings.first);
        continue;
      }
      if (bucket == targetCount - 1) {
        result.add(readings.last);
        continue;
      }
      final averageValue =
          bucketReadings
              .map((reading) => reading.valueCm)
              .reduce((sum, value) => sum + value) /
          bucketReadings.length;
      final midpoint = bucketReadings[bucketReadings.length ~/ 2];
      result.add(
        AnalysisReading(timestamp: midpoint.timestamp, valueCm: averageValue),
      );
    }
    return result;
  }
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
  static final _annualCache = StationDataCache<AnnualComparison>(
    ttl: const Duration(minutes: 10),
  );
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
          AnalysisPeriod.year1,
        ],
      };

  /// Keeps the current selection when the destination station supports it.
  /// A fallback is only needed when that period is not available there.
  AnalysisPeriod resolvePeriodForStation(
    PegelStation station,
    AnalysisPeriod currentPeriod,
  ) {
    final availablePeriods = periodsFor(station);
    return availablePeriods.contains(currentPeriod)
        ? currentPeriod
        : availablePeriods.first;
  }

  Future<AnalysisSeries> fetch(
    PegelStation station,
    AnalysisPeriod period,
  ) async {
    if (!periodsFor(station).contains(period)) {
      throw const AnalysisException();
    }
    if (period == AnalysisPeriod.year1) {
      final annualComparison = switch (station.source) {
        StationSource.bafu => _annualCache.get(
          'bafu-2032-${DateTime.now().year}',
          _fetchRomanshornAnnual,
        ),
        StationSource.vorarlberg => _annualCache.get(
          'vowis-200337-${DateTime.now().year}',
          _fetchBregenzAnnual,
        ),
        StationSource.pegelOnline => throw const AnalysisException(),
      };
      final comparison = await annualComparison;
      if (comparison.current.length < 2) throw const AnalysisException();
      return AnalysisSeries(
        readings: comparison.current,
        period: period,
        annualComparison: comparison,
      );
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

  Future<AnnualComparison> _fetchRomanshornAnnual() async {
    final currentYear = DateTime.now().year;
    final body = await _getJson(
      Uri.parse(
        '$_proxyBase/api/bafu/stations/2032/water-level-annual?year=${currentYear - 1}',
      ),
    );
    final plot = body is Map<String, dynamic> ? body['plot'] : null;
    final traces = plot is Map<String, dynamic> ? plot['data'] : null;
    if (traces is! List) throw const AnalysisException();
    final current = _annualTrace(
      traces,
      '$currentYear',
      displayYear: currentYear,
      referenceMasl: BafuHydroService.romanshornReferenceMasl,
    );
    final previous = _annualTrace(
      traces,
      '${currentYear - 1}',
      displayYear: currentYear,
      referenceMasl: BafuHydroService.romanshornReferenceMasl,
    );
    final median = _annualTrace(
      traces,
      'Median',
      displayYear: currentYear,
      referenceMasl: BafuHydroService.romanshornReferenceMasl,
    );
    final band = _annualBand(
      traces,
      '05.-95. Perzentil',
      displayYear: currentYear,
      referenceMasl: BafuHydroService.romanshornReferenceMasl,
    );
    if (current.length < 2 ||
        previous.length < 2 ||
        median.length < 2 ||
        band.length < 2) {
      throw const AnalysisException();
    }
    return AnnualComparison(
      current: current,
      previous: previous,
      reference: median,
      band: band,
      referenceLabel: 'Saisonaler Median',
    );
  }

  Future<List<AnalysisReading>> _fetchBregenz(AnalysisPeriod period) async {
    final annual = await _annualCache.get(
      'vowis-200337-${DateTime.now().year}',
      _fetchBregenzAnnual,
    );
    return _sortAndFilter(annual.current, period);
  }

  Future<AnnualComparison> _fetchBregenzAnnual() async {
    final body = await _getJson(
      Uri.parse(
        '$_proxyBase/api/vorarlberg/stations/200337/water-level-annual',
      ),
    );
    final rawSeries = body is Map<String, dynamic> ? body['series'] : null;
    if (rawSeries is! List) throw const AnalysisException();
    final currentYear = DateTime.now().year;
    final current = _vorarlbergAnnualTrace(
      rawSeries,
      'WAktuell',
      displayYear: currentYear,
    );
    final average = _vorarlbergAnnualTrace(
      rawSeries,
      'Mittel',
      displayYear: currentYear,
    );
    final minimum = _vorarlbergAnnualTrace(
      rawSeries,
      'Minimum',
      displayYear: currentYear,
    );
    final maximum = _vorarlbergAnnualTrace(
      rawSeries,
      'Maximum',
      displayYear: currentYear,
    );
    final band = _combineBand(minimum, maximum);
    if (current.length < 2 || average.length < 2 || band.length < 2) {
      throw const AnalysisException();
    }
    return AnnualComparison(
      current: current,
      reference: average,
      band: band,
      referenceLabel: 'Langjähriges Mittel',
    );
  }

  List<AnalysisReading> _annualTrace(
    List traces,
    String traceName, {
    required int displayYear,
    required double referenceMasl,
  }) {
    Map<String, dynamic>? trace;
    for (final candidate in traces.whereType<Map<String, dynamic>>()) {
      if ('${candidate['name']}' == traceName) {
        trace = candidate;
        break;
      }
    }
    final times = trace?['x'];
    final values = trace?['y'];
    if (times is! List || values is! List || times.length != values.length) {
      return const [];
    }
    final readings = <AnalysisReading>[];
    for (var index = 0; index < times.length; index++) {
      final sourceTime = _time(times[index]);
      final valueMasl = _number(values[index]);
      if (sourceTime == null || valueMasl == null) continue;
      readings.add(
        AnalysisReading(
          timestamp: DateTime(displayYear, sourceTime.month, sourceTime.day),
          valueCm: (valueMasl - referenceMasl) * 100,
        ),
      );
    }
    return _sortByTimestamp(readings);
  }

  List<AnalysisBandPoint> _annualBand(
    List traces,
    String traceName, {
    required int displayYear,
    required double referenceMasl,
  }) {
    final valuesByDay = <String, List<double>>{};
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
    for (var index = 0; index < times.length; index++) {
      final timestamp = _time(times[index]);
      final value = _number(values[index]);
      if (timestamp == null || value == null) continue;
      final key = '${timestamp.month}-${timestamp.day}';
      valuesByDay.putIfAbsent(key, () => []).add(value);
    }
    final band = <AnalysisBandPoint>[];
    valuesByDay.forEach((key, values) {
      final parts = key.split('-');
      final month = int.parse(parts[0]);
      final day = int.parse(parts[1]);
      band.add(
        AnalysisBandPoint(
          timestamp: DateTime(displayYear, month, day),
          lowerCm: (values.reduce(math.min) - referenceMasl) * 100,
          upperCm: (values.reduce(math.max) - referenceMasl) * 100,
        ),
      );
    });
    band.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return band;
  }

  List<AnalysisReading> _vorarlbergAnnualTrace(
    List series,
    String traceName, {
    required int displayYear,
  }) {
    Map<String, dynamic>? trace;
    for (final candidate in series.whereType<Map<String, dynamic>>()) {
      if (candidate['name'] == traceName) {
        trace = candidate;
        break;
      }
    }
    final points = trace?['data'];
    if (points is! List) return const [];
    final readings = <AnalysisReading>[];
    for (final point in points.whereType<Map<String, dynamic>>()) {
      final timestamp = _time(point['x']);
      final value = _number(point['y']);
      if (timestamp == null || value == null || value == 0) continue;
      readings.add(
        AnalysisReading(
          timestamp: DateTime(displayYear, timestamp.month, timestamp.day),
          valueCm: value,
        ),
      );
    }
    return _sortByTimestamp(readings);
  }

  List<AnalysisBandPoint> _combineBand(
    List<AnalysisReading> lower,
    List<AnalysisReading> upper,
  ) {
    final upperByDay = <String, double>{
      for (final point in upper)
        '${point.timestamp.month}-${point.timestamp.day}': point.valueCm,
    };
    return lower
        .where(
          (point) => upperByDay.containsKey(
            '${point.timestamp.month}-${point.timestamp.day}',
          ),
        )
        .map(
          (point) => AnalysisBandPoint(
            timestamp: point.timestamp,
            lowerCm: point.valueCm,
            upperCm:
                upperByDay['${point.timestamp.month}-${point.timestamp.day}']!,
          ),
        )
        .toList();
  }

  List<AnalysisReading> _sortByTimestamp(List<AnalysisReading> readings) {
    final values = <DateTime, AnalysisReading>{
      for (final reading in readings) reading.timestamp: reading,
    }.values.toList();
    values.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return values;
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
