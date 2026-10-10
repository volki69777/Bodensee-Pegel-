import 'dart:convert';

import 'activity_rating_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BoatType { motorboat, sailboat }

/// Local profile data for a boat. It deliberately has no safety assessment or
/// water-level calculation attached; that will be added only with verified
/// rules in a later version.
class BoatProfile {
  const BoatProfile({
    required this.id,
    required this.bootType,
    this.name,
    this.lengthMeters,
    this.widthMeters,
    this.draftMeters,
    this.heightAboveWaterlineMeters,
  });

  final String id;
  final String? name;
  final BoatType bootType;
  final double? lengthMeters;
  final double? widthMeters;
  final double? draftMeters;
  final double? heightAboveWaterlineMeters;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'bootType': bootType.name,
    'lengthMeters': lengthMeters,
    'widthMeters': widthMeters,
    'draftMeters': draftMeters,
    'heightAboveWaterlineMeters': heightAboveWaterlineMeters,
  };

  factory BoatProfile.fromJson(Map<String, dynamic> json) {
    final type = BoatType.values
        .where((candidate) => candidate.name == json['bootType'])
        .firstOrNull;
    if (type == null || json['id'] is! String) {
      throw const FormatException('Ungültiges Bootsprofil');
    }
    double? number(String key) {
      final value = json[key];
      return value is num ? value.toDouble() : double.tryParse('$value');
    }

    return BoatProfile(
      id: json['id'] as String,
      name: json['name'] is String && (json['name'] as String).trim().isNotEmpty
          ? json['name'] as String
          : null,
      bootType: type,
      lengthMeters: number('lengthMeters'),
      widthMeters: number('widthMeters'),
      draftMeters: number('draftMeters'),
      heightAboveWaterlineMeters: number('heightAboveWaterlineMeters'),
    );
  }
}

class ActivitiesBoatsData {
  const ActivitiesBoatsData({
    required this.selectedActivities,
    required this.boats,
    this.motorboatRatingProfile,
  });

  final List<String> selectedActivities;
  final List<BoatProfile> boats;
  final MotorboatRatingProfile? motorboatRatingProfile;
}

/// Stores the user's optional planner preferences locally on the device.
class ActivitiesBoatsService {
  ActivitiesBoatsService({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const activitiesKey = 'selected_lake_activities_v1';
  static const boatsKey = 'boat_profiles_v1';
  static const motorboatRatingProfileKey = 'motorboat_rating_profile_v1';

  final SharedPreferencesAsync _preferences;

  Future<ActivitiesBoatsData> load({
    required List<String> validActivities,
  }) async {
    try {
      final savedActivities = await _preferences.getStringList(activitiesKey);
      final selectedActivities = (savedActivities ?? const <String>[])
          .where(validActivities.contains)
          .toList(growable: false);
      final rawBoats = await _preferences.getString(boatsKey);
      final rawMotorboatProfile = await _preferences.getString(
        motorboatRatingProfileKey,
      );
      final motorboatRatingProfile = MotorboatRatingProfile.values
          .where((profile) => profile.name == rawMotorboatProfile)
          .firstOrNull;
      final decoded = rawBoats == null ? null : jsonDecode(rawBoats);
      final boats = decoded is List
          ? decoded
                .whereType<Map>()
                .map(
                  (entry) =>
                      BoatProfile.fromJson(Map<String, dynamic>.from(entry)),
                )
                .toList()
          : <BoatProfile>[];
      return ActivitiesBoatsData(
        selectedActivities: selectedActivities,
        boats: boats,
        motorboatRatingProfile: motorboatRatingProfile,
      );
    } catch (_) {
      return const ActivitiesBoatsData(selectedActivities: [], boats: []);
    }
  }

  Future<void> saveActivities(List<String> activities) =>
      _preferences.setStringList(activitiesKey, activities);

  Future<void> saveBoats(List<BoatProfile> boats) => _preferences.setString(
    boatsKey,
    jsonEncode(boats.map((boat) => boat.toJson()).toList()),
  );

  Future<void> saveMotorboatRatingProfile(
    MotorboatRatingProfile? profile,
  ) async {
    if (profile == null) {
      await _preferences.remove(motorboatRatingProfileKey);
      return;
    }
    await _preferences.setString(motorboatRatingProfileKey, profile.name);
  }
}
