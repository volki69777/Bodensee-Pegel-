import 'package:bodensee_pegel/analysis_service.dart';
import 'package:bodensee_pegel/bafu_hydro_service.dart';
import 'package:bodensee_pegel/insight_service.dart';
import 'package:bodensee_pegel/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = InsightService();
  final now = DateTime.utc(2026, 9, 11, 12);

  group('24-hour trend boundaries', () {
    test('one centimetre is stable', () {
      expect(InsightService.trend24Hours(1), InsightTrend.stable);
    });
    test('1.1 centimetres is a light rise', () {
      expect(InsightService.trend24Hours(1.1), InsightTrend.lightRise);
    });
    test('four centimetres is a strong rise', () {
      expect(InsightService.trend24Hours(4), InsightTrend.strongRise);
    });
    test('a light fall uses the concise neutral text', () {
      expect(
        service.fromKonstanz(change24HoursCm: -2)?.text,
        'Der Pegel ist in den letzten 24 Stunden leicht gefallen.',
      );
    });
    test('a strong rise uses the concise neutral text', () {
      expect(
        service.fromKonstanz(change24HoursCm: 4)?.text,
        'Der Pegel ist in den letzten 24 Stunden deutlich gestiegen.',
      );
    });
  });

  group('7-day trend boundaries', () {
    test('two centimetres is stable', () {
      expect(InsightService.trend7Days(-2), InsightTrend.stable);
    });
    test('2.1 centimetres is a light fall', () {
      expect(InsightService.trend7Days(-2.1), InsightTrend.lightFall);
    });
    test('eight centimetres is a strong fall', () {
      expect(InsightService.trend7Days(-8), InsightTrend.strongFall);
    });
  });

  test('Romanshorn seasonal range takes priority', () {
    final insight = service.fromRomanshorn(
      change24HoursCm: 6,
      currentTimestamp: now,
      seasonalReference: const SeasonalReference(
        currentCm: 240,
        medianCm: 250,
        lowerCm: 245,
        upperCm: 260,
      ),
      forecast: _forecast(now, 10),
    );
    expect(insight?.text, contains('unterhalb des üblichen Bereichs'));
  });

  test('Romanshorn inside seasonal range can be near median', () {
    final insight = service.fromRomanshorn(
      change24HoursCm: 6,
      currentTimestamp: now,
      seasonalReference: const SeasonalReference(
        currentCm: 251,
        medianCm: 250,
        lowerCm: 240,
        upperCm: 260,
      ),
      forecast: null,
    );
    expect(insight?.text, 'Der Pegel liegt nahe am saisonalen Median.');
  });

  test('Romanshorn above the seasonal range is identified', () {
    final insight = service.fromRomanshorn(
      change24HoursCm: 0,
      currentTimestamp: now,
      seasonalReference: const SeasonalReference(
        currentCm: 270,
        medianCm: 250,
        lowerCm: 240,
        upperCm: 260,
      ),
      forecast: null,
    );
    expect(insight?.text, contains('oberhalb des üblichen Bereichs'));
  });

  group('forecast boundaries', () {
    test('two centimetres is stable', () {
      expect(
        service
            .fromRomanshorn(
              change24HoursCm: null,
              currentTimestamp: now,
              forecast: _forecast(now, 2),
            )
            ?.text,
        contains('weitgehend stabil'),
      );
    });
    test('more than two centimetres is a light forecast change', () {
      expect(
        service
            .fromRomanshorn(
              change24HoursCm: null,
              currentTimestamp: now,
              forecast: _forecast(now, -2.1),
            )
            ?.text,
        contains('leichter Rückgang'),
      );
    });
    test('eight centimetres is a forecast change without light qualifier', () {
      expect(
        service
            .fromRomanshorn(
              change24HoursCm: null,
              currentTimestamp: now,
              forecast: _forecast(now, 8),
            )
            ?.text,
        'Bis in 3 Tagen wird ein Anstieg von etwa 8 cm erwartet.',
      );
    });
  });

  test('missing data yields no insight', () {
    expect(service.fromKonstanz(change24HoursCm: null), isNull);
    expect(
      service.fromRomanshorn(
        change24HoursCm: null,
        currentTimestamp: now,
        forecast: null,
      ),
      isNull,
    );
  });

  testWidgets('insight is placed above favorites', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              BodenseeInsightCard(
                insight: BodenseeInsight('Der Pegel ist weitgehend stabil.'),
              ),
              Text('FAVORITEN'),
            ],
          ),
        ),
      ),
    );
    final insight = tester.getTopLeft(
      find.byKey(const ValueKey('bodensee-insight-card')),
    );
    final favorites = tester.getTopLeft(find.text('FAVORITEN'));
    expect(insight.dy, lessThan(favorites.dy));
  });
}

BafuForecastData _forecast(DateTime start, double changeCm) => BafuForecastData(
  points: [
    BafuForecastPoint(
      timestamp: start,
      medianMasl: 394,
      minimumMasl: 393.9,
      maximumMasl: 394.1,
    ),
    BafuForecastPoint(
      timestamp: start.add(const Duration(days: 3)),
      medianMasl: 394 + changeCm / 100,
      minimumMasl: 393.9 + changeCm / 100,
      maximumMasl: 394.1 + changeCm / 100,
    ),
  ],
);
