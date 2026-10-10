import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bodensee_pegel/activities_boats_service.dart';
import 'package:bodensee_pegel/activity_rating_service.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('stores activities and several boat profiles locally', () async {
    final service = ActivitiesBoatsService();
    await service.saveActivities(['segeln', 'baden', 'radfahren', 'wandern']);
    await service.saveBoats(const [
      BoatProfile(id: '1', name: 'Seestern', bootType: BoatType.sailboat),
      BoatProfile(id: '2', name: 'Albatros', bootType: BoatType.motorboat),
    ]);

    final restored = await ActivitiesBoatsService().load(
      validActivities: ['segeln', 'baden'],
    );
    expect(restored.selectedActivities, orderedEquals(['segeln', 'baden']));
    expect(
      restored.boats.map((boat) => boat.name),
      orderedEquals(['Seestern', 'Albatros']),
    );
    expect(restored.boats.last.bootType, BoatType.motorboat);
  });

  test('stores and restores the optional motorboat rating profile', () async {
    final service = ActivitiesBoatsService();
    await service.saveMotorboatRatingProfile(MotorboatRatingProfile.smallOpen);

    final restored = await ActivitiesBoatsService().load(
      validActivities: const ['motorboot'],
    );
    expect(restored.motorboatRatingProfile, MotorboatRatingProfile.smallOpen);

    await service.saveMotorboatRatingProfile(null);
    final legacy = await ActivitiesBoatsService().load(
      validActivities: const ['motorboot'],
    );
    expect(legacy.motorboatRatingProfile, isNull);
  });
}
