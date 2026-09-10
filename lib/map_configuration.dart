import 'pegelonline_service.dart';

/// Karten-Konfiguration für KARTE V1.
/// DEVELOPMENT ONLY: Vor Veröffentlichung wird ausschließlich diese Tile-URL
/// gegen einen vertraglich passenden Produktionsanbieter ausgetauscht.
abstract final class MapConfiguration {
  static const developmentTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const attribution = '© OpenStreetMap contributors';
  static const userAgentPackageName = 'de.bodenseepegel.app';

  static const stations = <String, StationMapLocation>{
    // PEGELONLINE station 906, official WGS84 station position.
    'aa9179c1-17ef-4c61-a48a-74193fa7bfdf': StationMapLocation(latitude: 47.6632, longitude: 9.1752),
    // BAFU station 2032: LV95 2746161 / 1269999, transformed to WGS84.
    'bafu-2032': StationMapLocation(latitude: 47.5650, longitude: 9.3810),
    // Wasserwirtschaft Vorarlberg: Bregenz (Seepegel), station 200337.
    'vowis-200337': StationMapLocation(latitude: 47.5037, longitude: 9.7432),
  };

  static StationMapLocation locationFor(PegelStation station) => stations[station.uuid]!;
}

class StationMapLocation {
  const StationMapLocation({required this.latitude, required this.longitude});
  final double latitude;
  final double longitude;
}
