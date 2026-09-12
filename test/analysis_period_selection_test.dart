import 'package:flutter_test/flutter_test.dart';

import 'package:bodensee_pegel/analysis_service.dart';
import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:bodensee_pegel/pegelonline_service.dart';
import 'package:bodensee_pegel/vorarlberg_hydro_service.dart';

void main() {
  final service = AnalysisService();

  test('keeps an available analysis period across station changes', () {
    expect(
      service.resolvePeriodForStation(
        BafuHydroService.romanshorn,
        AnalysisPeriod.days30,
      ),
      AnalysisPeriod.days30,
    );
    expect(
      service.resolvePeriodForStation(
        VorarlbergHydroService.bregenz,
        AnalysisPeriod.days30,
      ),
      AnalysisPeriod.days30,
    );
    expect(
      service.resolvePeriodForStation(
        VorarlbergHydroService.bregenz,
        AnalysisPeriod.days7,
      ),
      AnalysisPeriod.days7,
    );
    expect(
      service.resolvePeriodForStation(
        BafuHydroService.romanshorn,
        AnalysisPeriod.hours24,
      ),
      AnalysisPeriod.hours24,
    );
    expect(
      service.resolvePeriodForStation(
        VorarlbergHydroService.bregenz,
        AnalysisPeriod.year1,
      ),
      AnalysisPeriod.year1,
    );
  });

  test(
    'uses the first supported period only when the selection is unavailable',
    () {
      expect(
        service.resolvePeriodForStation(
          VorarlbergHydroService.bregenz,
          AnalysisPeriod.hours24,
        ),
        AnalysisPeriod.days7,
      );
      expect(
        service.resolvePeriodForStation(
          PegelOnlineService.konstanz,
          AnalysisPeriod.year1,
        ),
        AnalysisPeriod.hours24,
      );
    },
  );

  test(
    'annual summary uses the original annual readings and reference day',
    () {
      final comparison = AnnualComparison(
        current: [
          AnalysisReading(timestamp: DateTime(2026, 1, 1), valueCm: 270),
          AnalysisReading(timestamp: DateTime(2026, 1, 2), valueCm: 266),
          AnalysisReading(timestamp: DateTime(2026, 1, 3), valueCm: 272),
        ],
        reference: [
          AnalysisReading(timestamp: DateTime(2026, 1, 1), valueCm: 269),
          AnalysisReading(timestamp: DateTime(2026, 1, 2), valueCm: 269),
          AnalysisReading(timestamp: DateTime(2026, 1, 3), valueCm: 269),
        ],
        referenceLabel: 'Saisonaler Median',
      );

      final summary = AnnualAnalysisSummary.from(comparison);

      expect(summary.currentCm, 272);
      expect(summary.minimumCm, 266);
      expect(summary.maximumCm, 272);
      expect(summary.referenceDifferenceCm, 3);
    },
  );
}
