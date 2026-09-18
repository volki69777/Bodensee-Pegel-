import 'package:bodensee_pegel/activity_rating_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ActivityForecastData data({
    double? minimum = 16,
    double? maximum = 22,
    double? rain = 0,
    double? wind = 10,
    double? gust = 15,
    double? water,
  }) => ActivityForecastData(
    temperatureMinimumCelsius: minimum,
    temperatureMaximumCelsius: maximum,
    precipitationMillimeters: rain,
    windKilometersPerHour: wind,
    gustKilometersPerHour: gust,
    waterTemperatureCelsius: water,
  );

  ActivityRating rate(String activity, ActivityForecastData forecast) =>
      ActivityRatingService.rate(activityId: activity, data: forecast);

  void expectScoreInCategory(ActivityRating rating) {
    final score = rating.score;
    if (rating.level == ActivityRatingLevel.unavailable) {
      expect(score, isNull);
      return;
    }
    expect(score, isNotNull);
    final range = switch (rating.level) {
      ActivityRatingLevel.veryGood => (8.0, 10.0),
      ActivityRatingLevel.good => (6.0, 7.9),
      ActivityRatingLevel.limited => (4.0, 5.9),
      ActivityRatingLevel.unsuitable => (0.0, 3.9),
      ActivityRatingLevel.unavailable => (0.0, 0.0),
    };
    expect(score!, inInclusiveRange(range.$1, range.$2));
  }

  group('score remains inside the existing category bands', () {
    final examples = <(String, ActivityForecastData)>[
      ('sup_kajak', data(wind: 8, gust: 16, rain: 0, maximum: 20)),
      ('sup_kajak', data(wind: 18, gust: 28, rain: 1, maximum: 20)),
      ('sup_kajak', data(wind: 25, gust: 20)),
      ('sup_kajak', data(wind: 26, gust: 20)),
      ('segeln', data(wind: 18, gust: 25)),
      ('segeln', data(wind: 8, gust: 20)),
      ('segeln', data(wind: 40, gust: 25)),
      ('segeln', data(wind: 46, gust: 25)),
      ('motorboot', data(wind: 8, gust: 15, rain: 0)),
      ('motorboot', data(wind: 28, gust: 40, rain: 1)),
      ('motorboot', data(wind: 38, gust: 30)),
      ('motorboot', data(wind: 39, gust: 30)),
      ('kiten', data(wind: 30, gust: 36)),
      ('kiten', data(wind: 22, gust: 28)),
      ('kiten', data(wind: 16, gust: 25)),
      ('kiten', data(wind: 14, gust: 20)),
      ('angeln', data(wind: 7, gust: 10, rain: 0, minimum: 12, maximum: 20)),
      ('angeln', data(wind: 22, gust: 30, rain: 1)),
      ('angeln', data(wind: 30, gust: 30)),
      ('angeln', data(wind: 31, gust: 30)),
      ('baden', data(maximum: 22, water: 20)),
      ('baden', data(maximum: 19, water: 17)),
      ('baden', data(maximum: 15, water: 20)),
    ];

    for (final example in examples) {
      test('${example.$1} score matches its existing category', () {
        expectScoreInCategory(rate(example.$1, example.$2));
      });
    }
  });

  test('moderate precipitation caps SUP at the good category maximum', () {
    final rating = rate(
      'sup_kajak',
      data(wind: 7.4, gust: 14.8, rain: 1.9, maximum: 19.3),
    );
    expect(rating.level, ActivityRatingLevel.good);
    expect(rating.score, 7.9);
  });

  test('optional missing values are removed instead of scored as zero', () {
    final rating = rate(
      'sup_kajak',
      data(wind: 10, gust: null, rain: null, maximum: null),
    );
    expect(rating.level, ActivityRatingLevel.veryGood);
    expect(rating.score, 10);
  });

  test('missing minimum data remains not rateable without a score', () {
    final rating = rate('sup_kajak', const ActivityForecastData());
    expect(rating.level, ActivityRatingLevel.unavailable);
    expect(rating.score, isNull);
  });

  test('kiting gustiness is scored and remains unsuitable above 15 km/h', () {
    final rating = rate('kiten', data(wind: 30, gust: 46));
    expect(rating.level, ActivityRatingLevel.unsuitable);
    expect(rating.score, inInclusiveRange(0, 3.9));
  });

  test('swimming without water temperature remains scoreable from air', () {
    final rating = rate('baden', data(maximum: 22, water: null));
    expect(rating.level, ActivityRatingLevel.veryGood);
    expect(rating.score, 10);
  });

  test('Bregenz local water temperature participates in swimming score', () {
    final rating = rate('baden', data(maximum: 22, water: 20));
    expect(rating.level, ActivityRatingLevel.veryGood);
    expect(rating.score, 10);
  });
}
