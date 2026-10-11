import 'package:flutter_test/flutter_test.dart';
import 'package:bodensee_pegel/activity_rating_service.dart';
import 'package:bodensee_pegel/activity_recommendation_service.dart';

void main() {
  test(
    'selects the unique highest existing score and keeps the original rating',
    () {
      const winner = ActivityRating(
        ActivityRatingLevel.veryGood,
        'Original',
        score: 9.2,
      );
      final ratings = {
        'sup_kajak': const ActivityRating(
          ActivityRatingLevel.good,
          'Wind',
          score: 7,
        ),
        'segeln': winner,
      };
      final best = ActivityRecommendationService.best(ratings)!;
      expect(best.activityId, 'segeln');
      expect(identical(best.rating, winner), isTrue);
      expect(ratings['segeln']!.score, 9.2);
    },
  );
  test('ties use planner order regardless of map insertion order', () {
    const rating = ActivityRating(
      ActivityRatingLevel.veryGood,
      'Gleichstand',
      score: 9,
    );
    final forward = {
      for (final id in ActivityRecommendationService.activityOrder) id: rating,
    };
    final reverse = {
      for (final id in ActivityRecommendationService.activityOrder.reversed)
        id: rating,
    };
    expect(
      ActivityRecommendationService.best(forward)!.activityId,
      'sup_kajak',
    );
    expect(
      ActivityRecommendationService.best(reverse)!.activityId,
      'sup_kajak',
    );
    reverse.remove('sup_kajak');
    expect(ActivityRecommendationService.best(reverse)!.activityId, 'segeln');
  });
  test('ranking uses unrounded scores', () {
    final best = ActivityRecommendationService.best({
      'sup_kajak': const ActivityRating(
        ActivityRatingLevel.veryGood,
        '',
        score: 9.01,
      ),
      'segeln': const ActivityRating(
        ActivityRatingLevel.veryGood,
        '',
        score: 9.04,
      ),
    })!;
    expect(best.activityId, 'segeln');
    expect(best.rating.score, 9.04);
  });
  test('missing or unavailable ratings do not compete', () {
    expect(ActivityRecommendationService.best({}), isNull);
    expect(
      ActivityRecommendationService.best({
        'sup_kajak': const ActivityRating(
          ActivityRatingLevel.unavailable,
          '',
          score: 10,
        ),
        'segeln': const ActivityRating(ActivityRatingLevel.good, ''),
        'motorboot': const ActivityRating(
          ActivityRatingLevel.good,
          '',
          score: double.nan,
        ),
      }),
      isNull,
    );
  });
  test('only the six water activities compete, including a valid zero', () {
    final best = ActivityRecommendationService.best({
      'wandern': const ActivityRating(
        ActivityRatingLevel.veryGood,
        '',
        score: 10,
      ),
      'radfahren': const ActivityRating(
        ActivityRatingLevel.veryGood,
        '',
        score: 10,
      ),
      'baden': const ActivityRating(
        ActivityRatingLevel.unsuitable,
        'Kalt',
        score: 0,
      ),
    })!;
    expect(best.activityId, 'baden');
    expect(best.rating.score, 0);
  });
  for (final profile in [null, ...MotorboatRatingProfile.values]) {
    test(
      'preserves engine scores, categories and reasons for profile $profile',
      () {
        final data = ActivityForecastData(
          temperatureMinimumCelsius: 10,
          temperatureMaximumCelsius: 10,
          windKilometersPerHour: 9,
          gustKilometersPerHour: 25.2,
          precipitationMillimeters: 0,
          motorboatProfile: profile,
        );
        final ratings = {
          for (final id in ActivityRecommendationService.activityOrder)
            id: ActivityRatingService.rate(activityId: id, data: data),
        };
        final before = {
          for (final entry in ratings.entries)
            entry.key: (
              entry.value.score,
              entry.value.level,
              entry.value.reason,
            ),
        };
        final recommendation = ActivityRecommendationService.best(ratings)!;
        // At 10 °C every motorboat profile is now capped at four points.
        expect(ratings['motorboot']!.score, 4);
        expect(recommendation.activityId, 'angeln');
        expect(
          identical(recommendation.rating, ratings[recommendation.activityId]),
          isTrue,
        );
        expect({
          for (final entry in ratings.entries)
            entry.key: (
              entry.value.score,
              entry.value.level,
              entry.value.reason,
            ),
        }, before);
      },
    );
  }
}
