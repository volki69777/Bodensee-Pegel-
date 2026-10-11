import 'activity_rating_service.dart';

/// Selects an existing daily rating without recomputing or rounding its score.
class DailyActivityRecommendation {
  const DailyActivityRecommendation(this.activityId, this.rating);

  final String activityId;
  final ActivityRating rating;
}

abstract final class ActivityRecommendationService {
  /// Same order as the six water activities in the planner. Strictly greater
  /// scores replace the winner, so ties always retain the earlier activity.
  static const activityOrder = <String>[
    'sup_kajak',
    'segeln',
    'motorboot',
    'kiten',
    'angeln',
    'baden',
  ];

  static DailyActivityRecommendation? best(
    Map<String, ActivityRating> ratings,
  ) {
    DailyActivityRecommendation? best;
    for (final id in activityOrder) {
      final rating = ratings[id];
      final score = rating?.score;
      if (rating == null ||
          rating.level == ActivityRatingLevel.unavailable ||
          score == null ||
          !score.isFinite) {
        continue;
      }
      if (best == null || score > best.rating.score!) {
        best = DailyActivityRecommendation(id, rating);
      }
    }
    return best;
  }
}
