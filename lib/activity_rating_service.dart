/// Transparente, regelbasierte Freizeit-Eignung aus Tagesprognosen.
///
/// Die Bewertungen sind keine Sicherheitsbewertung. Sie verwenden ausschließlich
/// die übergebenen Wetterwerte und treffen keine Aussage über lokale Gefahren,
/// Gewässerbedingungen oder amtliche Warnlagen.
library;

import 'dart:math' as math;

enum ActivityRatingLevel { veryGood, good, limited, unsuitable, unavailable }

enum ActivityWarningSeverity { none, severe }

/// A voluntary profile for the motorboat activity.
///
/// The profiles are deliberately conservative app heuristics, not nautical
/// safety limits. They only differentiate the existing leisure suitability
/// score using the forecast values already available in the app.
enum MotorboatRatingProfile { smallOpen, cabin, yacht }

extension MotorboatRatingProfileLabel on MotorboatRatingProfile {
  String get label => switch (this) {
    MotorboatRatingProfile.smallOpen => 'Kleines offenes Motorboot',
    MotorboatRatingProfile.cabin => 'Kajütboot',
    MotorboatRatingProfile.yacht => 'Größere Motoryacht',
  };

  String get activityLabel => switch (this) {
    MotorboatRatingProfile.smallOpen => 'Motorboot (klein)',
    MotorboatRatingProfile.cabin => 'Motorboot (Kajütboot)',
    MotorboatRatingProfile.yacht => 'Motorboot (Motoryacht)',
  };
}

class ActivityForecastData {
  const ActivityForecastData({
    this.temperatureMinimumCelsius,
    this.temperatureMaximumCelsius,
    this.precipitationMillimeters,
    this.windKilometersPerHour,
    this.gustKilometersPerHour,
    this.waterTemperatureCelsius,
    this.motorboatProfile,
    this.warningSeverity = ActivityWarningSeverity.none,
  });

  final double? temperatureMinimumCelsius;
  final double? temperatureMaximumCelsius;
  final double? precipitationMillimeters;
  final double? windKilometersPerHour;
  final double? gustKilometersPerHour;
  final double? waterTemperatureCelsius;
  final MotorboatRatingProfile? motorboatProfile;

  /// Reserved for a future official warning source. No warning data is passed
  /// in V1, but the explicit override keeps that later extension central.
  final ActivityWarningSeverity warningSeverity;

  bool get hasTemperatureRange =>
      temperatureMinimumCelsius != null && temperatureMaximumCelsius != null;
}

class ActivityRating {
  const ActivityRating(this.level, this.reason, {this.score});

  final ActivityRatingLevel level;
  final String reason;

  /// Continuous 0–10 score constrained to this rating's existing category.
  /// It stays null for an unavailable rating.
  final double? score;

  String get label => switch (level) {
    ActivityRatingLevel.veryGood => 'Sehr gut',
    ActivityRatingLevel.good => 'Gut',
    ActivityRatingLevel.limited => 'Eingeschränkt',
    ActivityRatingLevel.unsuitable => 'Ungeeignet',
    ActivityRatingLevel.unavailable => 'Nicht bewertbar',
  };

  String get shortLabel => switch (level) {
    ActivityRatingLevel.veryGood => 'SG',
    ActivityRatingLevel.good => 'G',
    ActivityRatingLevel.limited => 'E',
    ActivityRatingLevel.unsuitable => 'U',
    ActivityRatingLevel.unavailable => '–',
  };
}

/// All thresholds are day-level V1 rules and intentionally station-independent.
abstract final class ActivityRatingService {
  /// Up to this daily total counts as "kaum Niederschlag".
  static const littlePrecipitationMillimeters = 1.0;

  /// Above this daily total precipitation is the primary limiting factor.
  static const heavyPrecipitationMillimeters = 5.0;

  /// A simple, visible gustiness rule for kiting: a gust at least 15 km/h
  /// above the representative wind is treated as unusually gusty.
  static const extremeGustinessDifferenceKilometersPerHour = 15.0;

  static ActivityRating rate({
    required String activityId,
    required ActivityForecastData data,
  }) {
    if (data.warningSeverity == ActivityWarningSeverity.severe) {
      return const ActivityRating(
        ActivityRatingLevel.unsuitable,
        'Amtliche Warnung liegt vor',
      );
    }
    if (!_hasRelevantData(activityId, data)) return _unavailable;

    final rating = switch (activityId) {
      'sup_kajak' => _sup(data),
      'segeln' => _sailing(data),
      'motorboot' => _motorboat(data),
      'kiten' => _kiting(data),
      'angeln' => _fishing(data),
      'baden' => _swimming(data),
      'radfahren' => _cycling(data),
      'wandern' => _hiking(data),
      _ => _unavailable,
    };
    return _withScore(activityId, data, rating);
  }

  static const _unavailable = ActivityRating(
    ActivityRatingLevel.unavailable,
    'Nicht genügend Wetterdaten verfügbar',
  );

  /// Computes a continuous score from the same inputs as the existing
  /// category rules. The category remains authoritative: the score is always
  /// clamped into its category band and can therefore never imply another
  /// rating level.
  static ActivityRating _withScore(
    String activityId,
    ActivityForecastData data,
    ActivityRating rating,
  ) {
    if (rating.level == ActivityRatingLevel.unavailable) return rating;

    final raw = switch (activityId) {
      'sup_kajak' => _weighted(<(double?, double)>[
        (_descending(data.windKilometersPerHour, 12, 25), .45),
        (_descending(data.gustKilometersPerHour, 20, 35), .30),
        (_descending(data.precipitationMillimeters, 1, 8), .15),
        (_ascending(data.temperatureMaximumCelsius, 8, 16), .10),
      ]),
      'segeln' => _weighted(<(double?, double)>[
        (_range(data.windKilometersPerHour, 12, 28, 8, 45), .65),
        (_descending(data.gustKilometersPerHour, 40, 55), .35),
      ]),
      'motorboot' => _weighted(<(double?, double)>[
        (
          _descending(
            data.windKilometersPerHour,
            _motorboatThresholds(data.motorboatProfile).veryGoodWind,
            _motorboatThresholds(data.motorboatProfile).unsuitableWind,
          ),
          .45,
        ),
        (
          _descending(
            data.gustKilometersPerHour,
            _motorboatThresholds(data.motorboatProfile).veryGoodGust,
            _motorboatThresholds(data.motorboatProfile).unsuitableGust,
          ),
          .30,
        ),
        (_descending(data.precipitationMillimeters, 1, 8), .25),
      ]),
      'kiten' => _weighted(<(double?, double)>[
        (_range(data.windKilometersPerHour, 25, 40, 15, 50), .70),
        (
          data.windKilometersPerHour == null ||
                  data.gustKilometersPerHour == null
              ? null
              : _descending(
                  data.gustKilometersPerHour! - data.windKilometersPerHour!,
                  8,
                  extremeGustinessDifferenceKilometersPerHour,
                ),
          .30,
        ),
      ]),
      'angeln' => _weighted(<(double?, double)>[
        (_descending(data.windKilometersPerHour, 15, 30), .40),
        (_descending(data.gustKilometersPerHour, 30, 45), .25),
        (_descending(data.precipitationMillimeters, 1, 8), .20),
        (_fishingTemperatureScore(data), .15),
      ]),
      'baden' => _weighted(<(double?, double)>[
        (_ascending(data.temperatureMaximumCelsius, 12, 22), .60),
        (_ascending(data.waterTemperatureCelsius, 10, 20), .40),
      ]),
      // These two activities are intentionally retained for backwards
      // compatible stored data, but are no longer visible in V1.
      'radfahren' || 'wandern' => _weighted(<(double?, double)>[
        (_descending(data.windKilometersPerHour, 20, 45), 1),
      ]),
      _ => null,
    };
    if (raw == null) return rating;
    return ActivityRating(
      rating.level,
      rating.reason,
      score: _clampToCategory(raw, rating.level),
    );
  }

  /// Omits missing optional values and proportionally normalises what remains.
  static double? _weighted(List<(double?, double)> factors) {
    final available = factors.where((factor) => factor.$1 != null).toList();
    if (available.isEmpty) return null;
    final totalWeight = available.fold<double>(0, (sum, item) => sum + item.$2);
    return available.fold<double>(
      0,
      (sum, item) => sum + item.$1! * item.$2 / totalWeight,
    );
  }

  static double _clampToCategory(double raw, ActivityRatingLevel level) {
    final (minimum, maximum) = switch (level) {
      ActivityRatingLevel.veryGood => (8.0, 10.0),
      ActivityRatingLevel.good => (6.0, 7.9),
      ActivityRatingLevel.limited => (4.0, 5.9),
      ActivityRatingLevel.unsuitable => (0.0, 3.9),
      ActivityRatingLevel.unavailable => (0.0, 0.0),
    };
    return raw.clamp(minimum, maximum).toDouble();
  }

  static double? _ascending(double? value, double zeroAt, double tenAt) {
    if (value == null) return null;
    if (value <= zeroAt) return 0;
    if (value >= tenAt) return 10;
    return 10 * (value - zeroAt) / (tenAt - zeroAt);
  }

  static double? _descending(double? value, double tenAt, double zeroAt) {
    if (value == null) return null;
    if (value <= tenAt) return 10;
    if (value >= zeroAt) return 0;
    return 10 * (zeroAt - value) / (zeroAt - tenAt);
  }

  static double? _range(
    double? value,
    double idealMinimum,
    double idealMaximum,
    double outerMinimum,
    double outerMaximum,
  ) {
    if (value == null) return null;
    if (value >= idealMinimum && value <= idealMaximum) return 10;
    if (value <= outerMinimum || value >= outerMaximum) return 0;
    if (value < idealMinimum) {
      return 10 * (value - outerMinimum) / (idealMinimum - outerMinimum);
    }
    return 10 * (outerMaximum - value) / (outerMaximum - idealMaximum);
  }

  static double? _fishingTemperatureScore(ActivityForecastData data) {
    if (!data.hasTemperatureRange) return null;
    return math.min(
      _ascending(data.temperatureMinimumCelsius, 0, 8)!,
      _descending(data.temperatureMaximumCelsius, 25, 33)!,
    );
  }

  /// Wind is the minimum for water and wind sports plus fishing. Cycling and
  /// hiking need wind or a full comfort-temperature range; swimming needs air
  /// maximum or water temperature. Optional missing values never downgrade an
  /// otherwise assessable day.
  static bool _hasRelevantData(String activityId, ActivityForecastData data) =>
      switch (activityId) {
        'sup_kajak' ||
        'segeln' ||
        'motorboot' ||
        'kiten' ||
        'angeln' => data.windKilometersPerHour != null,
        'baden' =>
          data.temperatureMaximumCelsius != null ||
              data.waterTemperatureCelsius != null,
        'radfahren' || 'wandern' =>
          data.windKilometersPerHour != null || data.hasTemperatureRange,
        _ => false,
      };

  static ActivityRating _sup(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    if (_above(wind, 25)) return _unsuitableWind(wind!);
    if (_above(gust, 35)) return _unsuitableGust(gust!);
    if (_between(wind, 19, 25)) return _limitedWind(wind!);
    if (_between(gust, 29, 35)) return _limitedGust(gust!);
    if (_heavyRain(data)) return _limitedRainFor(data);
    if (_atMost(wind, 12) &&
        _atMostOrMissing(gust, 20) &&
        _littleRainOrMissing(data) &&
        (data.temperatureMaximumCelsius == null ||
            _atLeast(data.temperatureMaximumCelsius, 16))) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Leichter Wind und kaum Niederschlag',
      );
    }
    if (_atMost(wind, 18) && _atMostOrMissing(gust, 28)) {
      return ActivityRating(ActivityRatingLevel.good, _supGoodReason(data));
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static ActivityRating _sailing(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    if (_above(wind, 45)) return _unsuitableWind(wind!);
    if (_above(gust, 55)) return _unsuitableGust(gust!);
    if (_below(wind, 8)) return _limitedWind(wind!);
    if (_between(wind, 36, 45)) return _limitedWind(wind!);
    if (_between(gust, 41, 55)) return _limitedGust(gust!);
    if (_between(wind, 12, 28) && _atMostOrMissing(gust, 40)) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Passender Wind und moderate Böen',
      );
    }
    if (_between(wind, 8, 35) && _atMostOrMissing(gust, 40)) {
      return const ActivityRating(ActivityRatingLevel.good, 'Geeigneter Wind');
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static ActivityRating _motorboat(ActivityForecastData data) {
    final profile = data.motorboatProfile;
    if (profile == null) return _legacyMotorboat(data);
    return _motorboatForProfile(data, _motorboatThresholds(profile));
  }

  /// Keeps the original Motorboot V1 result intact until the person has
  /// explicitly selected a profile in the settings.
  static ActivityRating _legacyMotorboat(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    if (_above(wind, 38)) return _unsuitableWind(wind!);
    if (_above(gust, 50)) return _unsuitableGust(gust!);
    if (_between(wind, 29, 38)) return _limitedWind(wind!);
    if (_between(gust, 41, 50)) return _limitedGust(gust!);
    if (_heavyRain(data)) return _limitedRainFor(data);
    if (_atMost(wind, 20) &&
        _atMostOrMissing(gust, 30) &&
        _littleRainOrMissing(data)) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Wenig Wind und kaum Niederschlag',
      );
    }
    if (_atMost(wind, 28) && _atMostOrMissing(gust, 40)) {
      return ActivityRating(
        ActivityRatingLevel.good,
        _motorboatGoodReason(data),
      );
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static ActivityRating _motorboatForProfile(
    ActivityForecastData data,
    _MotorboatThresholds thresholds,
  ) {
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    final gustDifference = wind == null || gust == null ? null : gust - wind;
    if (_above(wind, thresholds.unsuitableWind)) return _unsuitableWind(wind!);
    if (_above(gustDifference, thresholds.unsuitableGustDifference)) {
      return _motorboatGustinessReason(
        ActivityRatingLevel.unsuitable,
        wind!,
        gust!,
      );
    }
    if (_above(gust, thresholds.unsuitableGust)) return _unsuitableGust(gust!);
    if (_between(wind, thresholds.limitedWindStart, thresholds.unsuitableWind)) {
      return _limitedWind(wind!);
    }
    if (_above(gustDifference, thresholds.limitedGustDifference)) {
      return _motorboatGustinessReason(
        ActivityRatingLevel.limited,
        wind!,
        gust!,
      );
    }
    if (_between(gust, thresholds.limitedGustStart, thresholds.unsuitableGust)) {
      return _limitedGust(gust!);
    }
    if (_heavyRain(data)) return _limitedRainFor(data);
    if (_atMost(wind, thresholds.veryGoodWind) &&
        _atMostOrMissing(gust, thresholds.veryGoodGust) &&
        _littleRainOrMissing(data)) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Wenig Wind und kaum Niederschlag',
      );
    }
    if (_atMost(wind, thresholds.goodWind) &&
        _atMostOrMissing(gust, thresholds.goodGust)) {
      return ActivityRating(
        ActivityRatingLevel.good,
        _motorboatGoodReason(data, thresholds),
      );
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static ActivityRating _kiting(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    if (wind == null) return _unavailable;
    if (_isExtremelyGusty(wind, gust)) {
      return _extremeGustiness(wind, gust!);
    }
    if (wind < 15) return _unsuitableWind(wind);
    if (wind > 50) return _unsuitableWind(wind);
    if (_between(wind, 15, 19) || _between(wind, 46, 50)) {
      return _limitedWind(wind);
    }
    if (_between(wind, 25, 40) && gust != null) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Passender Wind und moderate Böigkeit',
      );
    }
    return const ActivityRating(ActivityRatingLevel.good, 'Geeigneter Wind');
  }

  static ActivityRating _fishing(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    if (_above(wind, 30)) return _unsuitableWind(wind!);
    if (_above(gust, 45)) return _unsuitableGust(gust!);
    if (_between(wind, 23, 30)) return _limitedWind(wind!);
    if (_heavyRain(data)) return _limitedRainFor(data);
    if (_atMost(wind, 15) &&
        _littleRainOrMissing(data) &&
        (!data.hasTemperatureRange || _temperatureIn(data, 8, 25))) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Wenig Wind und milde Temperatur',
      );
    }
    if (_atMost(wind, 22)) {
      return ActivityRating(ActivityRatingLevel.good, _fishingGoodReason(data));
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static ActivityRating _swimming(ActivityForecastData data) {
    final air = data.temperatureMaximumCelsius;
    final water = data.waterTemperatureCelsius;
    if (air == null && water == null) return _unavailable;
    final waterAvailable = water != null;
    final waterNote = waterAvailable
        ? ''
        : ' · Wassertemperatur nicht verfügbar';
    if (_atLeast(air, 22) && (!waterAvailable || water >= 20)) {
      return ActivityRating(
        ActivityRatingLevel.veryGood,
        waterAvailable
            ? '${air!.round()} °C Luft · ${water.round()} °C Wasser'
            : 'Warme Lufttemperatur$waterNote',
      );
    }
    if (_atLeast(air, 19) && (!waterAvailable || water >= 17)) {
      return ActivityRating(
        ActivityRatingLevel.good,
        waterAvailable && water < 20
            ? 'Wassertemperatur ${water.round()} °C'
            : 'Milde Lufttemperatur$waterNote',
      );
    }
    return ActivityRating(
      ActivityRatingLevel.limited,
      waterAvailable && water < 17
          ? 'Wassertemperatur ${water.round()} °C'
          : 'Kühle Temperatur$waterNote',
    );
  }

  static ActivityRating _cycling(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    if (_above(wind, 40)) return _unsuitableWind(wind!);
    if (_heavyRain(data)) return _limitedRainFor(data);
    if (_between(wind, 31, 40)) return _limitedWind(wind!);
    if (data.hasTemperatureRange && !_temperatureIn(data, 8, 28)) {
      return const ActivityRating(
        ActivityRatingLevel.limited,
        'Deutliche Wärme oder Kälte',
      );
    }
    if ((!data.hasTemperatureRange || _temperatureIn(data, 12, 25)) &&
        _littleRainOrMissing(data) &&
        _atMostOrMissing(wind, 20)) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Milde Temperatur, wenig Wind und kaum Niederschlag',
      );
    }
    if ((!data.hasTemperatureRange || _temperatureIn(data, 8, 28)) &&
        _atMostOrMissing(wind, 30)) {
      return ActivityRating(ActivityRatingLevel.good, _outdoorGoodReason(data));
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static ActivityRating _hiking(ActivityForecastData data) {
    final wind = data.windKilometersPerHour;
    if (_above(wind, 50)) return _unsuitableWind(wind!);
    if (_heavyRain(data)) return _limitedRainFor(data);
    if (_between(wind, 26, 50)) return _limitedWind(wind!);
    if (data.hasTemperatureRange && !_temperatureIn(data, 5, 28)) {
      return const ActivityRating(
        ActivityRatingLevel.limited,
        'Deutliche Wärme oder Kälte',
      );
    }
    if ((!data.hasTemperatureRange || _temperatureIn(data, 10, 24)) &&
        _littleRainOrMissing(data) &&
        _atMostOrMissing(wind, 25)) {
      return const ActivityRating(
        ActivityRatingLevel.veryGood,
        'Milde Temperatur und kaum Niederschlag',
      );
    }
    if ((!data.hasTemperatureRange || _temperatureIn(data, 5, 28)) &&
        _atMostOrMissing(wind, 25)) {
      return ActivityRating(ActivityRatingLevel.good, _outdoorGoodReason(data));
    }
    return const ActivityRating(
      ActivityRatingLevel.good,
      'Wetterdaten vorhanden',
    );
  }

  static bool _littleRainOrMissing(ActivityForecastData data) =>
      data.precipitationMillimeters == null ||
      data.precipitationMillimeters! <= littlePrecipitationMillimeters;

  static bool _moderateRain(ActivityForecastData data) =>
      data.precipitationMillimeters != null &&
      data.precipitationMillimeters! > littlePrecipitationMillimeters &&
      data.precipitationMillimeters! <= heavyPrecipitationMillimeters;

  static bool _heavyRain(ActivityForecastData data) =>
      data.precipitationMillimeters != null &&
      data.precipitationMillimeters! > heavyPrecipitationMillimeters;

  static bool _temperatureIn(
    ActivityForecastData data,
    double minimum,
    double maximum,
  ) =>
      data.hasTemperatureRange &&
      data.temperatureMinimumCelsius! >= minimum &&
      data.temperatureMaximumCelsius! <= maximum;

  static bool _isExtremelyGusty(double wind, double? gust) =>
      gust != null && gust - wind > extremeGustinessDifferenceKilometersPerHour;

  static bool _above(double? value, double threshold) =>
      value != null && value > threshold;
  static bool _below(double? value, double threshold) =>
      value != null && value < threshold;
  static bool _atLeast(double? value, double threshold) =>
      value != null && value >= threshold;
  static bool _atMost(double? value, double threshold) =>
      value != null && value <= threshold;
  static bool _atMostOrMissing(double? value, double threshold) =>
      value == null || value <= threshold;
  static bool _between(double? value, double minimum, double maximum) =>
      value != null && value >= minimum && value <= maximum;

  static String _number(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceAll('.', ',');

  static String _moderateRainReason(ActivityForecastData data) =>
      'Mäßiger Niederschlag · ${_number(data.precipitationMillimeters!)} mm';

  static String _supGoodReason(ActivityForecastData data) {
    if (_moderateRain(data)) return _moderateRainReason(data);
    if (_above(data.gustKilometersPerHour, 20)) {
      return 'Böen bis ${data.gustKilometersPerHour!.round()} km/h';
    }
    if (_above(data.windKilometersPerHour, 12)) {
      return 'Wind ${data.windKilometersPerHour!.round()} km/h';
    }
    if (_below(data.temperatureMaximumCelsius, 16)) {
      return 'Maximal ${data.temperatureMaximumCelsius!.round()} °C';
    }
    return 'Günstige Wetterwerte';
  }

  static String _motorboatGoodReason(
    ActivityForecastData data, [
    _MotorboatThresholds? thresholds,
  ]) {
    final rules = thresholds ?? _motorboatThresholds(null);
    if (_moderateRain(data)) return _moderateRainReason(data);
    final wind = data.windKilometersPerHour;
    final gust = data.gustKilometersPerHour;
    if (wind != null &&
        gust != null &&
        gust - wind > rules.veryGoodGustDifference) {
      return 'Böen bis ${gust.round()} km/h bei ${wind.round()} km/h Wind';
    }
    if (_above(gust, rules.veryGoodGust)) {
      return 'Böen bis ${data.gustKilometersPerHour!.round()} km/h';
    }
    if (_above(wind, rules.veryGoodWind)) {
      return 'Wind ${data.windKilometersPerHour!.round()} km/h';
    }
    return 'Günstige Wetterwerte';
  }

  static String _fishingGoodReason(ActivityForecastData data) {
    if (_moderateRain(data)) return _moderateRainReason(data);
    if (data.hasTemperatureRange && !_temperatureIn(data, 8, 25)) {
      return 'Temperatur außerhalb 8–25 °C';
    }
    if (_above(data.windKilometersPerHour, 15)) {
      return 'Wind ${data.windKilometersPerHour!.round()} km/h';
    }
    return 'Günstige Wetterwerte';
  }

  static String _outdoorGoodReason(ActivityForecastData data) =>
      _moderateRain(data) ? _moderateRainReason(data) : 'Günstige Wetterwerte';

  static ActivityRating _unsuitableWind(double wind) => ActivityRating(
    ActivityRatingLevel.unsuitable,
    'Wind ${wind.round()} km/h',
  );
  static ActivityRating _unsuitableGust(double gust) => ActivityRating(
    ActivityRatingLevel.unsuitable,
    'Böen bis ${gust.round()} km/h',
  );
  static ActivityRating _limitedWind(double wind) =>
      ActivityRating(ActivityRatingLevel.limited, 'Wind ${wind.round()} km/h');
  static ActivityRating _limitedGust(double gust) => ActivityRating(
    ActivityRatingLevel.limited,
    'Böen bis ${gust.round()} km/h',
  );
  static ActivityRating _limitedRainFor(
    ActivityForecastData data,
  ) => ActivityRating(
    ActivityRatingLevel.limited,
    'Kräftiger Niederschlag · ${_number(data.precipitationMillimeters!)} mm',
  );

  static ActivityRating _extremeGustiness(double wind, double gust) =>
      ActivityRating(
        ActivityRatingLevel.unsuitable,
        'Stark böig: ${gust.round()} km/h Böen bei ${wind.round()} km/h Wind',
      );

  static ActivityRating _motorboatGustinessReason(
    ActivityRatingLevel level,
    double wind,
    double gust,
  ) => ActivityRating(
    level,
    'Stark böig: ${gust.round()} km/h Böen bei ${wind.round()} km/h Wind',
  );

  static _MotorboatThresholds _motorboatThresholds(
    MotorboatRatingProfile? profile,
  ) => switch (profile) {
    // The previous station-independent V1 rules remain the compatibility
    // baseline for users who have not chosen a profile.
    null || MotorboatRatingProfile.cabin => const _MotorboatThresholds(
      veryGoodWind: 20,
      veryGoodGust: 30,
      veryGoodGustDifference: 10,
      goodWind: 28,
      goodGust: 40,
      limitedWindStart: 29,
      limitedGustStart: 41,
      limitedGustDifference: 20,
      unsuitableWind: 38,
      unsuitableGust: 50,
      unsuitableGustDifference: 30,
    ),
    MotorboatRatingProfile.smallOpen => const _MotorboatThresholds(
      veryGoodWind: 12,
      veryGoodGust: 20,
      veryGoodGustDifference: 8,
      goodWind: 20,
      goodGust: 30,
      limitedWindStart: 21,
      limitedGustStart: 31,
      limitedGustDifference: 15,
      unsuitableWind: 30,
      unsuitableGust: 40,
      unsuitableGustDifference: 25,
    ),
    MotorboatRatingProfile.yacht => const _MotorboatThresholds(
      veryGoodWind: 25,
      veryGoodGust: 35,
      veryGoodGustDifference: 12,
      goodWind: 33,
      goodGust: 45,
      limitedWindStart: 34,
      limitedGustStart: 46,
      limitedGustDifference: 25,
      unsuitableWind: 43,
      unsuitableGust: 55,
      unsuitableGustDifference: 35,
    ),
  };
}

/// Conservative app heuristics, not navigation, seaworthiness, or safety
/// limits. They are intentionally central so the UI and tests use one model.
class _MotorboatThresholds {
  const _MotorboatThresholds({
    required this.veryGoodWind,
    required this.veryGoodGust,
    required this.veryGoodGustDifference,
    required this.goodWind,
    required this.goodGust,
    required this.limitedWindStart,
    required this.limitedGustStart,
    required this.limitedGustDifference,
    required this.unsuitableWind,
    required this.unsuitableGust,
    required this.unsuitableGustDifference,
  });

  final double veryGoodWind;
  final double veryGoodGust;
  final double veryGoodGustDifference;
  final double goodWind;
  final double goodGust;
  final double limitedWindStart;
  final double limitedGustStart;
  final double limitedGustDifference;
  final double unsuitableWind;
  final double unsuitableGust;
  final double unsuitableGustDifference;
}
