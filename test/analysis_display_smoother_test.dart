import 'package:flutter_test/flutter_test.dart';

import 'package:bodensee_pegel/analysis_service.dart';

void main() {
  List<AnalysisReading> readings(int count) => List.generate(
    count,
    (index) => AnalysisReading(
      timestamp: DateTime(2026, 8, 12).add(Duration(minutes: 15 * index)),
      valueCm: 270 + (index % 7).toDouble(),
    ),
  );

  test('30-day display smoothing preserves raw endpoints and bounds', () {
    final source = readings(720);
    final sourceValues = source.map((reading) => reading.valueCm).toList();

    final display = AnalysisDisplaySmoother.smooth(
      source,
      AnalysisPeriod.days30,
    );

    expect(display.length, lessThanOrEqualTo(260));
    expect(display.first.timestamp, source.first.timestamp);
    expect(display.first.valueCm, source.first.valueCm);
    expect(display.last.timestamp, source.last.timestamp);
    expect(display.last.valueCm, source.last.valueCm);
    expect(
      display.every(
        (reading) =>
            reading.valueCm >= sourceValues.reduce((a, b) => a < b ? a : b) &&
            reading.valueCm <= sourceValues.reduce((a, b) => a > b ? a : b),
      ),
      isTrue,
    );
    expect(
      source.map((reading) => reading.valueCm),
      orderedEquals(sourceValues),
    );
  });

  test(
    '24-hour display keeps original point count with only light smoothing',
    () {
      final source = readings(96);

      final display = AnalysisDisplaySmoother.smooth(
        source,
        AnalysisPeriod.hours24,
      );

      expect(display, hasLength(source.length));
      expect(display.first.valueCm, source.first.valueCm);
      expect(display.last.valueCm, source.last.valueCm);
    },
  );
}
