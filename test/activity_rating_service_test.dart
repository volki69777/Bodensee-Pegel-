import 'package:bodensee_pegel/activity_rating_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ActivityForecastData data({
    double? min = 16,
    double? max = 22,
    double? rain = 0,
    double? wind = 10,
    double? gust = 15,
    double? water,
  }) => ActivityForecastData(
    temperatureMinimumCelsius: min,
    temperatureMaximumCelsius: max,
    precipitationMillimeters: rain,
    windKilometersPerHour: wind,
    gustKilometersPerHour: gust,
    waterTemperatureCelsius: water,
  );

  ActivityRatingLevel rate(String id, ActivityForecastData forecast) =>
      ActivityRatingService.rate(activityId: id, data: forecast).level;

  group('SUP / Kajak', () {
    test('uses documented wind and gust boundaries', () {
      expect(
        rate('sup_kajak', data(wind: 12, gust: 20)),
        ActivityRatingLevel.veryGood,
      );
      expect(
        rate('sup_kajak', data(wind: 18, gust: 28)),
        ActivityRatingLevel.good,
      );
      expect(rate('sup_kajak', data(wind: 25)), ActivityRatingLevel.limited);
      expect(rate('sup_kajak', data(wind: 26)), ActivityRatingLevel.unsuitable);
      expect(rate('sup_kajak', data(gust: 28)), ActivityRatingLevel.good);
      expect(rate('sup_kajak', data(gust: 35)), ActivityRatingLevel.limited);
      expect(rate('sup_kajak', data(gust: 36)), ActivityRatingLevel.unsuitable);
    });

    test('names moderate rain as the factor preventing very good', () {
      final rating = ActivityRatingService.rate(
        activityId: 'sup_kajak',
        data: data(wind: 7.4, gust: 14.8, rain: 1.9, max: 19.3),
      );
      expect(rating.level, ActivityRatingLevel.good);
      expect(rating.reason, 'Mäßiger Niederschlag · 1,9 mm');
    });
  });

  group('Segeln', () {
    test('covers wind interval boundaries', () {
      expect(rate('segeln', data(wind: 7)), ActivityRatingLevel.limited);
      expect(rate('segeln', data(wind: 8)), ActivityRatingLevel.good);
      expect(rate('segeln', data(wind: 12)), ActivityRatingLevel.veryGood);
      expect(rate('segeln', data(wind: 28)), ActivityRatingLevel.veryGood);
      expect(rate('segeln', data(wind: 35)), ActivityRatingLevel.good);
      expect(rate('segeln', data(wind: 36)), ActivityRatingLevel.limited);
      expect(rate('segeln', data(wind: 45)), ActivityRatingLevel.limited);
      expect(rate('segeln', data(wind: 46)), ActivityRatingLevel.unsuitable);
    });
  });

  group('Motorboot', () {
    test('does not use water level and respects wind limits', () {
      expect(
        rate('motorboot', data(wind: 20, gust: 30)),
        ActivityRatingLevel.veryGood,
      );
      expect(
        rate('motorboot', data(wind: 28, gust: 40)),
        ActivityRatingLevel.good,
      );
      expect(rate('motorboot', data(wind: 38)), ActivityRatingLevel.limited);
      expect(rate('motorboot', data(wind: 39)), ActivityRatingLevel.unsuitable);
    });

    test('names moderate rain as the factor preventing very good', () {
      final rating = ActivityRatingService.rate(
        activityId: 'motorboot',
        data: data(wind: 7.4, gust: 14.8, rain: 1.9),
      );
      expect(rating.level, ActivityRatingLevel.good);
      expect(rating.reason, 'Mäßiger Niederschlag · 1,9 mm');
    });
  });

  group('Kiten', () {
    test('uses wind intervals and a simple transparent gustiness rule', () {
      expect(rate('kiten', data(wind: 14)), ActivityRatingLevel.unsuitable);
      expect(rate('kiten', data(wind: 15)), ActivityRatingLevel.limited);
      expect(rate('kiten', data(wind: 19)), ActivityRatingLevel.limited);
      expect(rate('kiten', data(wind: 20)), ActivityRatingLevel.good);
      expect(
        rate('kiten', data(wind: 25, gust: 35)),
        ActivityRatingLevel.veryGood,
      );
      expect(
        rate('kiten', data(wind: 40, gust: 50)),
        ActivityRatingLevel.veryGood,
      );
      expect(rate('kiten', data(wind: 45)), ActivityRatingLevel.good);
      expect(rate('kiten', data(wind: 46)), ActivityRatingLevel.limited);
      expect(rate('kiten', data(wind: 50)), ActivityRatingLevel.limited);
      expect(rate('kiten', data(wind: 51)), ActivityRatingLevel.unsuitable);
      expect(
        rate('kiten', data(wind: 30, gust: 46)),
        ActivityRatingLevel.unsuitable,
      );
    });

    test('prefers the gustiness reason when weak wind is also present', () {
      final rating = ActivityRatingService.rate(
        activityId: 'kiten',
        data: data(wind: 4.7, gust: 27.4),
      );
      expect(rating.level, ActivityRatingLevel.unsuitable);
      expect(rating.reason, 'Stark böig: 27 km/h Böen bei 5 km/h Wind');
    });
  });

  group('Angeln', () {
    test('uses wind limits and rain as a limiting factor', () {
      expect(rate('angeln', data(wind: 15)), ActivityRatingLevel.veryGood);
      expect(rate('angeln', data(wind: 22)), ActivityRatingLevel.good);
      expect(rate('angeln', data(wind: 30)), ActivityRatingLevel.limited);
      expect(rate('angeln', data(wind: 31)), ActivityRatingLevel.unsuitable);
      expect(rate('angeln', data(rain: 6)), ActivityRatingLevel.limited);
    });
  });

  group('Baden / Schwimmen', () {
    test('does not penalise unavailable water temperature', () {
      final missingWater = ActivityRatingService.rate(
        activityId: 'baden',
        data: data(max: 22, water: null),
      );
      expect(missingWater.level, ActivityRatingLevel.veryGood);
      expect(missingWater.reason, contains('Wassertemperatur nicht verfügbar'));
      expect(
        rate('baden', data(max: 22, water: 20)),
        ActivityRatingLevel.veryGood,
      );
      expect(rate('baden', data(max: 19, water: 17)), ActivityRatingLevel.good);
      expect(
        rate('baden', data(max: 15, water: 20)),
        ActivityRatingLevel.limited,
      );
    });
  });

  group('Radfahren und Wandern', () {
    test('use temperature, precipitation and wind boundaries', () {
      expect(
        rate('radfahren', data(min: 12, max: 25, wind: 20)),
        ActivityRatingLevel.veryGood,
      );
      expect(rate('radfahren', data(wind: 31)), ActivityRatingLevel.limited);
      expect(rate('radfahren', data(wind: 41)), ActivityRatingLevel.unsuitable);
      expect(rate('radfahren', data(rain: 6)), ActivityRatingLevel.limited);
      expect(
        rate('wandern', data(min: 10, max: 24, wind: 25)),
        ActivityRatingLevel.veryGood,
      );
      expect(rate('wandern', data(wind: 26)), ActivityRatingLevel.limited);
      expect(rate('wandern', data(wind: 51)), ActivityRatingLevel.unsuitable);
      expect(rate('wandern', data(rain: 6)), ActivityRatingLevel.limited);
    });
  });

  test('missing individual values do not automatically worsen a rating', () {
    expect(
      rate('sup_kajak', data(gust: null, rain: null, max: null, wind: 10)),
      ActivityRatingLevel.veryGood,
    );
    expect(
      rate(
        'segeln',
        data(gust: null, rain: null, min: null, max: null, wind: 20),
      ),
      ActivityRatingLevel.veryGood,
    );
  });

  test('defines precipitation categories at every boundary', () {
    ActivityRating ratingFor(double rain) => ActivityRatingService.rate(
      activityId: 'sup_kajak',
      data: data(wind: 7, gust: 14, max: 20, rain: rain),
    );
    expect(ratingFor(1).level, ActivityRatingLevel.veryGood);
    expect(ratingFor(1.01).reason, startsWith('Mäßiger Niederschlag'));
    expect(ratingFor(5).reason, startsWith('Mäßiger Niederschlag'));
    expect(ratingFor(5.01).level, ActivityRatingLevel.limited);
  });

  test('Bregenz water temperature is considered only when supplied', () {
    final withWater = ActivityRatingService.rate(
      activityId: 'baden',
      data: data(max: 22, water: 20),
    );
    final futureDayWithoutWater = ActivityRatingService.rate(
      activityId: 'baden',
      data: data(max: 22, water: null),
    );
    expect(withWater.reason, '22 °C Luft · 20 °C Wasser');
    expect(futureDayWithoutWater.reason, contains('nicht verfügbar'));
  });

  test('almost entirely missing data is not rateable', () {
    expect(
      rate('sup_kajak', const ActivityForecastData()),
      ActivityRatingLevel.unavailable,
    );
    expect(
      rate('baden', const ActivityForecastData()),
      ActivityRatingLevel.unavailable,
    );
  });

  test('critical factors take priority over positive conditions', () {
    expect(
      rate('sup_kajak', data(min: 20, max: 24, wind: 30, gust: 15)),
      ActivityRatingLevel.unsuitable,
    );
    expect(
      ActivityRatingService.rate(
        activityId: 'wandern',
        data: data(wind: 10).copyWithWarning(),
      ).level,
      ActivityRatingLevel.unsuitable,
    );
  });
}

extension on ActivityForecastData {
  ActivityForecastData copyWithWarning() => ActivityForecastData(
    temperatureMinimumCelsius: temperatureMinimumCelsius,
    temperatureMaximumCelsius: temperatureMaximumCelsius,
    precipitationMillimeters: precipitationMillimeters,
    windKilometersPerHour: windKilometersPerHour,
    gustKilometersPerHour: gustKilometersPerHour,
    waterTemperatureCelsius: waterTemperatureCelsius,
    warningSeverity: ActivityWarningSeverity.severe,
  );
}
