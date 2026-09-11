import 'package:shared_preferences/shared_preferences.dart';

/// Stores only the user's station choices. Live data is deliberately never
/// persisted, so a new app session cannot display stale measurements.
class FavoritesService {
  static const preferenceKey = 'favorite_station_uuids_v1';

  final SharedPreferencesAsync _preferences;

  FavoritesService({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  Future<List<String>> load({required List<String> validStationUuids}) async {
    final stored = await _preferences.getStringList(preferenceKey);
    final valid = validStationUuids.toSet();
    final favorites = (stored ?? validStationUuids)
        .where(valid.contains)
        .toSet()
        .toList();

    // Keep a previously stored ordering, while retaining every valid default
    // only on the first app start.
    if (stored != null && favorites.length != stored.length) {
      await _preferences.setStringList(preferenceKey, favorites);
    }
    return favorites;
  }

  Future<List<String>> toggle({
    required String stationUuid,
    required List<String> currentFavorites,
  }) async {
    final updated = List<String>.from(currentFavorites);
    if (updated.contains(stationUuid)) {
      updated.remove(stationUuid);
    } else {
      updated.add(stationUuid);
    }
    await _preferences.setStringList(preferenceKey, updated);
    return updated;
  }
}
