import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bafu_hydro_service.dart';
import 'environment_service.dart';
import 'pegelonline_service.dart';
import 'vorarlberg_hydro_service.dart';

void main() => runApp(const BodenseePegelApp());

abstract final class AppColors {
  static const blue = Color(0xFF0879EE);
  static const deepBlue = Color(0xFF064BA7);
  static const navy = Color(0xFF082E61);
  static const mist = Color(0xFFF5F8FD);
  static const green = Color(0xFF16B950);
  static const red = Color(0xFFC44040);
}

class StationReading {
  const StationReading({
    required this.value,
    required this.timestamp,
    this.officialState,
  });

  final double value;
  final DateTime timestamp;
  final String? officialState;
}

class StationLiveData {
  const StationLiveData({
    required this.current,
    required this.history24Hours,
    required this.change24Hours,
    required this.unit,
    required this.fractionDigits,
    required this.changeFractionDigits,
    this.originalWaterLevelLabel,
    this.forecast,
  });

  final StationReading current;
  final List<StationReading>? history24Hours;
  final double? change24Hours;
  final String unit;
  final int fractionDigits;
  final int changeFractionDigits;
  final String? originalWaterLevelLabel;
  final BafuForecastData? forecast;

  String formatValue(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(fractionDigits).replaceAll('.', ',');

  String formatChange(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(changeFractionDigits).replaceAll('.', ',');

  String get formattedTime {
    final localTime = current.timestamp.toLocal();
    final hour = localTime.hour.toString().padLeft(2, '0');
    final minute = localTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class BodenseePegelApp extends StatelessWidget {
  const BodenseePegelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Bodensee Pegel+',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: AppColors.blue),
          scaffoldBackgroundColor: AppColors.mist,
          textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Roboto'),
        ),
        home: const DashboardPage(),
      );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const _selectedStationPreferenceKey = 'selected_station_uuid';

  final _pegelOnlineService = PegelOnlineService();
  final _bafuService = BafuHydroService();
  final _vorarlbergService = VorarlbergHydroService();
  final _environmentService = EnvironmentService();
  final _preferences = SharedPreferencesAsync();
  late Future<List<PegelStation>> _stations;
  late Future<StationLiveData> _liveData;
  late Future<StationEnvironmentData> _environmentData;
  PegelStation _selectedStation = PegelOnlineService.konstanz;

  @override
  void initState() {
    super.initState();
    _stations = Future.value(const [
      PegelOnlineService.konstanz,
      BafuHydroService.romanshorn,
      VorarlbergHydroService.bregenz,
    ]);
    _liveData = _loadLiveData(_selectedStation);
    _environmentData = _environmentService.fetchFor(_selectedStation);
    _restoreSelectedStation();
  }

  Future<void> _restoreSelectedStation() async {
    try {
      final savedUuid = await _preferences.getString(_selectedStationPreferenceKey);
      if (savedUuid == null) return;
      final stations = await _stations;
      PegelStation? savedStation;
      for (final station in stations) {
        if (station.uuid == savedUuid) {
          savedStation = station;
          break;
        }
      }
      if (savedStation != null && mounted) {
        _selectStation(savedStation, persist: false);
      }
    } catch (_) {
      // Local storage must never prevent the default live station from loading.
    }
  }

  void _selectStation(PegelStation station, {bool persist = true}) {
    if (station.uuid == _selectedStation.uuid) return;
    setState(() {
      _selectedStation = station;
      _liveData = _loadLiveData(station);
      _environmentData = _environmentService.fetchFor(station);
    });
    if (persist) {
      _preferences.setString(_selectedStationPreferenceKey, station.uuid);
    }
  }

  Future<void> _openStationSelector(List<PegelStation> stations) async {
    if (stations.isEmpty) return;
    final station = await showModalBottomSheet<PegelStation>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _StationSelector(
        stations: stations,
        selectedStation: _selectedStation,
      ),
    );
    if (station != null && mounted) {
      _selectStation(station);
    }
  }

  void _refresh() => setState(() {
        _liveData = _loadLiveData(_selectedStation);
        _environmentData = _environmentService.fetchFor(_selectedStation);
      });

  Future<StationLiveData> _loadLiveData(PegelStation station) async {
    if (station.source == StationSource.bafu) {
      final liveData = await _bafuService.fetchRomanshornLiveData();
      BafuForecastData? forecast;
      try {
        forecast = await _bafuService.fetchRomanshornForecast();
      } on BafuHydroException {
        // The independent live measurement remains visible without a forecast.
      }
      final reference = station.waterLevelReferenceMasl;
      if (reference == null) throw const BafuHydroException();
      return StationLiveData(
        current: StationReading(
          value: _waterLevelCm(liveData.current.waterLevelMasl, reference),
          timestamp: liveData.current.timestamp,
        ),
        history24Hours: liveData.history24Hours
            ?.map((reading) => StationReading(
                  value: _waterLevelCm(reading.waterLevelMasl, reference),
                  timestamp: reading.timestamp,
                ))
            .toList(),
        change24Hours: liveData.change24Hours == null ? null : liveData.change24Hours! * 100,
        unit: 'cm',
        fractionDigits: 0,
        changeFractionDigits: 1,
        originalWaterLevelLabel: '${liveData.current.waterLevelMasl.toStringAsFixed(3).replaceAll('.', ',')} m ü. M.',
        forecast: forecast,
      );
    }
    if (station.source == StationSource.vorarlberg) {
      final liveData = await _vorarlbergService.fetchBregenzLiveData();
      return StationLiveData(
        current: StationReading(
          value: liveData.waterLevelCm,
          timestamp: liveData.timestamp,
        ),
        history24Hours: null,
        change24Hours: null,
        unit: 'cm',
        fractionDigits: 1,
        changeFractionDigits: 1,
      );
    }
    final liveData = await _pegelOnlineService.fetchLiveData(station);
    return StationLiveData(
      current: StationReading(
        value: liveData.current.waterLevelCm,
        timestamp: liveData.current.timestamp,
        officialState: liveData.current.officialState,
      ),
      history24Hours: liveData.history24Hours
          ?.map((reading) => StationReading(value: reading.waterLevelCm, timestamp: reading.timestamp))
          .toList(),
      change24Hours: liveData.change24Hours,
      unit: station.unit,
      fractionDigits: 1,
      changeFractionDigits: 1,
    );
  }

  double _waterLevelCm(double waterLevelMasl, double referenceMasl) =>
      (waterLevelMasl - referenceMasl) * 100;

  @override
  Widget build(BuildContext context) => Scaffold(
        bottomNavigationBar: const _BottomNavigation(),
        body: Stack(
          children: [
            const _PhotoBackdrop(),
            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 140),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Header(),
                    const SizedBox(height: 58),
                    FutureBuilder<List<PegelStation>>(
                      future: _stations,
                      builder: (context, stationsSnapshot) => FutureBuilder<StationLiveData>(
                        future: _liveData,
                        builder: (context, liveSnapshot) => _LiveLevelCard(
                          selectedStation: _selectedStation,
                          stations: stationsSnapshot.data ?? const [],
                          liveSnapshot: liveSnapshot,
                          onOpenStationSelector: _openStationSelector,
                          onRefresh: _refresh,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FutureBuilder<StationLiveData>(
                      future: _liveData,
                      builder: (context, snapshot) => _ForecastCard(
                        station: _selectedStation,
                        forecast: snapshot.hasData && !snapshot.hasError ? snapshot.data!.forecast : null,
                        waiting: snapshot.connectionState == ConnectionState.waiting,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FutureBuilder<StationEnvironmentData>(
                      key: ValueKey('environment-${_selectedStation.uuid}'),
                      future: _environmentData,
                      builder: (context, snapshot) => _EnvironmentInfoCard(
                        config: _environmentService.configFor(_selectedStation),
                        data: snapshot.hasData && !snapshot.hasError ? snapshot.data : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class _PhotoBackdrop extends StatelessWidget {
  const _PhotoBackdrop();

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: 470,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                'https://www.travelstuttgart.com/uploads/5/6/1/0/5610753/konz1_4_orig.jpg',
                fit: BoxFit.cover,
                alignment: Alignment.center,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF127FC9)),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xD90052AE), Color(0xA3108BD0), Color(0x1AFFFFFF)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
            child: const Icon(Icons.waves_rounded, color: Colors.white, size: 43),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Text('Bodensee Pegel+', style: TextStyle(color: Colors.white, fontSize: 29, fontWeight: FontWeight.w800, letterSpacing: -1)),
          ),
          const Icon(Icons.notifications_none_rounded, color: Colors.white, size: 34),
          const SizedBox(width: 14),
          const Icon(Icons.menu_rounded, color: Colors.white, size: 38),
        ],
      );
}

class _LiveLevelCard extends StatelessWidget {
  const _LiveLevelCard({
    required this.selectedStation,
    required this.stations,
    required this.liveSnapshot,
    required this.onOpenStationSelector,
    required this.onRefresh,
  });

  final PegelStation selectedStation;
  final List<PegelStation> stations;
  final AsyncSnapshot<StationLiveData> liveSnapshot;
  final ValueChanged<List<PegelStation>> onOpenStationSelector;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final data = liveSnapshot.hasData &&
            liveSnapshot.connectionState != ConnectionState.waiting &&
            !liveSnapshot.hasError
        ? liveSnapshot.data
        : null;
    final unavailable = liveSnapshot.hasError;
    final loading = liveSnapshot.connectionState == ConnectionState.waiting;
    final level = data == null ? '—' : data.formatValue(data.current.value);
    final updateLabel = data != null
        ? 'Letzte Aktualisierung: ${data.formattedTime}'
        : unavailable
            ? 'Daten aktuell nicht verfügbar'
            : 'Live-Daten werden geladen …';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 25, 28, 20),
      decoration: _cardDecoration(radius: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.location_on_outlined, color: AppColors.deepBlue, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                button: true,
                label: 'Messstelle auswählen',
                child: InkWell(
                  onTap: stations.isEmpty ? null : () => onOpenStationSelector(stations),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: Text(selectedStation.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.deepBlue, fontSize: 23, fontWeight: FontWeight.w800))),
                      const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.deepBlue),
                    ]),
                  ),
                ),
              ),
            ),
            IconButton(onPressed: loading ? null : onRefresh, tooltip: 'Live-Daten aktualisieren', icon: const Icon(Icons.refresh_rounded, color: AppColors.blue)),
          ]),
          const SizedBox(height: 8),
          Text(updateLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: unavailable ? AppColors.red : const Color(0xFF64738D), fontSize: 16)),
          const SizedBox(height: 28),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(level, style: const TextStyle(color: AppColors.navy, fontSize: 96, height: .82, fontWeight: FontWeight.w900, letterSpacing: -5)))),
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(data?.unit ?? '', style: const TextStyle(color: AppColors.navy, fontSize: 29, fontWeight: FontWeight.w800))),
          ]),
          if (data?.originalWaterLevelLabel case final originalValue?) ...[
            const SizedBox(height: 7),
            Text(
              originalValue,
              style: const TextStyle(color: Color(0xFF64738D), fontSize: 14),
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Change24Hours(data: data, unavailable: unavailable),
              if (data?.current.officialState case final state?) _OfficialStatus(state: state),
            ],
          ),
          const SizedBox(height: 18),
          _HistorySparkline(
            history: data?.history24Hours,
            verticalMargin: selectedStation.source == StationSource.bafu ? .02 : 2,
          ),
        ],
      ),
    );
  }
}

class _StationSelector extends StatelessWidget {
  const _StationSelector({
    required this.stations,
    required this.selectedStation,
  });

  final List<PegelStation> stations;
  final PegelStation selectedStation;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD7E2F0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'MESSSTELLE AUSWÄHLEN',
                style: TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              ...stations.map(
                (station) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: station.uuid == selectedStation.uuid
                        ? const Color(0xFFF1F7FF)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => Navigator.pop(context, station),
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: station.uuid == selectedStation.uuid
                                ? AppColors.blue
                                : const Color(0xFFE1E9F4),
                            width: station.uuid == selectedStation.uuid ? 1.5 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: const BoxDecoration(
                                color: Color(0xFFEAF3FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.location_on_outlined,
                                color: AppColors.blue,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    station.name,
                                    style: const TextStyle(
                                      color: AppColors.navy,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (station.waterName != null) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      station.waterName!,
                                      style: const TextStyle(
                                        color: Color(0xFF64738D),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Icon(
                              station.uuid == selectedStation.uuid
                                  ? Icons.check_circle_rounded
                                  : Icons.chevron_right_rounded,
                              color: station.uuid == selectedStation.uuid
                                  ? AppColors.blue
                                  : const Color(0xFF9AABC0),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _Change24Hours extends StatelessWidget {
  const _Change24Hours({required this.data, required this.unavailable});

  final StationLiveData? data;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final change = data?.change24Hours;
    if (change == null) {
      final liveData = data;
      final historyUnavailable = liveData != null && liveData.history24Hours == null;
      return Text(
        unavailable || historyUnavailable
            ? '24-h-Veränderung nicht verfügbar'
            : '24-h-Veränderung wird geladen …',
        style: const TextStyle(color: Color(0xFF64738D), fontSize: 16),
      );
    }
    final sign = change > 0 ? '+' : change < 0 ? '−' : '±';
    final value = data?.formatChange(change.abs()) ?? '';
    final unit = data!.unit;
    final color = change == 0 ? const Color(0xFF64738D) : change > 0 ? AppColors.green : AppColors.red;
    final icon = change > 0 ? Icons.arrow_upward_rounded : change < 0 ? Icons.arrow_downward_rounded : Icons.remove_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(22)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 21),
        const SizedBox(width: 8),
        Text('$sign$value $unit in 24 h', style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

class _OfficialStatus extends StatelessWidget {
  const _OfficialStatus({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final label = switch (state) {
      'normal' => 'NORMAL',
      'low' => 'NIEDRIG',
      'high' => 'HOCH',
      'out-dated' => 'VERALTETE MESSUNG',
      'commented' => 'MESSUNG KOMMENTIERT',
      _ => null,
    };
    if (label == null) return const SizedBox.shrink();
    final color = state == 'normal' ? AppColors.green : state == 'high' ? AppColors.red : const Color(0xFF64738D);
    return Row(children: [
      Icon(Icons.circle, color: color, size: 15),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
    ]);
  }
}

class _UnavailableInfoCard extends StatelessWidget {
  const _UnavailableInfoCard({required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: _cardDecoration(),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 44, height: 44, decoration: const BoxDecoration(color: Color(0xFFEAF3FF), shape: BoxShape.circle), child: Icon(icon, color: AppColors.blue)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: AppColors.deepBlue, fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Text(message, style: const TextStyle(color: Color(0xFF64738D), fontSize: 15, height: 1.3)),
          ])),
        ]),
      );
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({
    required this.station,
    required this.forecast,
    required this.waiting,
  });

  final PegelStation station;
  final BafuForecastData? forecast;
  final bool waiting;

  static const _referenceMasl = BafuHydroService.romanshornReferenceMasl;

  @override
  Widget build(BuildContext context) {
    if (station.source != StationSource.bafu) {
      return const _UnavailableInfoCard(
        icon: Icons.show_chart_rounded,
        title: 'PROGNOSE',
        message: 'Für diese Station derzeit keine maschinenlesbare Behördenprognose verfügbar.',
      );
    }
    final data = forecast;
    if (data == null) {
      return _UnavailableInfoCard(
        icon: Icons.show_chart_rounded,
        title: 'PROGNOSE',
        message: waiting
            ? 'BAFU-Prognose wird geladen …'
            : 'BAFU-Prognose aktuell nicht verfügbar.',
      );
    }
    final tomorrow = _pointAt(data.points, const Duration(days: 1));
    final trend = _trend(data.points);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.show_chart_rounded, color: AppColors.blue),
              SizedBox(width: 10),
              Text(
                'PROGNOSE',
                style: TextStyle(color: AppColors.deepBlue, fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: _NextForecastValue(point: tomorrow, trend: trend),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SizedBox(
                  height: 146,
                  child: CustomPaint(
                    painter: _ForecastChartPainter(data.points, _referenceMasl),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          const Text(
            'Quelle: BAFU · Prognose mit Unsicherheitsbereich',
            style: TextStyle(color: Color(0xFF8B98AC), fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFEAF3FF),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Diagramm ansehen',
                  style: TextStyle(color: AppColors.blue, fontSize: 16, fontWeight: FontWeight.w800),
                ),
                SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: AppColors.blue, size: 25),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _trend(List<BafuForecastPoint> points) {
    final differenceCm = (points.last.medianMasl - points.first.medianMasl) * 100;
    if (differenceCm > .5) return 'steigend';
    if (differenceCm < -.5) return 'fallend';
    return 'etwa gleich';
  }

  BafuForecastPoint _pointAt(List<BafuForecastPoint> points, Duration offset) {
    final target = points.first.timestamp.add(offset);
    return points.reduce(
      (closest, candidate) => candidate.timestamp.difference(target).inMilliseconds.abs() <
              closest.timestamp.difference(target).inMilliseconds.abs()
          ? candidate
          : closest,
    );
  }
}

class _NextForecastValue extends StatelessWidget {
  const _NextForecastValue({required this.point, required this.trend});

  final BafuForecastPoint point;
  final String trend;

  @override
  Widget build(BuildContext context) {
    final levelCm = (point.medianMasl - BafuHydroService.romanshornReferenceMasl) * 100;
    final local = point.timestamp.toLocal();
    final time = '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')} · '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final (icon, label) = switch (trend) {
      'steigend' => (Icons.arrow_upward_rounded, 'Langsam steigend'),
      'fallend' => (Icons.arrow_downward_rounded, 'Langsam fallend'),
      _ => (Icons.arrow_forward_rounded, 'Etwa gleich'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('MORGEN', style: TextStyle(color: Color(0xFF64738D), fontSize: 11, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('${levelCm.round()}', style: const TextStyle(color: AppColors.navy, fontSize: 42, height: .9, fontWeight: FontWeight.w900, letterSpacing: -2)),
        const Text('cm', style: TextStyle(color: AppColors.navy, fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 7),
        Text(time, style: const TextStyle(color: Color(0xFF8B98AC), fontSize: 10)),
        const SizedBox(height: 9),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.blue, size: 17),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label, style: const TextStyle(color: AppColors.blue, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ],
    );
  }
}

class _ForecastChartPainter extends CustomPainter {
  _ForecastChartPainter(this.points, this.referenceMasl);

  final List<BafuForecastPoint> points;
  final double referenceMasl;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final low = points.map((point) => (point.minimumMasl - referenceMasl) * 100).reduce(math.min).toDouble();
    final high = points.map((point) => (point.maximumMasl - referenceMasl) * 100).reduce(math.max).toDouble();
    // A generous visual margin prevents one-centimetre forecast steps from
    // being exaggerated while leaving every source value untouched.
    final displayMin = low - 4;
    final displayMax = high + 4;
    final range = displayMax - displayMin;
    final horizontalPadding = 2.0;
    final verticalPadding = 5.0;
    const axisHeight = 21.0;
    final drawableWidth = size.width - 2 * horizontalPadding;
    final drawableHeight = size.height - verticalPadding - axisHeight;
    final firstTime = points.first.timestamp;
    final duration = points.last.timestamp.difference(firstTime).inMilliseconds;

    Offset position(BafuForecastPoint point, double value) {
      final elapsed = point.timestamp.difference(firstTime).inMilliseconds;
      final x = horizontalPadding + drawableWidth * (duration == 0 ? 0 : elapsed / duration);
      final y = verticalPadding + drawableHeight * (1 - (value - displayMin) / range);
      return Offset(x, y);
    }

    final upper = points
        .map((point) => position(point, (point.maximumMasl - referenceMasl) * 100))
        .toList();
    final lower = points
        .map((point) => position(point, (point.minimumMasl - referenceMasl) * 100))
        .toList();
    final median = points
        .map((point) => position(point, (point.medianMasl - referenceMasl) * 100))
        .toList();
    _drawTimeAxis(canvas, size, duration, horizontalPadding, verticalPadding, drawableWidth, drawableHeight);

    final area = _smoothPath(upper);
    _appendSmoothPath(area, lower.reversed.toList());
    area.close();
    canvas.drawPath(area, Paint()..color = AppColors.blue.withValues(alpha: .10));

    // The Bezier controls only round the joins. The path still passes through
    // every official BAFU point; it neither adds nor changes forecast values.
    final line = _smoothPath(median);
    canvas.drawPath(
      line,
      Paint()
        ..color = AppColors.deepBlue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawTimeAxis(
    Canvas canvas,
    Size size,
    int durationMs,
    double horizontalPadding,
    double verticalPadding,
    double drawableWidth,
    double drawableHeight,
  ) {
    final durationHours = durationMs / Duration.millisecondsPerHour;
    final tickHours = <double>[0, 24, 48, 72, 96]
        .where((hour) => hour < durationHours)
        .toList();
    if (durationHours > 0) tickHours.add(durationHours);

    final gridPaint = Paint()
      ..color = const Color(0xFFE2EAF5)
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(color: Color(0xFF64738D), fontSize: 9);
    for (final hour in tickHours) {
      final fraction = durationHours == 0 ? 0.0 : hour / durationHours;
      final x = horizontalPadding + drawableWidth * fraction;
      canvas.drawLine(Offset(x, verticalPadding), Offset(x, verticalPadding + drawableHeight), gridPaint);
      final label = hour == 0
          ? 'Jetzt'
          : (hour - durationHours).abs() < .1 && durationHours >= 108
              ? '5 Tage'
              : '${hour.round()}h';
      final textPainter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = (x - textPainter.width / 2).clamp(0.0, size.width - textPainter.width).toDouble();
      textPainter.paint(canvas, Offset(labelX, verticalPadding + drawableHeight + 5));
    }
  }

  Path _smoothPath(List<Offset> values) {
    final path = Path()..moveTo(values.first.dx, values.first.dy);
    _appendSmoothPath(path, values, moveToFirst: false);
    return path;
  }

  void _appendSmoothPath(Path path, List<Offset> values, {bool moveToFirst = true}) {
    if (values.isEmpty) return;
    if (moveToFirst) {
      path.lineTo(values.first.dx, values.first.dy);
    }
    for (var index = 0; index < values.length - 1; index++) {
      final previous = index == 0 ? values[index] : values[index - 1];
      final current = values[index];
      final next = values[index + 1];
      final following = index + 2 < values.length ? values[index + 2] : next;
      final controlOne = Offset(
        current.dx + (next.dx - previous.dx) / 6,
        current.dy + (next.dy - previous.dy) / 6,
      );
      final controlTwo = Offset(
        next.dx - (following.dx - current.dx) / 6,
        next.dy - (following.dy - current.dy) / 6,
      );
      path.cubicTo(controlOne.dx, controlOne.dy, controlTwo.dx, controlTwo.dy, next.dx, next.dy);
    }
  }

  @override
  bool shouldRepaint(covariant _ForecastChartPainter oldDelegate) => oldDelegate.points != points;
}

class _EnvironmentInfoCard extends StatelessWidget {
  const _EnvironmentInfoCard({required this.config, required this.data});

  final EnvironmentStationConfig config;
  final StationEnvironmentData? data;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        decoration: _cardDecoration(),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _EnvironmentSection(
                  icon: Icons.water_drop_outlined,
                  title: 'WASSERTEMP.',
                  value: _temperature(data?.waterTemperatureC),
                  detail: data?.waterTemperatureC == null
                      ? 'nicht verfügbar'
                      : config.waterTemperatureDepthLabel ?? '',
                  accent: const Color(0xFF11B6C7),
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE1E9F4)),
              Expanded(
                child: _EnvironmentSection(
                  icon: Icons.air_rounded,
                  title: 'WIND',
                  value: _windValue(data),
                  detail: data?.windSpeedMetersPerSecond == null
                      ? 'nicht verfügbar'
                      : _windDetail(data?.windDirectionDegrees, config.windSourceLabel),
                  accent: AppColors.blue,
                  directionDegrees: data?.windDirectionDegrees,
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE1E9F4)),
              Expanded(
                child: _EnvironmentSection(
                  icon: Icons.thermostat_rounded,
                  title: 'LUFT',
                  value: _temperature(data?.airTemperatureC),
                  detail: data?.airTemperatureC == null ? 'nicht verfügbar' : config.airSourceLabel,
                  accent: const Color(0xFFFFA91B),
                ),
              ),
            ],
          ),
        ),
      );

  String _temperature(double? value) => value == null ? '–' : '${value.toStringAsFixed(1).replaceAll('.', ',')} °C';

  String _windValue(StationEnvironmentData? data) {
    final speed = data?.windSpeedMetersPerSecond;
    if (speed == null) return '–';
    return '${(speed * 3.6).toStringAsFixed(1).replaceAll('.', ',')} km/h';
  }

  String _windDetail(double? direction, String source) =>
      direction == null ? source : '${_compassPoint(direction)} · $source';

  String _compassPoint(double degrees) {
    const points = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
    return points[((degrees % 360) / 45).round() % points.length];
  }
}

class _EnvironmentSection extends StatelessWidget {
  const _EnvironmentSection({
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    required this.accent,
    this.directionDegrees,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final Color accent;
  final double? directionDegrees;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: accent.withValues(alpha: .11), shape: BoxShape.circle),
              child: Icon(icon, color: accent, size: 25),
            ),
            const SizedBox(height: 9),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.navy, fontSize: 10, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: value == '–' ? const Color(0xFF8B98AC) : accent, fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                if (directionDegrees != null) ...[
                  const SizedBox(width: 2),
                  Transform.rotate(
                    angle: directionDegrees! * math.pi / 180,
                    child: Icon(Icons.arrow_upward_rounded, color: AppColors.navy, size: 13),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF8B98AC), fontSize: 10)),
          ],
        ),
      );
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation();

  @override
  Widget build(BuildContext context) => Container(
        height: 99,
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Color(0x14052F65), blurRadius: 18, offset: Offset(0, -4))]),
        child: const Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _NavItem(icon: Icons.waves_rounded, label: 'Live', active: true),
          _NavItem(icon: Icons.query_stats_rounded, label: 'Analyse'),
          _NavItem(icon: Icons.location_on_outlined, label: 'Karte'),
          _NavItem(icon: Icons.person_outline_rounded, label: 'Mehr'),
        ]),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, this.active = false});

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 21, vertical: 6), decoration: BoxDecoration(color: active ? const Color(0xFFE7F1FF) : Colors.transparent, borderRadius: BorderRadius.circular(20)), child: Icon(icon, color: active ? AppColors.blue : AppColors.navy, size: 31)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: active ? AppColors.blue : AppColors.navy, fontWeight: active ? FontWeight.w800 : FontWeight.w600)),
      ]);
}

BoxDecoration _cardDecoration({double radius = 26}) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [BoxShadow(color: Color(0x10092E60), blurRadius: 22, offset: Offset(0, 9))],
    );

class _HistorySparkline extends StatelessWidget {
  const _HistorySparkline({required this.history, required this.verticalMargin});

  final List<StationReading>? history;
  final double verticalMargin;

  @override
  Widget build(BuildContext context) {
    if (history == null || history!.isEmpty) {
      return const SizedBox(
        height: 55,
        child: Center(
          child: Text(
            '24-h-Verlauf nicht verfügbar',
            style: TextStyle(color: Color(0xFF64738D), fontSize: 15),
          ),
        ),
      );
    }
    return SizedBox(
      height: 96,
      width: double.infinity,
      child: Column(
        children: [
          SizedBox(
            height: 72,
            width: double.infinity,
            child: CustomPaint(
              painter: _HistorySparklinePainter(history!, verticalMargin),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 5),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('vor 24 h', style: TextStyle(color: Color(0xFF8B98AC), fontSize: 12)),
              Text('jetzt', style: TextStyle(color: Color(0xFF8B98AC), fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistorySparklinePainter extends CustomPainter {
  _HistorySparklinePainter(this.history, this.verticalMargin);

  final List<StationReading> history;
  final double verticalMargin;

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;

    final values = history.map((reading) => reading.value).toList();
    final minValue = values.reduce(math.min).toDouble();
    final maxValue = values.reduce(math.max).toDouble();
    // The display margin scales with the station's original unit. The actual
    // API readings are not changed.
    final displayMin = minValue - verticalMargin;
    final displayMax = maxValue + verticalMargin;
    final valueRange = displayMax - displayMin;
    final horizontalPadding = 3.0;
    final verticalPadding = 8.0;
    final drawableHeight = size.height - 2 * verticalPadding;
    final points = <Offset>[];

    final firstTimestamp = history.first.timestamp;
    final lastTimestamp = history.last.timestamp;
    final durationMs = lastTimestamp.difference(firstTimestamp).inMilliseconds;
    for (var index = 0; index < history.length; index++) {
      final elapsedMs = history[index].timestamp.difference(firstTimestamp).inMilliseconds;
      final relativePosition = durationMs == 0 ? index / (history.length - 1) : elapsedMs / durationMs;
      final x = horizontalPadding +
          (size.width - 2 * horizontalPadding) *
              relativePosition.clamp(0.0, 1.0).toDouble();
      final normalizedValue = (history[index].value - displayMin) / valueRange;
      final y = verticalPadding + drawableHeight * (1 - normalizedValue);
      points.add(Offset(x, y));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length - 1; index++) {
      final midpoint = Offset(
        (points[index].dx + points[index + 1].dx) / 2,
        (points[index].dy + points[index + 1].dy) / 2,
      );
      path.quadraticBezierTo(points[index].dx, points[index].dy, midpoint.dx, midpoint.dy);
    }
    path.quadraticBezierTo(
      points.last.dx,
      points.last.dy,
      points.last.dx,
      points.last.dy,
    );
    final fillPath = Path.from(path)
      ..lineTo(size.width - horizontalPadding, size.height)
      ..lineTo(horizontalPadding, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x330879EE), Color(0x000879EE)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
