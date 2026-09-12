import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bodensee_pegel/activities_boats_service.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('stores activities and several boat profiles locally', () async {
    final service = ActivitiesBoatsService();
    await service.saveActivities(['segeln', 'baden']);
    await service.saveBoats(const [
      BoatProfile(id: '1', name: 'Seestern', bootType: BoatType.sailboat),
      BoatProfile(id: '2', name: 'Albatros', bootType: BoatType.motorboat),
    ]);

    final restored = await ActivitiesBoatsService().load(
      validActivities: ['segeln', 'baden', 'wandern'],
    );
    expect(restored.selectedActivities, orderedEquals(['segeln', 'baden']));
    expect(
      restored.boats.map((boat) => boat.name),
      orderedEquals(['Seestern', 'Albatros']),
    );
    expect(restored.boats.last.bootType, BoatType.motorboat);
  });
}
