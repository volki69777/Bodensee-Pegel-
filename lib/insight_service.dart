import 'analysis_service.dart';
import 'bafu_hydro_service.dart';

enum InsightTrend { stable, lightRise, lightFall, strongRise, strongFall }

class BodenseeInsight {
  const BodenseeInsight(this.text);

  final String text;
}

/// Converts verified measurements and references into one concise, neutral
/// statement. It intentionally contains no causal interpretation or alerts.
class InsightService {
  const InsightService();

  static InsightTrend trend24Hours(double changeCm) =>
      _trend(changeCm, stableLimit: 1, strongLimit: 4);

  static InsightTrend trend7Days(double changeCm) =>
      _trend(changeCm, stableLimit: 2, strongLimit: 8);

  static InsightTrend _trend(
    double changeCm, {
    required double stableLimit,
    required double strongLimit,
  }) {
    final magnitude = changeCm.abs();
    if (magnitude <= stableLimit) return InsightTrend.stable;
    if (magnitude >= strongLimit) {
      return changeCm >= 0 ? InsightTrend.strongRise : InsightTrend.strongFall;
    }
    return changeCm >= 0 ? InsightTrend.lightRise : InsightTrend.lightFall;
  }

  BodenseeInsight? fromKonstanz({required double? change24HoursCm}) =>
      change24HoursCm == null
      ? null
      : BodenseeInsight(
          _trendText(
            trend24Hours(change24HoursCm),
            change24HoursCm,
            '24 Stunden',
          ),
        );

  BodenseeInsight? fromBregenz({required double? change7DaysCm}) =>
      change7DaysCm == null
      ? null
      : BodenseeInsight(
          _trendText(trend7Days(change7DaysCm), change7DaysCm, '7 Tagen'),
        );

  BodenseeInsight? fromRomanshorn({
    required double? change24HoursCm,
    SeasonalReference? seasonalReference,
    BafuForecastData? forecast,
    required DateTime currentTimestamp,
  }) {
    final seasonal = _seasonalInsight(seasonalReference);
    if (seasonal != null) return seasonal;

    final forecastInsight = _forecastInsight(forecast, currentTimestamp);
    if (forecastInsight != null) return forecastInsight;

    return change24HoursCm == null
        ? null
        : BodenseeInsight(
            _trendText(
              trend24Hours(change24HoursCm),
              change24HoursCm,
              '24 Stunden',
            ),
          );
  }

  BodenseeInsight? _seasonalInsight(SeasonalReference? reference) {
    if (reference == null ||
        reference.lowerCm == null ||
        reference.upperCm == null) {
      return null;
    }
    final difference = reference.differenceCm;
    final amount = _cm(difference.abs());
    if (reference.currentCm < reference.lowerCm!) {
      return BodenseeInsight(
        'Der Pegel liegt $amount cm unter dem saisonalen Median und unterhalb des üblichen Bereichs.',
      );
    }
    if (reference.currentCm > reference.upperCm!) {
      return BodenseeInsight(
        'Der Pegel liegt $amount cm über dem saisonalen Median und oberhalb des üblichen Bereichs.',
      );
    }
    if (difference.abs() <= 2) {
      return const BodenseeInsight(
        'Der Pegel liegt nahe am saisonalen Median.',
      );
    }
    final direction = difference < 0 ? 'unter' : 'über';
    return BodenseeInsight(
      'Der Pegel liegt $amount cm $direction dem saisonalen Median.',
    );
  }

  BodenseeInsight? _forecastInsight(
    BafuForecastData? forecast,
    DateTime currentTimestamp,
  ) {
    if (forecast == null || forecast.points.length < 2) return null;
    final points = forecast.points;
    final first = points.first.timestamp;
    // A usable forecast must cover the current measurement and reach three
    // days ahead. This prevents a stale or incomplete plot from yielding text.
    if (first.difference(currentTimestamp).abs() > const Duration(hours: 12)) {
      return null;
    }
    final target = first.add(const Duration(days: 3));
    final point = _closestPoint(points, target);
    if (point.timestamp.difference(target).abs() > const Duration(hours: 12)) {
      return null;
    }
    final changeCm = (point.medianMasl - points.first.medianMasl) * 100;
    final amount = _cm(changeCm.abs());
    if (changeCm.abs() <= 2) {
      return const BodenseeInsight(
        'Für die nächsten 3 Tage wird ein weitgehend stabiler Pegel erwartet.',
      );
    }
    final direction = changeCm < 0 ? 'Rückgang' : 'Anstieg';
    if (changeCm.abs() < 8 - .000001) {
      return BodenseeInsight(
        'Bis in 3 Tagen wird ein leichter $direction von etwa $amount cm erwartet.',
      );
    }
    return BodenseeInsight(
      'Bis in 3 Tagen wird ein $direction von etwa $amount cm erwartet.',
    );
  }

  BafuForecastPoint _closestPoint(
    List<BafuForecastPoint> points,
    DateTime target,
  ) => points.reduce(
    (closest, candidate) =>
        candidate.timestamp.difference(target).abs() <
            closest.timestamp.difference(target).abs()
        ? candidate
        : closest,
  );

  String _trendText(InsightTrend trend, double changeCm, String period) {
    if (trend == InsightTrend.stable) {
      return 'Der Pegel ist seit $period weitgehend stabil.';
    }
    final direction =
        trend == InsightTrend.lightFall || trend == InsightTrend.strongFall
        ? 'gefallen'
        : 'gestiegen';
    final intensity =
        trend == InsightTrend.lightRise || trend == InsightTrend.lightFall
        ? 'leicht'
        : 'deutlich';
    return 'Der Pegel ist in den letzten $period $intensity $direction.';
  }

  String _cm(double value) {
    final rounded = value.roundToDouble();
    return (value - rounded).abs() < .000001
        ? rounded.round().toString()
        : value.toStringAsFixed(1).replaceAll('.', ',');
  }
}
