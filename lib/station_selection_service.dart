import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bafu_hydro_service.dart';
import 'pegelonline_service.dart';
import 'vorarlberg_hydro_service.dart';

/// Holds the station currently selected across all primary app pages.
///
/// The saved start station is deliberately only used once, when there is no
/// remembered last-used station during a fresh app start.
class StationSelectionService extends ChangeNotifier {
  StationSelectionService({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const lastSelectedStationPreferenceKey = 'selected_station_uuid';
  static const startStationPreferenceKey = 'start_station_uuid';

  static const stations = <PegelStation>[
    PegelOnlineService.konstanz,
    BafuHydroService.romanshorn,
    VorarlbergHydroService.bregenz,
  ];

  final SharedPreferencesAsync _preferences;
  PegelStation _currentStation = PegelOnlineService.konstanz;
  Future<void>? _initialRestore;

  PegelStation get currentStation => _currentStation;

  /// Restores the last manually selected station first. The independently
  /// configured start station is only the fallback for a new installation.
  Future<void> restoreInitialStation() =>
      _initialRestore ??= _restoreInitialStation();

  Future<void> _restoreInitialStation() async {
    try {
      final lastSelectedUuid = await _preferences.getString(
        lastSelectedStationPreferenceKey,
      );
      final startStationUuid = await _preferences.getString(
        startStationPreferenceKey,
      );
      final restored =
          _stationForUuid(lastSelectedUuid) ??
          _stationForUuid(startStationUuid);
      if (restored != null) select(restored, persistLast: false);
    } catch (_) {
      // The built-in Konstanz default remains available when local storage
      // cannot be read.
    }
  }

  void select(PegelStation station, {bool persistLast = true}) {
    if (station.uuid == _currentStation.uuid) return;
    _currentStation = station;
    notifyListeners();
    if (persistLast) {
      unawaited(
        _preferences.setString(lastSelectedStationPreferenceKey, station.uuid),
      );
    }
  }

  PegelStation? _stationForUuid(String? uuid) {
    for (final station in stations) {
      if (station.uuid == uuid) return station;
    }
    return null;
  }
}
