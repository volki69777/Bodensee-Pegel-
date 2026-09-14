import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import 'analysis_service.dart';
import 'activity_rating_service.dart';
import 'activity_time_window_service.dart';
import 'activities_boats_service.dart';
import 'bafu_hydro_service.dart';
import 'dwd_forecast_service.dart';
import 'environment_service.dart';
import 'favorites_service.dart';
import 'geosphere_forecast_service.dart';
import 'insight_service.dart';
import 'map_configuration.dart';
import 'meteoswiss_forecast_service.dart';
import 'official_warning_service.dart';
import 'pegelonline_service.dart';
import 'station_data_cache.dart';
import 'station_selection_service.dart';
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

class BodenseePegelApp extends StatefulWidget {
  const BodenseePegelApp({super.key, this.navigatorObservers = const []});

  final List<NavigatorObserver> navigatorObservers;

  @override
  State<BodenseePegelApp> createState() => _BodenseePegelAppState();
}

class _BodenseePegelAppState extends State<BodenseePegelApp> {
  final _stationSelection = StationSelectionService();

  @override
  void initState() {
    super.initState();
    _stationSelection.restoreInitialStation();
  }

  @override
  void dispose() {
    _stationSelection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StationSelectionScope(
    notifier: _stationSelection,
    child: MaterialApp(
      title: 'Bodensee Pegel+',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.blue),
        scaffoldBackgroundColor: AppColors.mist,
        textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Roboto'),
      ),
      onGenerateInitialRoutes: (initialRouteName) => [
        _appRouteFor(
          RouteSettings(name: initialRouteName),
          redirectToLive:
              AppRoutes.destinationForPath(initialRouteName) == null,
        ),
      ],
      onGenerateRoute: _appRouteFor,
      onUnknownRoute: (settings) => _appRouteFor(
        const RouteSettings(name: AppRoutes.livePath),
        redirectToLive: true,
      ),
      navigatorObservers: widget.navigatorObservers,
    ),
  );
}

class StationSelectionScope extends InheritedNotifier<StationSelectionService> {
  const StationSelectionScope({
    super.key,
    required StationSelectionService notifier,
    required super.child,
  }) : super(notifier: notifier);

  static StationSelectionService? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<StationSelectionScope>()
      ?.notifier;
}

enum AppDestination { today, live, analysis, map, more }

/// Stable main-page paths used by Flutter Web while keeping mobile navigation
/// on the same Navigator API.
abstract final class AppRoutes {
  static const todayPath = '/heute';
  static const livePath = '/live';
  static const analysisPath = '/analyse';
  static const mapPath = '/karte';
  static const morePath = '/mehr';

  static String pathFor(AppDestination destination) => switch (destination) {
    AppDestination.today => todayPath,
    AppDestination.live => livePath,
    AppDestination.analysis => analysisPath,
    AppDestination.map => mapPath,
    AppDestination.more => morePath,
  };

  static AppDestination? destinationForPath(String? path) => switch (path) {
    todayPath => AppDestination.today,
    livePath || '/' || '' => AppDestination.live,
    analysisPath => AppDestination.analysis,
    mapPath => AppDestination.map,
    morePath => AppDestination.more,
    _ => null,
  };

  static String normalize(String? path) => destinationForPath(path) == null
      ? livePath
      : (path == '/' ? livePath : path!);
}

Route<void> _appRouteFor(
  RouteSettings settings, {
  bool redirectToLive = false,
}) {
  final destination = AppRoutes.destinationForPath(settings.name);
  return MaterialPageRoute<void>(
    settings: RouteSettings(
      name: destination == null
          ? AppRoutes.livePath
          : AppRoutes.pathFor(destination),
    ),
    builder: (_) => DashboardPage(
      initialDestination: destination ?? AppDestination.live,
      initialStation: settings.arguments is PegelStation
          ? settings.arguments! as PegelStation
          : null,
      redirectToLive: redirectToLive || destination == null,
    ),
  );
}

void _navigateTo(
  BuildContext context,
  AppDestination destination, {
  PegelStation? initialStation,
}) {
  if (initialStation != null) {
    StationSelectionScope.maybeOf(context)?.select(initialStation);
  }
  final path = AppRoutes.pathFor(destination);
  if (kIsWeb) {
    SystemNavigator.routeInformationUpdated(
      uri: Uri(path: path),
      replace: false,
    );
  }
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: path, arguments: initialStation),
      builder: (_) => DashboardPage(
        initialDestination: destination,
        initialStation: initialStation,
      ),
    ),
    (_) => false,
  );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    this.initialDestination = AppDestination.live,
    this.initialStation,
    this.redirectToLive = false,
  });

  final AppDestination initialDestination;
  final PegelStation? initialStation;
  final bool redirectToLive;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _pegelOnlineService = PegelOnlineService();
  final _bafuService = BafuHydroService();
  final _vorarlbergService = VorarlbergHydroService();
  final _environmentService = EnvironmentService();
  final _favoritesService = FavoritesService();
  final _analysisService = AnalysisService();
  final _insightService = InsightService();
  final _liveDataCache = StationDataCache<StationLiveData>();
  final _insightCache = StationDataCache<BodenseeInsight?>();
  late Future<List<PegelStation>> _stations;
  late Future<StationLiveData> _liveData;
  late Future<StationEnvironmentData> _environmentData;
  late Future<List<String>> _favoriteUuids;
  late Future<BodenseeInsight?> _insight;
  PegelStation _selectedStation = PegelOnlineService.konstanz;
  StationSelectionService? _stationSelection;

  @override
  void initState() {
    super.initState();
    _selectedStation = widget.initialStation ?? PegelOnlineService.konstanz;
    _stations = Future.value(StationSelectionService.stations);
    _liveData = _loadCachedLiveData(_selectedStation);
    _environmentData = _loadEnvironmentData(_selectedStation);
    _insight = _loadCachedInsight(_selectedStation, _liveData);
    _favoriteUuids = _loadFavoriteUuids();
    if (widget.initialDestination != AppDestination.live ||
        widget.redirectToLive) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openInitialDestination(),
      );
    }
  }

  void _openInitialDestination() {
    if (!mounted) return;
    if (widget.redirectToLive) {
      if (kIsWeb) {
        SystemNavigator.routeInformationUpdated(
          uri: Uri(path: AppRoutes.livePath),
          replace: true,
        );
      }
      Navigator.of(context).pushReplacementNamed(AppRoutes.livePath);
      return;
    }
    final page = switch (widget.initialDestination) {
      AppDestination.today => const TodayPage(),
      AppDestination.live => null,
      AppDestination.analysis => const AnalysisPage(),
      AppDestination.map => MapPage(
        selectedStation: _selectedStation,
        loadLiveData: _loadCachedLiveData,
        loadEnvironmentData: _environmentService.fetchFor,
      ),
      AppDestination.more => const MorePage(),
    };
    if (page != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: AppRoutes.pathFor(widget.initialDestination),
          ),
          builder: (_) => page,
        ),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selection = StationSelectionScope.maybeOf(context);
    if (selection == _stationSelection) return;
    _stationSelection?.removeListener(_syncSharedStation);
    _stationSelection = selection;
    selection?.addListener(_syncSharedStation);
    if (widget.initialStation != null) {
      selection?.select(widget.initialStation!);
    }
    _applySelectedStation(selection?.currentStation ?? _selectedStation);
  }

  void _syncSharedStation() {
    final selection = _stationSelection;
    if (selection != null) _applySelectedStation(selection.currentStation);
  }

  void _applySelectedStation(PegelStation station) {
    if (station.uuid == _selectedStation.uuid) return;
    setState(() {
      _selectedStation = station;
      _liveData = _loadCachedLiveData(station);
      _environmentData = _loadEnvironmentData(station);
      _insight = _loadCachedInsight(station, _liveData);
    });
  }

  void _selectStation(PegelStation station) {
    final selection = _stationSelection;
    if (selection != null) {
      selection.select(station);
      return;
    }
    _applySelectedStation(station);
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
    _liveDataCache.invalidate(_selectedStation.uuid);
    _insightCache.invalidate(_selectedStation.uuid);
    _liveData = _loadCachedLiveData(_selectedStation);
    _environmentData = _loadEnvironmentData(_selectedStation);
    _insight = _loadCachedInsight(_selectedStation, _liveData);
  });

  @override
  void dispose() {
    _stationSelection?.removeListener(_syncSharedStation);
    super.dispose();
  }

  Future<List<String>> _loadFavoriteUuids() async {
    final stations = await _stations;
    return _favoritesService.load(
      validStationUuids: stations.map((station) => station.uuid).toList(),
    );
  }

  Future<void> _toggleFavorite() async {
    final current = await _favoriteUuids;
    final updated = await _favoritesService.toggle(
      stationUuid: _selectedStation.uuid,
      currentFavorites: current,
    );
    if (mounted) {
      setState(() {
        _favoriteUuids = Future.value(updated);
      });
    }
  }

  Future<StationLiveData> _loadCachedLiveData(PegelStation station) =>
      _liveDataCache.get(station.uuid, () => _loadLiveData(station));

  Future<BodenseeInsight?> _loadCachedInsight(
    PegelStation station,
    Future<StationLiveData> liveData,
  ) => _insightCache.get(station.uuid, () => _loadInsight(station, liveData));

  Future<BodenseeInsight?> _loadInsight(
    PegelStation station,
    Future<StationLiveData> liveFuture,
  ) async {
    try {
      final live = await liveFuture;
      return switch (station.source) {
        StationSource.pegelOnline => _insightService.fromKonstanz(
          change24HoursCm: live.change24Hours,
        ),
        StationSource.bafu => _insightService.fromRomanshorn(
          change24HoursCm: live.change24Hours,
          seasonalReference: await _seasonalReferenceOrNull(),
          forecast: live.forecast,
          currentTimestamp: live.current.timestamp,
        ),
        StationSource.vorarlberg => _insightService.fromBregenz(
          change7DaysCm: await _bregenz7DayChangeOrNull(station),
        ),
      };
    } catch (_) {
      return null;
    }
  }

  Future<SeasonalReference?> _seasonalReferenceOrNull() async {
    try {
      return await _analysisService.fetchRomanshornSeasonalReference();
    } on AnalysisException {
      return null;
    }
  }

  Future<double?> _bregenz7DayChangeOrNull(PegelStation station) async {
    try {
      final series = await _analysisService.fetch(
        station,
        AnalysisPeriod.days7,
      );
      if (series.readings.length < 2) return null;
      return series.readings.last.valueCm - series.readings.first.valueCm;
    } on AnalysisException {
      return null;
    }
  }

  Future<StationEnvironmentData> _loadEnvironmentData(PegelStation station) {
    final request = _environmentService.fetchFor(station);
    request.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return request;
  }

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
            ?.map(
              (reading) => StationReading(
                value: _waterLevelCm(reading.waterLevelMasl, reference),
                timestamp: reading.timestamp,
              ),
            )
            .toList(),
        change24Hours: liveData.change24Hours == null
            ? null
            : liveData.change24Hours! * 100,
        unit: 'cm',
        fractionDigits: 0,
        changeFractionDigits: 1,
        originalWaterLevelLabel:
            '${liveData.current.waterLevelMasl.toStringAsFixed(3).replaceAll('.', ',')} m ü. M.',
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
          ?.map(
            (reading) => StationReading(
              value: reading.waterLevelCm,
              timestamp: reading.timestamp,
            ),
          )
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
    bottomNavigationBar: _BottomNavigation(
      onToday: () => _navigateTo(context, AppDestination.today),
      onAnalysis: () => _navigateTo(context, AppDestination.analysis),
      onMap: () => _navigateTo(context, AppDestination.map),
      onMore: () => _navigateTo(context, AppDestination.more),
    ),
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
                  builder: (context, stationsSnapshot) =>
                      FutureBuilder<StationLiveData>(
                        future: _liveData,
                        builder: (context, liveSnapshot) => _LiveLevelCard(
                          selectedStation: _selectedStation,
                          stations: stationsSnapshot.data ?? const [],
                          liveSnapshot: liveSnapshot,
                          onOpenStationSelector: _openStationSelector,
                          onRefresh: _refresh,
                          isFavorite: _favoriteUuids.then(
                            (favorites) =>
                                favorites.contains(_selectedStation.uuid),
                          ),
                          onToggleFavorite: _toggleFavorite,
                        ),
                      ),
                ),
                const SizedBox(height: 24),
                FutureBuilder<StationLiveData>(
                  future: _liveData,
                  builder: (context, snapshot) => ForecastCard(
                    station: _selectedStation,
                    forecast: snapshot.hasData && !snapshot.hasError
                        ? snapshot.data!.forecast
                        : null,
                    waiting:
                        snapshot.connectionState == ConnectionState.waiting,
                  ),
                ),
                const SizedBox(height: 24),
                FutureBuilder<StationEnvironmentData>(
                  key: ValueKey('environment-${_selectedStation.uuid}'),
                  future: _environmentData,
                  builder: (context, snapshot) => _EnvironmentInfoCard(
                    config: _environmentService.configFor(_selectedStation),
                    data: snapshot.hasData && !snapshot.hasError
                        ? snapshot.data
                        : null,
                  ),
                ),
                FutureBuilder<BodenseeInsight?>(
                  key: ValueKey('insight-${_selectedStation.uuid}'),
                  future: _insight,
                  builder: (context, snapshot) {
                    final insight = snapshot.hasData && !snapshot.hasError
                        ? snapshot.data
                        : null;
                    if (insight == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: BodenseeInsightCard(insight: insight),
                    );
                  },
                ),
                const SizedBox(height: 24),
                FutureBuilder<List<String>>(
                  future: _favoriteUuids,
                  builder: (context, snapshot) => _FavoritesSection(
                    stations: (snapshot.data ?? const <String>[])
                        .map(
                          (uuid) => StationSelectionService.stations
                              .where((station) => station.uuid == uuid)
                              .firstOrNull,
                        )
                        .whereType<PegelStation>()
                        .toList(),
                    selectedStation: _selectedStation,
                    loadLiveData: _loadCachedLiveData,
                    onSelectStation: _selectStation,
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

class TodayPage extends StatefulWidget {
  const TodayPage({
    super.key,
    this.dwdForecastService,
    this.meteoSwissForecastService,
    this.geoSphereForecastService,
    this.officialWarningService,
    this.bafuForecastLoader,
    this.environmentLoader,
    this.nowProvider,
  });

  final DwdForecastService? dwdForecastService;
  final MeteoSwissForecastService? meteoSwissForecastService;
  final GeoSphereForecastService? geoSphereForecastService;
  final OfficialWarningService? officialWarningService;
  final Future<BafuForecastData> Function()? bafuForecastLoader;
  final Future<StationEnvironmentData> Function(PegelStation)?
  environmentLoader;
  @visibleForTesting
  final DateTime Function()? nowProvider;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  static const _stations = StationSelectionService.stations;
  final _activitiesBoatsService = ActivitiesBoatsService();
  late final DwdForecastService _dwdForecastService;
  late final MeteoSwissForecastService _meteoSwissForecastService;
  late final GeoSphereForecastService _geoSphereForecastService;
  late final OfficialWarningService _officialWarningService;
  late final Future<BafuForecastData> Function() _bafuForecastLoader;
  late final Future<StationEnvironmentData> Function(PegelStation)
  _environmentLoader;
  late final DateTime Function() _nowProvider;
  PegelStation _station = PegelOnlineService.konstanz;
  StationSelectionService? _stationSelection;
  late DateTime _selectedDate;
  Future<DwdMosmixForecast>? _dwdForecast;
  Future<MeteoSwissForecast>? _meteoSwissForecast;
  Future<GeoSphereForecast>? _geoSphereForecast;
  Future<OfficialWarnings>? _officialWarnings;
  OfficialWarningSource? _warningSource;
  Future<BafuForecastData>? _bafuForecast;
  Future<StationEnvironmentData>? _bregenzEnvironment;
  List<String> _selectedActivityIds = const [];
  bool _activitiesLoaded = false;

  @override
  void initState() {
    super.initState();
    _dwdForecastService = widget.dwdForecastService ?? DwdForecastService();
    _meteoSwissForecastService =
        widget.meteoSwissForecastService ?? MeteoSwissForecastService();
    _geoSphereForecastService =
        widget.geoSphereForecastService ?? GeoSphereForecastService();
    _officialWarningService =
        widget.officialWarningService ?? OfficialWarningService();
    _bafuForecastLoader =
        widget.bafuForecastLoader ?? BafuHydroService().fetchRomanshornForecast;
    _environmentLoader =
        widget.environmentLoader ?? EnvironmentService().fetchFor;
    _nowProvider = widget.nowProvider ?? DateTime.now;
    _selectedDate = _dayOnly(DateTime.now());
    _loadSelectedActivities();
    _loadForecastForStation();
  }

  Future<void> _loadSelectedActivities() async {
    final data = await _activitiesBoatsService.load(
      validActivities: plannerActivities
          .map((activity) => activity.id)
          .toList(),
    );
    if (mounted) {
      setState(() {
        _selectedActivityIds = data.selectedActivities;
        _activitiesLoaded = true;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selection = StationSelectionScope.maybeOf(context);
    if (selection == _stationSelection) return;
    _stationSelection?.removeListener(_syncStation);
    _stationSelection = selection;
    selection?.addListener(_syncStation);
    final selectedStation = selection?.currentStation;
    if (selectedStation != null && selectedStation.uuid != _station.uuid) {
      _station = selectedStation;
      _loadForecastForStation();
    }
  }

  void _syncStation() {
    final station = _stationSelection?.currentStation;
    if (station != null && mounted && station.uuid != _station.uuid) {
      setState(() => _station = station);
      _loadForecastForStation();
    }
  }

  void _loadForecastForStation() {
    if (_station.uuid == PegelOnlineService.konstanz.uuid) {
      if (_dwdForecast == null) {
        final future = _dwdForecastService.load();
        _dwdForecast = future;
        // A station switch may remove the FutureBuilder before a network
        // failure arrives. Keep an error listener attached in that case; the
        // visible Konstanz card still receives the original future and shows
        // its own unavailable state.
        unawaited(
          future.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {},
          ),
        );
      }
      _meteoSwissForecast = null;
      _bafuForecast = null;
      _geoSphereForecast = null;
      _bregenzEnvironment = null;
      if (_warningSource != OfficialWarningSource.dwd) {
        _warningSource = OfficialWarningSource.dwd;
        _officialWarnings = _loadWarnings(
          _officialWarningService.loadDwdKonstanz(),
        );
      }
    } else if (_station.uuid == BafuHydroService.romanshorn.uuid) {
      if (_meteoSwissForecast == null) {
        final future = _meteoSwissForecastService.load();
        _meteoSwissForecast = future;
        // Keep an error listener while a station change temporarily removes
        // the FutureBuilder that owns the visible error state.
        unawaited(
          future.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {},
          ),
        );
      }
      _dwdForecast = null;
      _geoSphereForecast = null;
      _bregenzEnvironment = null;
      // MeteoSwiss has no documented, public machine-readable warning feed.
      // Keep this intentionally unavailable instead of deriving warnings from
      // its forecast values.
      _officialWarnings = null;
      _warningSource = null;
      if (_bafuForecast == null) {
        final future = _bafuForecastLoader();
        _bafuForecast = future;
        unawaited(
          future.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {},
          ),
        );
      }
    } else {
      _dwdForecast = null;
      _meteoSwissForecast = null;
      _bafuForecast = null;
      if (_warningSource != OfficialWarningSource.geoSphere) {
        _warningSource = OfficialWarningSource.geoSphere;
        _officialWarnings = _loadWarnings(
          _officialWarningService.loadGeoSphereBregenz(),
        );
      }
      if (_geoSphereForecast == null) {
        final future = _geoSphereForecastService.load();
        _geoSphereForecast = future;
        unawaited(
          future.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {},
          ),
        );
      }
      if (_bregenzEnvironment == null) {
        final future = _environmentLoader(VorarlbergHydroService.bregenz);
        _bregenzEnvironment = future;
        unawaited(
          future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      }
    }
  }

  Future<OfficialWarnings> _loadWarnings(Future<OfficialWarnings> future) {
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  Future<void> _selectStation() async {
    final station = await showModalBottomSheet<PegelStation>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _StationSelector(stations: _stations, selectedStation: _station),
    );
    if (station != null && mounted) {
      _stationSelection?.select(station);
      if (_stationSelection == null) {
        setState(() => _station = station);
        _loadForecastForStation();
      }
    }
  }

  @override
  void dispose() {
    _stationSelection?.removeListener(_syncStation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = _dayOnly(DateTime.now());
    final days = List<DateTime>.generate(
      7,
      (index) => start.add(Duration(days: index)),
    );
    final visibleActivities = !_activitiesLoaded || _selectedActivityIds.isEmpty
        ? plannerActivities
        : plannerActivities
              .where((activity) => _selectedActivityIds.contains(activity.id))
              .toList(growable: false);
    return Scaffold(
      bottomNavigationBar: _BottomNavigation(
        onLive: () => _navigateTo(context, AppDestination.live),
        onAnalysis: () => _navigateTo(context, AppDestination.analysis),
        onMap: () => _navigateTo(context, AppDestination.map),
        onMore: () => _navigateTo(context, AppDestination.more),
        todayActive: true,
      ),
      body: Stack(
        children: [
          const _PhotoBackdrop(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'HEUTE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _AnalysisStationButton(
                    station: _station,
                    onTap: _selectStation,
                  ),
                  const SizedBox(height: 16),
                  _DayPicker(
                    days: days,
                    selectedDay: _selectedDate,
                    onSelected: (day) => setState(() => _selectedDate = day),
                  ),
                  const SizedBox(height: 18),
                  _buildTodayOverview(),
                  const SizedBox(height: 20),
                  _buildActivityPlanner(days, visibleActivities),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayOverview() {
    final isKonstanz = _station.uuid == PegelOnlineService.konstanz.uuid;
    final isRomanshorn = _station.uuid == BafuHydroService.romanshorn.uuid;
    if (isKonstanz) {
      return FutureBuilder<DwdMosmixForecast>(
        future: _dwdForecast,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _TodayOverviewCard(
              date: _selectedDate,
              station: _station,
              state: _TodayForecastState.loading,
              warningFuture: _officialWarnings,
            );
          }
          final day = snapshot.hasData
              ? DwdMosmixAggregation.aggregate(snapshot.data!).firstWhere(
                  (candidate) => _dayOnly(candidate.localDate) == _selectedDate,
                  orElse: () => DwdDailyForecast(
                    localDate: _selectedDate,
                    points: const [],
                  ),
                )
              : null;
          return _ForecastOverviewWithSource(
            card: _TodayOverviewCard(
              date: _selectedDate,
              station: _station,
              forecast: day == null ? null : _TodayForecastValues.fromDwd(day),
              state: snapshot.hasData
                  ? _TodayForecastState.available
                  : _TodayForecastState.unavailable,
              warningFuture: _officialWarnings,
            ),
            source:
                'Prognose: Deutscher Wetterdienst (DWD) · MOSMIX\n'
                'Warnungen: Deutscher Wetterdienst (DWD)',
          );
        },
      );
    }
    if (isRomanshorn) {
      return FutureBuilder<MeteoSwissForecast>(
        future: _meteoSwissForecast,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _TodayOverviewCard(
              date: _selectedDate,
              station: _station,
              state: _TodayForecastState.loading,
              warningsUnavailable: true,
            );
          }
          final day = snapshot.hasData
              ? MeteoSwissForecastAggregation.aggregate(snapshot.data!)
                    .firstWhere(
                      (candidate) =>
                          _dayOnly(candidate.localDate) == _selectedDate,
                      orElse: () => MeteoSwissDailyForecast(
                        localDate: _selectedDate,
                        points: const [],
                      ),
                    )
              : null;
          return FutureBuilder<BafuForecastData>(
            future: _bafuForecast,
            builder: (context, bafuSnapshot) {
              final point = bafuSnapshot.hasData
                  ? BafuForecastDaySelection.representativePoint(
                      forecast: bafuSnapshot.data!,
                      localDate: _selectedDate,
                    )
                  : null;
              return _ForecastOverviewWithSource(
                card: _TodayOverviewCard(
                  date: _selectedDate,
                  station: _station,
                  forecast: day == null
                      ? null
                      : _TodayForecastValues.fromMeteoSwiss(day),
                  state: snapshot.hasData
                      ? _TodayForecastState.available
                      : _TodayForecastState.unavailable,
                  waterLevelForecast: point == null
                      ? null
                      : _TodayWaterLevelForecast.fromBafu(point),
                  waterLevelForecastLoading:
                      bafuSnapshot.connectionState != ConnectionState.done,
                  warningsUnavailable: true,
                ),
                source:
                    'Prognose: MeteoSwiss\n'
                    'Warnungen: nicht maschinenlesbar verfügbar',
              );
            },
          );
        },
      );
    }
    return FutureBuilder<GeoSphereForecast>(
      future: _geoSphereForecast,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _TodayOverviewCard(
            date: _selectedDate,
            station: _station,
            state: _TodayForecastState.loading,
            warningFuture: _officialWarnings,
          );
        }
        final day = snapshot.hasData
            ? GeoSphereForecastAggregation.aggregate(snapshot.data!).firstWhere(
                (candidate) => _dayOnly(candidate.localDate) == _selectedDate,
                orElse: () => GeoSphereDailyForecast(
                  localDate: _selectedDate,
                  points: const [],
                ),
              )
            : null;
        return _ForecastOverviewWithSource(
          card: _TodayOverviewCard(
            date: _selectedDate,
            station: _station,
            forecast: day == null
                ? null
                : _TodayForecastValues.fromGeoSphere(day),
            state: snapshot.hasData
                ? _TodayForecastState.available
                : _TodayForecastState.unavailable,
            warningFuture: _officialWarnings,
          ),
          source:
              'Prognose: GeoSphere Austria\n'
              'Warnungen: GeoSphere Austria · CC BY 4.0',
        );
      },
    );
  }

  Widget _buildActivityPlanner(
    List<DateTime> days,
    List<_PlannerActivity> activities,
  ) {
    if (_station.uuid == PegelOnlineService.konstanz.uuid) {
      return FutureBuilder<DwdMosmixForecast>(
        future: _dwdForecast,
        builder: (context, snapshot) => _activityPlannerContent(
          days: days,
          activities: activities,
          forecasts: snapshot.hasData
              ? DwdMosmixAggregation.aggregate(snapshot.data!)
                    .map(_TodayForecastValues.fromDwd)
                    .toList(growable: false)
              : const [],
          timeWindowPoints: snapshot.hasData
              ? snapshot.data!.points
                    .map(ActivityTimeWindowPoint.fromDwd)
                    .toList(growable: false)
              : const [],
          timeWindowLocation: ActivityTimeWindowAggregation.berlin,
        ),
      );
    }
    if (_station.uuid == BafuHydroService.romanshorn.uuid) {
      return FutureBuilder<MeteoSwissForecast>(
        future: _meteoSwissForecast,
        builder: (context, snapshot) => _activityPlannerContent(
          days: days,
          activities: activities,
          forecasts: snapshot.hasData
              ? MeteoSwissForecastAggregation.aggregate(snapshot.data!)
                    .map(_TodayForecastValues.fromMeteoSwiss)
                    .toList(growable: false)
              : const [],
          timeWindowPoints: snapshot.hasData
              ? snapshot.data!.points
                    .map(ActivityTimeWindowPoint.fromMeteoSwiss)
                    .toList(growable: false)
              : const [],
          timeWindowLocation: ActivityTimeWindowAggregation.zurich,
        ),
      );
    }
    return FutureBuilder<GeoSphereForecast>(
      future: _geoSphereForecast,
      builder: (context, snapshot) => FutureBuilder<StationEnvironmentData>(
        future: _bregenzEnvironment,
        builder: (context, environmentSnapshot) => _activityPlannerContent(
          days: days,
          activities: activities,
          forecasts: snapshot.hasData
              ? GeoSphereForecastAggregation.aggregate(snapshot.data!)
                    .map(_TodayForecastValues.fromGeoSphere)
                    .toList(growable: false)
              : const [],
          timeWindowPoints: snapshot.hasData
              ? snapshot.data!.points
                    .map(ActivityTimeWindowPoint.fromGeoSphere)
                    .toList(growable: false)
              : const [],
          timeWindowLocation: ActivityTimeWindowAggregation.vienna,
          bregenzWaterTemperatureToday:
              environmentSnapshot.hasData && !environmentSnapshot.hasError
              ? environmentSnapshot.data!.waterTemperatureC
              : null,
        ),
      ),
    );
  }

  Widget _activityPlannerContent({
    required List<DateTime> days,
    required List<_PlannerActivity> activities,
    required List<_TodayForecastValues> forecasts,
    required List<ActivityTimeWindowPoint> timeWindowPoints,
    required tz.Location timeWindowLocation,
    double? bregenzWaterTemperatureToday,
  }) {
    final forecastsByDay = <DateTime, _TodayForecastValues>{
      for (final forecast in forecasts)
        if (forecast.localDate != null) _dayOnly(forecast.localDate!): forecast,
    };
    final ratingsByDay = <DateTime, Map<String, ActivityRating>>{
      for (final day in days)
        day: {
          for (final activity in activities)
            activity.id: ActivityRatingService.rate(
              activityId: activity.id,
              data: _activityForecastData(
                forecastsByDay[day],
                waterTemperatureCelsius:
                    _station.uuid == VorarlbergHydroService.bregenz.uuid &&
                        day == _dayOnly(DateTime.now())
                    ? bregenzWaterTemperatureToday
                    : null,
              ),
            ),
        },
    };
    final nowUtc = _nowProvider().toUtc();
    final nowLocal = tz.TZDateTime.from(nowUtc, timeWindowLocation);
    final selectedDayIsToday =
        _selectedDate == DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final timeWindowForecasts = selectedDayIsToday
        ? ActivityTimeWindowAggregation.aggregate(
            points: timeWindowPoints,
            windows: ActivityTimeWindowAggregation.schedule(
              nowUtc: nowUtc,
              location: timeWindowLocation,
            ),
          )
        : const <ActivityTimeWindowForecast>[];
    final timeWindowRatings = <ActivityTimeWindow, Map<String, ActivityRating>>{
      for (final forecast in timeWindowForecasts)
        forecast.window: {
          for (final activity in activities)
            activity.id: ActivityRatingService.rate(
              activityId: activity.id,
              data: _activityTimeWindowForecastData(
                forecast,
                // A local VOWIS water measurement is a current observation,
                // not a forecast. It is therefore used only in the genuinely
                // running Bregenz interval and never propagated to later ones.
                waterTemperatureCelsius:
                    _station.uuid == VorarlbergHydroService.bregenz.uuid &&
                        forecast.window.isCurrent
                    ? bregenzWaterTemperatureToday
                    : null,
              ),
            ),
        },
    };
    return Column(
      children: [
        _TodayActivitiesSection(
          activities: activities,
          ratings: ratingsByDay[_selectedDate] ?? const {},
          timeWindowRatings: timeWindowRatings,
        ),
        const SizedBox(height: 20),
        _WeeklyPlannerSection(
          days: days,
          activities: activities,
          ratingsByDay: ratingsByDay,
        ),
      ],
    );
  }

  ActivityForecastData _activityForecastData(
    _TodayForecastValues? forecast, {
    double? waterTemperatureCelsius,
  }) => ActivityForecastData(
    temperatureMinimumCelsius: forecast?.temperatureMinimumCelsius,
    temperatureMaximumCelsius: forecast?.temperatureMaximumCelsius,
    precipitationMillimeters: forecast?.precipitationMillimeters,
    windKilometersPerHour: forecast?.representativeWindKilometersPerHour,
    gustKilometersPerHour: forecast?.maximumGustKilometersPerHour,
    waterTemperatureCelsius: waterTemperatureCelsius,
  );

  ActivityForecastData _activityTimeWindowForecastData(
    ActivityTimeWindowForecast forecast, {
    double? waterTemperatureCelsius,
  }) => ActivityForecastData(
    temperatureMinimumCelsius: forecast.temperatureMinimumCelsius,
    temperatureMaximumCelsius: forecast.temperatureMaximumCelsius,
    precipitationMillimeters: forecast.precipitationMillimeters,
    windKilometersPerHour: forecast.representativeWindKilometersPerHour,
    gustKilometersPerHour: forecast.maximumGustKilometersPerHour,
    waterTemperatureCelsius: waterTemperatureCelsius,
  );
}

DateTime _dayOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

const _weekdayShort = <String>['MO', 'DI', 'MI', 'DO', 'FR', 'SA', 'SO'];

String _shortDayLabel(DateTime day, {required bool isToday}) => isToday
    ? 'HEUTE'
    : '${_weekdayShort[day.weekday - 1]} ${day.day.toString().padLeft(2, '0')}';

String _longDayLabel(DateTime day) =>
    '${_weekdayShort[day.weekday - 1]} ${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}';

class _DayPicker extends StatelessWidget {
  const _DayPicker({
    required this.days,
    required this.selectedDay,
    required this.onSelected,
  });

  final List<DateTime> days;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final chips = List<Widget>.generate(
        days.length,
        (index) => _DayChoiceChip(
          key: ValueKey('today-day-$index'),
          label: _shortDayLabel(days[index], isToday: index == 0),
          selected: days[index] == selectedDay,
          onSelected: () => onSelected(days[index]),
        ),
      );

      // On normal phone widths all seven dates remain visible. On unusually
      // narrow layouts the same chips retain their comfortable tap target in a
      // horizontal scroller instead of shrinking their labels excessively.
      if (constraints.maxWidth >= 330) {
        return SizedBox(
          key: const ValueKey('today-day-picker'),
          height: 38,
          child: Row(
            children: [
              for (var index = 0; index < chips.length; index++) ...[
                Expanded(flex: index == 0 ? 13 : 10, child: chips[index]),
                if (index < chips.length - 1) const SizedBox(width: 3),
              ],
            ],
          ),
        );
      }

      return SizedBox(
        height: 38,
        child: ListView.separated(
          key: const ValueKey('today-day-picker'),
          scrollDirection: Axis.horizontal,
          itemCount: chips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 4),
          itemBuilder: (_, index) =>
              SizedBox(width: index == 0 ? 62 : 53, child: chips[index]),
        ),
      );
    },
  );
}

class _DayChoiceChip extends StatelessWidget {
  const _DayChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Center(child: Text(label, maxLines: 1, overflow: TextOverflow.clip)),
    selected: selected,
    onSelected: (_) => onSelected(),
    selectedColor: AppColors.blue,
    backgroundColor: Colors.white,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 3),
    labelStyle: TextStyle(
      color: selected ? Colors.white : AppColors.navy,
      fontWeight: FontWeight.w800,
      fontSize: 10,
    ),
    side: BorderSide(
      color: selected ? AppColors.blue : const Color(0xFFE1EAF5),
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
  );
}

enum _TodayForecastState { loading, neutral, unavailable, available }

class _TodayForecastValues {
  const _TodayForecastValues({
    this.localDate,
    this.temperatureMinimumCelsius,
    this.temperatureMaximumCelsius,
    this.precipitationMillimeters,
    this.representativeWindKilometersPerHour,
    this.maximumGustKilometersPerHour,
    this.windDirectionAbbreviation,
    this.weatherLabel,
  });

  factory _TodayForecastValues.fromDwd(DwdDailyForecast forecast) =>
      _TodayForecastValues(
        localDate: forecast.localDate,
        temperatureMinimumCelsius: forecast.temperatureMinimumCelsius,
        temperatureMaximumCelsius: forecast.temperatureMaximumCelsius,
        precipitationMillimeters: forecast.precipitationMillimeters,
        representativeWindKilometersPerHour:
            forecast.representativeWindKilometersPerHour,
        maximumGustKilometersPerHour: forecast.maximumGustKilometersPerHour,
        windDirectionAbbreviation: forecast.windDirectionAbbreviation,
        weatherLabel: forecast.weatherLabel,
      );

  factory _TodayForecastValues.fromMeteoSwiss(
    MeteoSwissDailyForecast forecast,
  ) => _TodayForecastValues(
    localDate: forecast.localDate,
    temperatureMinimumCelsius: forecast.temperatureMinimumCelsius,
    temperatureMaximumCelsius: forecast.temperatureMaximumCelsius,
    precipitationMillimeters: forecast.precipitationMillimeters,
    representativeWindKilometersPerHour:
        forecast.representativeWindKilometersPerHour,
    maximumGustKilometersPerHour: forecast.maximumGustKilometersPerHour,
    windDirectionAbbreviation: forecast.windDirectionAbbreviation,
    weatherLabel: forecast.weatherLabel,
  );

  factory _TodayForecastValues.fromGeoSphere(GeoSphereDailyForecast forecast) =>
      _TodayForecastValues(
        localDate: forecast.localDate,
        temperatureMinimumCelsius: forecast.temperatureMinimumCelsius,
        temperatureMaximumCelsius: forecast.temperatureMaximumCelsius,
        precipitationMillimeters: forecast.precipitationMillimeters,
        representativeWindKilometersPerHour:
            forecast.representativeWindKilometersPerHour,
        maximumGustKilometersPerHour: forecast.maximumGustKilometersPerHour,
        windDirectionAbbreviation: forecast.windDirectionAbbreviation,
        weatherLabel: forecast.weatherLabel,
      );

  final DateTime? localDate;
  final double? temperatureMinimumCelsius;
  final double? temperatureMaximumCelsius;
  final double? precipitationMillimeters;
  final double? representativeWindKilometersPerHour;
  final double? maximumGustKilometersPerHour;
  final String? windDirectionAbbreviation;
  final String? weatherLabel;
}

class _TodayWaterLevelForecast {
  const _TodayWaterLevelForecast({
    required this.levelCentimeters,
    required this.timeLabel,
  });

  factory _TodayWaterLevelForecast.fromBafu(BafuForecastPoint point) =>
      _TodayWaterLevelForecast(
        levelCentimeters: BafuForecastDaySelection.medianLevelCentimeters(
          point,
        ),
        timeLabel: BafuForecastDaySelection.localTimeLabel(point),
      );

  final double levelCentimeters;
  final String timeLabel;
}

class _ForecastOverviewWithSource extends StatelessWidget {
  const _ForecastOverviewWithSource({required this.card, required this.source});

  final Widget card;
  final String source;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      card,
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: source
              .split('\n')
              .map(
                (line) => Text(
                  line,
                  style: const TextStyle(
                    color: Color(0xFFF8FBFF),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    shadows: [
                      Shadow(
                        color: Color(0x9900163A),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ),
    ],
  );
}

class _TodayOverviewCard extends StatelessWidget {
  const _TodayOverviewCard({
    required this.date,
    required this.station,
    required this.state,
    this.forecast,
    this.waterLevelForecast,
    this.waterLevelForecastLoading = false,
    this.warningFuture,
    this.warningsUnavailable = false,
  });

  final DateTime date;
  final PegelStation station;
  final _TodayForecastState state;
  final _TodayForecastValues? forecast;
  final _TodayWaterLevelForecast? waterLevelForecast;
  final bool waterLevelForecastLoading;
  final Future<OfficialWarnings>? warningFuture;
  final bool warningsUnavailable;

  bool get _isToday => _dayOnly(date) == _dayOnly(DateTime.now());

  String get _title =>
      'TAGESÜBERSICHT · ${_longDayLabel(date)}'
      '${_isToday ? ' · AB JETZT' : ''}';

  String get _pendingLabel => switch (state) {
    _TodayForecastState.loading => 'Prognosedaten werden geladen',
    _TodayForecastState.neutral => 'Noch keine Prognosedaten verfügbar',
    _ => 'Nicht verfügbar',
  };

  tz.Location? get _warningLocation => switch (station.uuid) {
    final id when id == PegelOnlineService.konstanz.uuid =>
      OfficialWarningTimeZones.berlin,
    final id when id == VorarlbergHydroService.bregenz.uuid =>
      OfficialWarningTimeZones.vienna,
    _ => null,
  };

  List<(IconData, String, _TodayMetricContent, VoidCallback?)> _items(
    BuildContext context,
    AsyncSnapshot<OfficialWarnings> warningSnapshot,
  ) {
    final warning = _warningContent(context, warningSnapshot);
    if (state != _TodayForecastState.available || forecast == null) {
      return [
        (Icons.cloud_outlined, 'Wetter', _pendingContent, null),
        (Icons.thermostat_rounded, 'Temperatur', _pendingContent, null),
        (Icons.water_drop_outlined, 'Niederschlag', _pendingContent, null),
        (Icons.air_rounded, 'Wind', _pendingContent, null),
        (Icons.speed_rounded, 'Böen', _pendingContent, null),
        (Icons.waves_rounded, 'Pegel', _waterLevelLabel, null),
        (
          Icons.warning_amber_rounded,
          'Warnungen',
          warning.content,
          warning.onTap,
        ),
      ];
    }
    return [
      (
        Icons.cloud_outlined,
        'Wetter',
        _TodayMetricContent.fromValue(forecast!.weatherLabel),
        null,
      ),
      (
        Icons.thermostat_rounded,
        'Temperatur',
        _TodayMetricContent.fromValue(
          _temperatureRange(
            forecast!.temperatureMinimumCelsius,
            forecast!.temperatureMaximumCelsius,
          ),
        ),
        null,
      ),
      (
        Icons.water_drop_outlined,
        'Niederschlag',
        _TodayMetricContent.fromValue(
          _millimeters(forecast!.precipitationMillimeters),
          detail: _isToday && forecast!.precipitationMillimeters != null
              ? 'ab jetzt'
              : null,
        ),
        null,
      ),
      (
        Icons.air_rounded,
        'Wind',
        _TodayMetricContent.fromValue(_wind(forecast!)),
        null,
      ),
      (
        Icons.speed_rounded,
        'Böen',
        _TodayMetricContent.fromValue(
          _kilometersPerHour(forecast!.maximumGustKilometersPerHour),
        ),
        null,
      ),
      (Icons.waves_rounded, 'Pegel', _waterLevelLabel, null),
      (
        Icons.warning_amber_rounded,
        'Warnungen',
        warning.content,
        warning.onTap,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<OfficialWarnings>(
    future: warningFuture,
    builder: (context, warningSnapshot) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            style: const TextStyle(
              color: AppColors.deepBlue,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            station.name,
            style: const TextStyle(color: Color(0xFF71809A), fontSize: 13),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 10) / 2;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _items(context, warningSnapshot)
                    .map(
                      (item) => SizedBox(
                        width: width,
                        child: _TodayMetric(
                          icon: item.$1,
                          label: item.$2,
                          content: item.$3,
                          onTap: item.$4,
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    ),
  );

  _TodayMetricContent get _pendingContent => _TodayMetricContent(
    value: _pendingLabel,
    isInformational: state != _TodayForecastState.unavailable,
  );

  _TodayMetricContent get _waterLevelLabel {
    if (station.source != StationSource.bafu) {
      return const _TodayMetricContent(
        value: 'Noch keine Prognosedaten verfügbar',
        isInformational: true,
      );
    }
    final data = waterLevelForecast;
    if (data != null) {
      return _TodayMetricContent(
        value: '${data.levelCentimeters.round()} cm',
        detail: 'Prognose · ${data.timeLabel}',
      );
    }
    return waterLevelForecastLoading
        ? const _TodayMetricContent(
            value: 'Prognosedaten werden geladen',
            isInformational: true,
          )
        : const _TodayMetricContent(
            value: 'Nicht verfügbar',
            isUnavailable: true,
          );
  }

  _TodayWarningMetric _warningContent(
    BuildContext context,
    AsyncSnapshot<OfficialWarnings> snapshot,
  ) {
    if (warningsUnavailable || _warningLocation == null) {
      return const _TodayWarningMetric(
        _TodayMetricContent(
          value: 'Nicht verfügbar',
          detail: 'Keine maschinenlesbaren Amtswarnungen',
          isUnavailable: true,
        ),
      );
    }
    if (snapshot.connectionState != ConnectionState.done) {
      return const _TodayWarningMetric(
        _TodayMetricContent(
          value: 'Warnungen werden geladen',
          isInformational: true,
        ),
      );
    }
    if (!snapshot.hasData) {
      return const _TodayWarningMetric(
        _TodayMetricContent(
          value: 'Nicht verfügbar',
          detail: 'Amtliche Warnungen konnten nicht geladen werden',
          isUnavailable: true,
        ),
      );
    }
    final warnings = snapshot.data!.forLocalDay(date, _warningLocation!);
    if (warnings.isEmpty) {
      return const _TodayWarningMetric(
        _TodayMetricContent(
          value: 'Keine amtlichen Warnungen',
          isInformational: true,
        ),
      );
    }
    final first = warnings.first;
    return _TodayWarningMetric(
      _TodayMetricContent(
        value: warnings.length == 1
            ? '1 amtliche Warnung'
            : '${warnings.length} amtliche Warnungen',
        detail: '${first.nativeType} · ${first.severityLabel}',
      ),
      onTap: () => _showOfficialWarningDetails(
        context,
        warnings: warnings,
        location: _warningLocation!,
      ),
    );
  }
}

class _TodayWarningMetric {
  const _TodayWarningMetric(this.content, {this.onTap});

  final _TodayMetricContent content;
  final VoidCallback? onTap;
}

void _showOfficialWarningDetails(
  BuildContext context, {
  required List<OfficialWarning> warnings,
  required tz.Location location,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) =>
        _OfficialWarningDetailsSheet(warnings: warnings, location: location),
  );
}

class _OfficialWarningDetailsSheet extends StatelessWidget {
  const _OfficialWarningDetailsSheet({
    required this.warnings,
    required this.location,
  });

  final List<OfficialWarning> warnings;
  final tz.Location location;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .82,
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD6E2F4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: AppColors.blue),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'AMTLICHE WARNUNGEN',
                  style: TextStyle(
                    color: AppColors.deepBlue,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Schließen',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Quelle: ${warnings.first.sourceLabel}',
            style: const TextStyle(color: Color(0xFF71809A), fontSize: 12),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView.separated(
              itemCount: warnings.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _OfficialWarningDetailCard(
                warning: warnings[index],
                location: location,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _OfficialWarningDetailCard extends StatelessWidget {
  const _OfficialWarningDetailCard({
    required this.warning,
    required this.location,
  });

  final OfficialWarning warning;
  final tz.Location location;

  @override
  Widget build(BuildContext context) {
    final title = warning.headline?.trim().isNotEmpty == true
        ? warning.headline!
        : warning.nativeType;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F9FF),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            warning.nativeType,
            style: const TextStyle(
              color: AppColors.deepBlue,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.navy,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${warning.severityLabel} · gültig ${_warningTimeRange(warning, location)}',
            style: const TextStyle(color: Color(0xFF62738F), fontSize: 11),
          ),
          if (warning.description?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 9),
            Text(
              warning.description!,
              style: const TextStyle(
                color: Color(0xFF314968),
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
          if (warning.instruction?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              warning.instruction!,
              style: const TextStyle(
                color: Color(0xFF314968),
                fontSize: 12,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _warningTimeRange(OfficialWarning warning, tz.Location location) {
  String format(DateTime value) {
    final local = tz.TZDateTime.from(value, location);
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')} · '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  return '${format(warning.startsAt)}–${format(warning.endsAt)}';
}

class _TodayMetricContent {
  const _TodayMetricContent({
    required this.value,
    this.detail,
    this.isUnavailable = false,
    this.isInformational = false,
  });

  factory _TodayMetricContent.fromValue(String? value, {String? detail}) {
    final isUnavailable = value == null || value == 'Nicht verfügbar';
    return _TodayMetricContent(
      value: value ?? 'Nicht verfügbar',
      detail: detail,
      isUnavailable: isUnavailable,
    );
  }

  final String value;
  final String? detail;
  final bool isUnavailable;
  final bool isInformational;
}

String _temperatureRange(double? minimum, double? maximum) {
  if (minimum == null || maximum == null) return 'Nicht verfügbar';
  return '${minimum.round()}–${maximum.round()} °C';
}

String _millimeters(double? value) => value == null
    ? 'Nicht verfügbar'
    : '${value.toStringAsFixed(1).replaceAll('.', ',')} mm';

String _kilometersPerHour(double? value) =>
    value == null ? 'Nicht verfügbar' : '${value.round()} km/h';

String _wind(_TodayForecastValues forecast) {
  final speed = _kilometersPerHour(
    forecast.representativeWindKilometersPerHour,
  );
  if (speed == 'Nicht verfügbar') return speed;
  final direction = forecast.windDirectionAbbreviation;
  return direction == null ? speed : '$speed · $direction';
}

class _TodayMetric extends StatelessWidget {
  const _TodayMetric({
    required this.icon,
    required this.label,
    required this.content,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final _TodayMetricContent content;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F9FF),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.blue, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFF62738F),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    content.value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: content.isUnavailable || content.isInformational
                          ? const Color(0xFF71809A)
                          : AppColors.navy,
                      fontSize: content.isUnavailable || content.isInformational
                          ? 10
                          : 15,
                      height: 1.18,
                      fontWeight:
                          content.isUnavailable || content.isInformational
                          ? FontWeight.w500
                          : FontWeight.w800,
                    ),
                  ),
                  if (content.detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      content.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF71809A),
                        fontSize: 10,
                        height: 1.15,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PlannerActivity {
  const _PlannerActivity(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

const plannerActivities = <_PlannerActivity>[
  _PlannerActivity('sup_kajak', 'SUP / Kajak', Icons.kayaking_rounded),
  _PlannerActivity('segeln', 'Segeln', Icons.sailing_rounded),
  _PlannerActivity('motorboot', 'Motorboot', Icons.directions_boat_rounded),
  _PlannerActivity('kiten', 'Kiten', Icons.air_rounded),
  _PlannerActivity('angeln', 'Angeln', Icons.phishing_rounded),
  _PlannerActivity('baden', 'Baden / Schwimmen', Icons.pool_rounded),
];

class _TodayActivitiesSection extends StatelessWidget {
  const _TodayActivitiesSection({
    required this.activities,
    required this.ratings,
    required this.timeWindowRatings,
  });

  final List<_PlannerActivity> activities;
  final Map<String, ActivityRating> ratings;
  final Map<ActivityTimeWindow, Map<String, ActivityRating>> timeWindowRatings;

  @override
  Widget build(BuildContext context) => _MoreSection(
    title: 'DEIN TAG AM SEE',
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Column(
        children: [
          for (var index = 0; index < activities.length; index++) ...[
            _TodayActivityRow(
              activity: activities[index],
              rating:
                  ratings[activities[index].id] ??
                  const ActivityRating(
                    ActivityRatingLevel.unavailable,
                    'Nicht genügend Wetterdaten verfügbar',
                  ),
              timeWindowRatings: {
                for (final entry in timeWindowRatings.entries)
                  entry.key:
                      entry.value[activities[index].id] ??
                      const ActivityRating(
                        ActivityRatingLevel.unavailable,
                        'Nicht genügend Wetterdaten verfügbar',
                      ),
              },
            ),
            if (index < activities.length - 1)
              const Divider(height: 1, color: Color(0xFFEAF0F7)),
          ],
        ],
      ),
    ),
  );
}

class _TodayActivityRow extends StatelessWidget {
  const _TodayActivityRow({
    required this.activity,
    required this.rating,
    required this.timeWindowRatings,
  });

  final _PlannerActivity activity;
  final ActivityRating rating;
  final Map<ActivityTimeWindow, ActivityRating> timeWindowRatings;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('today-activity-${activity.id}'),
    height: timeWindowRatings.isEmpty ? 54 : 84,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            SizedBox(
              width: 30,
              child: Icon(activity.icon, color: AppColors.blue, size: 21),
            ),
            const SizedBox(width: 7),
            Expanded(
              flex: 4,
              child: Text(
                activity.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.navy,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    rating.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: _ratingColor(rating.level),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    rating.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Color(0xFF71809A),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (timeWindowRatings.isNotEmpty) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 37),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 5,
                runSpacing: 3,
                children: [
                  for (final entry in timeWindowRatings.entries)
                    _TimeWindowRatingChip(
                      key: ValueKey(
                        'time-window-${activity.id}-${entry.key.label}',
                      ),
                      window: entry.key,
                      rating: entry.value,
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _TimeWindowRatingChip extends StatelessWidget {
  const _TimeWindowRatingChip({
    super.key,
    required this.window,
    required this.rating,
  });

  final ActivityTimeWindow window;
  final ActivityRating rating;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(window.label),
          content: Text('${rating.label}\n${rating.reason}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Schließen'),
            ),
          ],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F7FE),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFDCE8F7)),
        ),
        child: Text(
          '${window.label} ${rating.shortLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _ratingColor(rating.level),
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
  );
}

class _WeeklyPlannerSection extends StatelessWidget {
  const _WeeklyPlannerSection({
    required this.days,
    required this.activities,
    required this.ratingsByDay,
  });

  final List<DateTime> days;
  final List<_PlannerActivity> activities;
  final Map<DateTime, Map<String, ActivityRating>> ratingsByDay;

  @override
  Widget build(BuildContext context) => _MoreSection(
    title: 'WOCHENÜBERSICHT',
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Freizeit-Eignung aus Tagesprognosen',
            style: TextStyle(color: Color(0xFF71809A), fontSize: 12),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              // Keep all seven day columns visible inside the card. The
              // activity column remains wide enough for the longest current
              // label; the remaining width is split equally across days.
              final activityWidth = math.min(
                116.0,
                math.max(100.0, constraints.maxWidth * .34),
              );
              final dayWidth =
                  (constraints.maxWidth - activityWidth) / days.length;
              return Table(
                key: const ValueKey('weekly-planner-table'),
                defaultColumnWidth: const FixedColumnWidth(52),
                columnWidths: {
                  0: FixedColumnWidth(activityWidth),
                  for (var index = 1; index <= days.length; index++)
                    index: FixedColumnWidth(dayWidth),
                },
                border: TableBorder.all(
                  color: const Color(0xFFE6EDF6),
                  borderRadius: BorderRadius.circular(10),
                ),
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: Color(0xFFF5F9FF)),
                    children: [
                      const _PlannerTableCell(''),
                      ...days.map(
                        (day) => _PlannerTableCell(
                          _shortDayLabel(day, isToday: day == days.first),
                          isDayHeader: true,
                        ),
                      ),
                    ],
                  ),
                  ...activities.map(
                    (activity) => TableRow(
                      children: [
                        KeyedSubtree(
                          key: ValueKey('weekly-activity-${activity.id}'),
                          child: _PlannerTableCell(
                            activity.label,
                            alignLeft: true,
                          ),
                        ),
                        ...days.map(
                          (day) => _PlannerRatingCell(
                            ratingsByDay[day]?[activity.id] ??
                                const ActivityRating(
                                  ActivityRatingLevel.unavailable,
                                  'Nicht genügend Wetterdaten verfügbar',
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}

Color _ratingColor(ActivityRatingLevel level) => switch (level) {
  ActivityRatingLevel.veryGood => AppColors.blue,
  ActivityRatingLevel.good => AppColors.deepBlue,
  ActivityRatingLevel.limited => const Color(0xFF59718E),
  ActivityRatingLevel.unsuitable => const Color(0xFF425B78),
  ActivityRatingLevel.unavailable => const Color(0xFF71809A),
};

class _PlannerRatingCell extends StatelessWidget {
  const _PlannerRatingCell(this.rating);

  final ActivityRating rating;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: Center(
      child: Tooltip(
        message: '${rating.label}: ${rating.reason}',
        child: Text(
          rating.shortLabel,
          maxLines: 1,
          style: TextStyle(
            color: _ratingColor(rating.level),
            fontSize: 9,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    ),
  );
}

class _PlannerTableCell extends StatelessWidget {
  const _PlannerTableCell(
    this.text, {
    this.alignLeft = false,
    this.isDayHeader = false,
  });

  final String text;
  final bool alignLeft;
  final bool isDayHeader;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: Align(
      alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isDayHeader ? 1 : 4),
        child: isDayHeader
            ? FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Color(0xFF64738D),
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : Text(
                text,
                maxLines: alignLeft ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFF64738D),
                  fontSize: alignLeft ? 10 : 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    ),
  );
}

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    required this.selectedStation,
    required this.loadLiveData,
    required this.loadEnvironmentData,
  });

  final PegelStation selectedStation;
  final Future<StationLiveData> Function(PegelStation) loadLiveData;
  final Future<StationEnvironmentData> Function(PegelStation)
  loadEnvironmentData;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  static const _stations = [
    PegelOnlineService.konstanz,
    BafuHydroService.romanshorn,
    VorarlbergHydroService.bregenz,
  ];
  late Future<List<_MapStationData>> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<List<_MapStationData>> _load() => Future.wait(
    _stations.map((station) async {
      StationLiveData? live;
      StationEnvironmentData? environment;
      try {
        live = await widget.loadLiveData(station);
      } catch (_) {}
      try {
        environment = await widget.loadEnvironmentData(station);
      } catch (_) {}
      return _MapStationData(
        station: station,
        live: live,
        environment: environment,
      );
    }),
  );

  Future<void> _openPanel(_MapStationData data) async {
    final station = await showModalBottomSheet<PegelStation>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _MapStationPanel(
        data: data,
        onOpen: () => Navigator.of(context).pop(data.station),
      ),
    );
    if (station != null && mounted) {
      _navigateTo(context, AppDestination.live, initialStation: station);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: _BottomNavigation(
      onToday: () => _navigateTo(context, AppDestination.today),
      onLive: () => _navigateTo(context, AppDestination.live),
      onAnalysis: () => _navigateTo(context, AppDestination.analysis),
      onMore: () => _navigateTo(context, AppDestination.more),
      mapActive: true,
    ),
    body: FutureBuilder<List<_MapStationData>>(
      future: _data,
      builder: (context, snapshot) {
        final stationData =
            snapshot.data ??
            _stations
                .map((station) => _MapStationData(station: station))
                .toList();
        return Stack(
          children: [
            FlutterMap(
              options: const MapOptions(
                // Framed so that all three supported stations remain visible
                // while keeping the map focused on the Bodensee.
                initialCenter: LatLng(47.58, 9.46),
                initialZoom: 9.85,
                minZoom: 7,
                maxZoom: 17,
              ),
              children: [
                TileLayer(
                  urlTemplate: MapConfiguration.developmentTileUrl,
                  userAgentPackageName: MapConfiguration.userAgentPackageName,
                ),
                MarkerLayer(
                  markers: stationData.map((data) {
                    final location = MapConfiguration.locationFor(data.station);
                    return Marker(
                      point: LatLng(location.latitude, location.longitude),
                      width: 82,
                      height: 56,
                      child: _MapMarker(
                        data: data,
                        onTap: () => _openPanel(data),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    const Text(
                      'KARTE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                        shadows: [
                          Shadow(
                            color: Color(0x55082E61),
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton.filled(
                      onPressed: () => setState(() => _data = _load()),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 112,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .88),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Text(
                    MapConfiguration.attribution,
                    style: TextStyle(fontSize: 10, color: AppColors.navy),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _MapStationData {
  const _MapStationData({required this.station, this.live, this.environment});
  final PegelStation station;
  final StationLiveData? live;
  final StationEnvironmentData? environment;
}

class _MapMarker extends StatelessWidget {
  const _MapMarker({required this.data, required this.onTap});
  final _MapStationData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = data.live == null
        ? '–'
        : '${data.live!.formatValue(data.live!.current.value)} cm';
    return InkWell(
      key: ValueKey('map-marker-${data.station.uuid}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.blue, width: 1.4),
          boxShadow: const [
            BoxShadow(
              color: Color(0x2A082E61),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: AppColors.deepBlue,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
            Text(
              data.station.name,
              style: const TextStyle(
                color: Color(0xFF64738D),
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapStationPanel extends StatelessWidget {
  const _MapStationPanel({required this.data, required this.onOpen});
  final _MapStationData data;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final live = data.live;
    final change = live?.change24Hours;
    final level = live == null
        ? '–'
        : '${live.formatValue(live.current.value)} cm';
    final changeText = change == null
        ? data.station.source == StationSource.vorarlberg
              ? '24 h nicht verfügbar'
              : '24 h nicht verfügbar'
        : '${change >= 0 ? '+' : '−'}${live!.formatChange(change.abs())} cm in 24 h';
    final temperature = data.environment?.waterTemperatureC;
    final temperatureConfig = EnvironmentService().configFor(data.station);
    final temperatureSource = temperature == null
        ? temperatureConfig.waterTemperatureUnavailableLabel
        : temperatureConfig.waterTemperatureLabel;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD7E2F0),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              data.station.name,
              style: const TextStyle(
                color: AppColors.deepBlue,
                fontSize: 21,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MapPanelValue(label: 'AKTUELLER PEGEL', value: level),
                ),
                Expanded(
                  child: _MapPanelValue(
                    label: 'VERÄNDERUNG',
                    value: changeText,
                  ),
                ),
                Expanded(
                  child: _MapPanelValue(
                    label: 'WASSERTEMP.',
                    value: temperature == null
                        ? '–'
                        : '${temperature.toStringAsFixed(1).replaceAll('.', ',')} °C',
                    detail: temperatureSource,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.waves_rounded),
                label: const Text('Station öffnen'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPanelValue extends StatelessWidget {
  const _MapPanelValue({required this.label, required this.value, this.detail});
  final String label;
  final String value;
  final String? detail;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF71809A),
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
      if (detail != null) ...[
        const SizedBox(height: 3),
        Text(
          detail!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF71809A), fontSize: 9),
        ),
      ],
      const SizedBox(height: 4),
      Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.navy,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}

class MorePage extends StatefulWidget {
  const MorePage({super.key});

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  static const _startStationPreferenceKey = 'start_station_uuid';
  static const _stations = <PegelStation>[
    PegelOnlineService.konstanz,
    BafuHydroService.romanshorn,
    VorarlbergHydroService.bregenz,
  ];

  final _preferences = SharedPreferencesAsync();
  PegelStation _startStation = PegelOnlineService.konstanz;

  @override
  void initState() {
    super.initState();
    _restoreStartStation();
  }

  Future<void> _restoreStartStation() async {
    try {
      final savedUuid = await _preferences.getString(
        _startStationPreferenceKey,
      );
      final station = _stations
          .where((station) => station.uuid == savedUuid)
          .firstOrNull;
      if (station != null && mounted) setState(() => _startStation = station);
    } catch (_) {
      // The built-in Konstanz default remains available when local storage fails.
    }
  }

  Future<void> _selectStartStation() async {
    final station = await showModalBottomSheet<PegelStation>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) =>
          _StationSelector(stations: _stations, selectedStation: _startStation),
    );
    if (station == null || !mounted || station.uuid == _startStation.uuid) {
      return;
    }
    setState(() => _startStation = station);
    try {
      await _preferences.setString(_startStationPreferenceKey, station.uuid);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Startstation konnte nicht gespeichert werden.'),
        ),
      );
    }
  }

  void _showComingSoon(String title) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text('Wird vor Veröffentlichung ergänzt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: _BottomNavigation(
      onToday: () => _navigateTo(context, AppDestination.today),
      onLive: () => _navigateTo(context, AppDestination.live),
      onAnalysis: () => _navigateTo(context, AppDestination.analysis),
      onMap: () => _navigateTo(context, AppDestination.map),
      moreActive: true,
    ),
    body: Stack(
      children: [
        const _PhotoBackdrop(),
        SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MEHR',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .5,
                  ),
                ),
                const SizedBox(height: 24),
                _MoreSection(
                  title: 'EINSTELLUNGEN',
                  child: Column(
                    children: [
                      _MoreActionRow(
                        icon: Icons.location_on_outlined,
                        title: 'Startstation',
                        detail: _startStation.name,
                        onTap: _selectStartStation,
                      ),
                      const Divider(height: 1, color: Color(0xFFE5ECF5)),
                      const _MoreInfoRow(
                        icon: Icons.refresh_rounded,
                        title: 'Aktualisierung',
                        detail: 'Live-Daten werden beim Öffnen und manuell aktualisiert.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const _MoreSection(
                  title: 'BENACHRICHTIGUNGEN',
                  child: _MoreInfoRow(
                    icon: Icons.notifications_none_rounded,
                    title: 'Pegelgrenzen und Warnungen folgen',
                    detail: 'Benachrichtigungen werden in einer späteren Version ergänzt.',
                    muted: true,
                  ),
                ),
                const SizedBox(height: 18),
                _MoreSection(
                  title: 'PERSONALISIERUNG',
                  child: _MoreActionRow(
                    icon: Icons.directions_boat_outlined,
                    title: 'Meine Aktivitäten & Boote',
                    detail: 'Aktivitäten auswählen und Boote lokal verwalten',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ActivitiesBoatsPage(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _MoreSection(
                  title: 'INFORMATIONEN',
                  child: Column(
                    children: [
                      _MoreActionRow(
                        icon: Icons.hub_outlined,
                        title: 'Datenquellen & Messstationen',
                        detail:
                            'Offizielle Quellen, Messstationen und Lizenzen',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const DataSourcesPage(),
                          ),
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFFE5ECF5)),
                      _MoreActionRow(
                        icon: Icons.info_outline_rounded,
                        title: 'Über Bodensee Pegel+',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AboutPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _MoreSection(
                  title: 'RECHTLICHES',
                  titleColor: AppColors.navy,
                  child: Column(
                    children: [
                      _MoreActionRow(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Datenschutz',
                        onTap: () => _showComingSoon('Datenschutz'),
                      ),
                      const Divider(height: 1, color: Color(0xFFE5ECF5)),
                      _MoreActionRow(
                        icon: Icons.article_outlined,
                        title: 'Impressum',
                        onTap: () => _showComingSoon('Impressum'),
                      ),
                    ],
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

class ActivitiesBoatsPage extends StatefulWidget {
  const ActivitiesBoatsPage({super.key});

  @override
  State<ActivitiesBoatsPage> createState() => _ActivitiesBoatsPageState();
}

class _ActivitiesBoatsPageState extends State<ActivitiesBoatsPage> {
  final _service = ActivitiesBoatsService();
  late Future<ActivitiesBoatsData> _data;
  List<String> _selectedActivities = const [];
  List<BoatProfile> _boats = const [];

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<ActivitiesBoatsData> _load() async {
    final data = await _service.load(
      validActivities: plannerActivities
          .map((activity) => activity.id)
          .toList(),
    );
    _selectedActivities = data.selectedActivities;
    _boats = data.boats;
    return data;
  }

  Future<void> _toggleActivity(_PlannerActivity activity, bool selected) async {
    final updated = [..._selectedActivities];
    if (selected) {
      if (!updated.contains(activity.id)) updated.add(activity.id);
    } else {
      updated.remove(activity.id);
    }
    setState(() => _selectedActivities = updated);
    await _service.saveActivities(updated);
  }

  Future<void> _addBoat() async {
    final result = await _openBoatForm();
    if (result?.boat == null || !mounted) return;
    final updated = [..._boats, result!.boat!];
    setState(() => _boats = updated);
    await _service.saveBoats(updated);
  }

  Future<_BoatFormResult?> _openBoatForm({BoatProfile? boat}) =>
      showModalBottomSheet<_BoatFormResult>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _BoatFormSheet(initialBoat: boat),
      );

  Future<void> _editBoat(BoatProfile boat) async {
    final result = await _openBoatForm(boat: boat);
    if (result == null || !mounted) return;
    final updated = switch (result.deleted) {
      true => _boats.where((candidate) => candidate.id != boat.id).toList(),
      false =>
        _boats
            .map(
              (candidate) => candidate.id == boat.id ? result.boat! : candidate,
            )
            .toList(),
    };
    setState(() => _boats = updated);
    await _service.saveBoats(updated);
  }

  @override
  Widget build(BuildContext context) => _MoreSubpage(
    title: 'Meine Aktivitäten & Boote',
    child: FutureBuilder<ActivitiesBoatsData>(
      future: _data,
      builder: (context, snapshot) {
        final loading = !snapshot.hasData;
        return Column(
          children: [
            _MoreSection(
              title: 'MEINE AKTIVITÄTEN',
              child: loading
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Column(
                      children: plannerActivities
                          .map(
                            (activity) => SwitchListTile.adaptive(
                              key: ValueKey('activity-${activity.id}'),
                              secondary: Icon(
                                activity.icon,
                                color: AppColors.blue,
                              ),
                              title: Text(
                                activity.label,
                                style: const TextStyle(
                                  color: AppColors.navy,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              value: _selectedActivities.contains(activity.id),
                              activeTrackColor: AppColors.blue,
                              onChanged: (selected) =>
                                  _toggleActivity(activity, selected),
                            ),
                          )
                          .toList(),
                    ),
            ),
            const SizedBox(height: 18),
            _MoreSection(
              title: 'MEINE BOOTE',
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (loading)
                      const Center(child: CircularProgressIndicator())
                    else if (_boats.isEmpty)
                      const Text(
                        'Noch keine Boote gespeichert.',
                        style: TextStyle(
                          color: Color(0xFF71809A),
                          fontSize: 14,
                        ),
                      )
                    else
                      ..._boats.map(
                        (boat) => _BoatProfileRow(
                          boat: boat,
                          onTap: () => _editBoat(boat),
                        ),
                      ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('add-boat-button'),
                        onPressed: loading ? null : _addBoat,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Boot hinzufügen'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _BoatProfileRow extends StatelessWidget {
  const _BoatProfileRow({required this.boat, required this.onTap});

  final BoatProfile boat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final typeLabel = boat.bootType == BoatType.sailboat
        ? 'Segelboot'
        : 'Motorboot';
    final title = boat.name ?? typeLabel;
    final details = <String>[
      typeLabel,
      if (boat.lengthMeters != null)
        '${boat.lengthMeters!.toStringAsFixed(1).replaceAll('.', ',')} m Länge',
      if (boat.draftMeters != null)
        '${boat.draftMeters!.toStringAsFixed(1).replaceAll('.', ',')} m Tiefgang',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFFF5F9FF),
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          key: ValueKey('boat-row-${boat.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(15),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Icon(
                  boat.bootType == BoatType.sailboat
                      ? Icons.sailing_rounded
                      : Icons.directions_boat_rounded,
                  color: AppColors.blue,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppColors.navy,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        details.join(' · '),
                        style: const TextStyle(
                          color: Color(0xFF71809A),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF71809A),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BoatFormResult {
  const _BoatFormResult.saved(this.boat) : deleted = false;
  const _BoatFormResult.deleted() : boat = null, deleted = true;

  final BoatProfile? boat;
  final bool deleted;
}

class _BoatFormSheet extends StatefulWidget {
  const _BoatFormSheet({this.initialBoat});

  final BoatProfile? initialBoat;

  @override
  State<_BoatFormSheet> createState() => _BoatFormSheetState();
}

class _BoatFormSheetState extends State<_BoatFormSheet> {
  BoatType _type = BoatType.motorboat;
  final _name = TextEditingController();
  final _length = TextEditingController();
  final _width = TextEditingController();
  final _draft = TextEditingController();
  final _height = TextEditingController();

  bool get _isEditing => widget.initialBoat != null;

  @override
  void initState() {
    super.initState();
    final boat = widget.initialBoat;
    if (boat == null) return;
    _type = boat.bootType;
    _name.text = boat.name ?? '';
    _length.text = _formatNumber(boat.lengthMeters);
    _width.text = _formatNumber(boat.widthMeters);
    _draft.text = _formatNumber(boat.draftMeters);
    _height.text = _formatNumber(boat.heightAboveWaterlineMeters);
  }

  @override
  void dispose() {
    _name.dispose();
    _length.dispose();
    _width.dispose();
    _draft.dispose();
    _height.dispose();
    super.dispose();
  }

  double? _number(TextEditingController controller) =>
      double.tryParse(controller.text.trim().replaceAll(',', '.'));

  String _formatNumber(double? value) => value == null
      ? ''
      : value
            .toStringAsFixed(value.truncateToDouble() == value ? 0 : 1)
            .replaceAll('.', ',');

  void _save() {
    Navigator.of(context).pop(
      _BoatFormResult.saved(
        BoatProfile(
          id:
              widget.initialBoat?.id ??
              DateTime.now().microsecondsSinceEpoch.toString(),
          name: _name.text.trim().isEmpty ? null : _name.text.trim(),
          bootType: _type,
          lengthMeters: _number(_length),
          widthMeters: _number(_width),
          draftMeters: _number(_draft),
          heightAboveWaterlineMeters: _number(_height),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Boot wirklich löschen?'),
        content: const Text('Dieses Boot wird aus der lokalen Liste entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey('boat-confirm-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(const _BoatFormResult.deleted());
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(radius: 26),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _isEditing ? 'Boot bearbeiten' : 'Boot hinzufügen',
                style: const TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<BoatType>(
                key: const ValueKey('boat-type-field'),
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Bootstyp'),
                items: const [
                  DropdownMenuItem(
                    value: BoatType.motorboat,
                    child: Text('Motorboot'),
                  ),
                  DropdownMenuItem(
                    value: BoatType.sailboat,
                    child: Text('Segelboot'),
                  ),
                ],
                onChanged: (type) =>
                    setState(() => _type = type ?? BoatType.motorboat),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('boat-name-field'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
              ),
              const SizedBox(height: 10),
              _BoatNumberField(
                key: const ValueKey('boat-length-field'),
                controller: _length,
                label: 'Länge (m)',
              ),
              _BoatNumberField(
                key: const ValueKey('boat-width-field'),
                controller: _width,
                label: 'Breite (m)',
              ),
              _BoatNumberField(
                key: const ValueKey('boat-draft-field'),
                controller: _draft,
                label: 'Tiefgang (m)',
              ),
              _BoatNumberField(
                key: const ValueKey('boat-height-field'),
                controller: _height,
                label: 'Höhe über Wasserlinie (m)',
                helperText: 'Höchster Punkt des Bootes über der Wasseroberfläche, z. B. Verdeck, Antenne oder Mast.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('boat-add-submit'),
                  onPressed: _save,
                  child: const Text('Boot speichern'),
                ),
              ),
              if (_isEditing) ...[
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    key: const ValueKey('boat-delete-button'),
                    onPressed: _delete,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF71809A),
                    ),
                    child: const Text('Boot löschen'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _BoatNumberField extends StatelessWidget {
  const _BoatNumberField({
    super.key,
    required this.controller,
    required this.label,
    this.helperText,
  });

  final TextEditingController controller;
  final String label;
  final String? helperText;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, helperText: helperText),
    ),
  );
}

class DataSourcesPage extends StatelessWidget {
  const DataSourcesPage({super.key});

  Future<void> _openLink(BuildContext context, String url) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link konnte nicht geöffnet werden.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => _MoreSubpage(
    title: 'Datenquellen & Messstationen',
    child: _MoreSection(
      title: 'OFFIZIELLE QUELLEN',
      child: Column(
        children: _moreSources
            .map(
              (source) => _SourceRow(
                source: source,
                onOpen: () => _openLink(context, source.url),
              ),
            )
            .toList(),
      ),
    ),
  );
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late Future<String?> _version;

  @override
  void initState() {
    super.initState();
    _version = _loadVersion();
  }

  Future<String?> _loadVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return '${packageInfo.version} (${packageInfo.buildNumber})';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _MoreSubpage(
      title: 'Über Bodensee Pegel+',
      child: _MoreSection(
        title: 'BODENSEE PEGEL+',
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bodensee Pegel+ zeigt aktuelle und historische Wasserstände des Bodensees sowie ausgewählte Umwelt- und Prognosedaten aus offiziellen Quellen. Analysen und saisonale Vergleiche helfen dabei, die aktuelle Pegelsituation besser einzuordnen.',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 15,
                  height: 1.42,
                ),
              ),
              const SizedBox(height: 14),
              FutureBuilder<String?>(
                future: _version,
                builder: (context, snapshot) => Text(
                  snapshot.hasData && snapshot.data != null
                      ? 'Version ${snapshot.data}'
                      : 'Version nicht verfügbar',
                  style: const TextStyle(
                    color: AppColors.blue,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 15),
              const Text(
                'Die dargestellten Daten stammen aus offiziellen Quellen, können jedoch unvollständig, verzögert oder fehlerhaft sein. Bodensee Pegel+ ist kein amtlicher Warn- oder Informationsdienst. Die Angaben dürfen nicht als alleinige Grundlage für sicherheitskritische Entscheidungen verwendet werden.',
                style: TextStyle(
                  color: Color(0xFF64738D),
                  fontSize: 13,
                  height: 1.42,
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFE5ECF5)),
              InkWell(
                key: const ValueKey('about-data-sources-link'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DataSourcesPage(),
                  ),
                ),
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 11),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Datenquellen & Messstationen',
                          style: TextStyle(
                            color: AppColors.blue,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: AppColors.blue),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreSubpage extends StatelessWidget {
  const _MoreSubpage({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const _PhotoBackdrop(),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 20, 18),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Zurück',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 32),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MoreSection extends StatelessWidget {
  const _MoreSection({
    required this.title,
    required this.child,
    this.titleColor = Colors.white,
  });

  final String title;
  final Widget child;
  final Color titleColor;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          title,
          style: TextStyle(
            color: titleColor,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: .5,
          ),
        ),
      ),
      Container(
        decoration: _cardDecoration(radius: 24),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          child: child,
        ),
      ),
    ],
  );
}

class _MoreActionRow extends StatelessWidget {
  const _MoreActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(24),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: Row(
        children: [
          _MoreIcon(icon: icon),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.navy,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail!,
                    style: const TextStyle(
                      color: Color(0xFF71809A),
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.blue),
        ],
      ),
    ),
  );
}

class _MoreInfoRow extends StatelessWidget {
  const _MoreInfoRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.muted = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool muted;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MoreIcon(icon: icon, muted: muted),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: muted ? const Color(0xFF71809A) : AppColors.navy,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                style: const TextStyle(
                  color: Color(0xFF71809A),
                  fontSize: 13,
                  height: 1.32,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MoreIcon extends StatelessWidget {
  const _MoreIcon({required this.icon, this.muted = false});

  final IconData icon;
  final bool muted;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: (muted ? const Color(0xFF8B98AC) : AppColors.blue).withValues(
        alpha: .10,
      ),
      shape: BoxShape.circle,
    ),
    child: Icon(icon, color: muted ? const Color(0xFF8B98AC) : AppColors.blue),
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.onOpen});

  final _MoreSource source;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 15, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                source.name,
                style: const TextStyle(
                  color: AppColors.navy,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Offizielle Quelle öffnen',
              onPressed: onOpen,
              icon: const Icon(
                Icons.open_in_new_rounded,
                color: AppColors.blue,
              ),
            ),
          ],
        ),
        Text(
          source.data,
          style: const TextStyle(
            color: Color(0xFF475A78),
            fontSize: 13,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          source.stations,
          style: const TextStyle(color: Color(0xFF71809A), fontSize: 12),
        ),
        const SizedBox(height: 5),
        Text(
          source.licence,
          style: const TextStyle(
            color: AppColors.blue,
            fontSize: 11,
            height: 1.28,
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 14),
          child: Divider(height: 1, color: Color(0xFFE5ECF5)),
        ),
      ],
    ),
  );
}

class _MoreSource {
  const _MoreSource({
    required this.name,
    required this.data,
    required this.stations,
    required this.licence,
    required this.url,
  });

  final String name;
  final String data;
  final String stations;
  final String licence;
  final String url;
}

const _moreSources = <_MoreSource>[
  _MoreSource(
    name: 'PEGELONLINE / WSV',
    data: 'Pegelstand, Messzeitpunkt und historische Wasserstände',
    stations: 'Konstanz',
    licence: 'DL-DE-Zero-2.0 · Ungeprüfte Rohdaten',
    url: 'https://www.pegelonline.wsv.de/webservice/ueberblick',
  ),
  _MoreSource(
    name: 'BAFU',
    data: 'Pegelstand, Historie, saisonale Referenz und Prognose',
    stations: 'Romanshorn',
    licence: 'Quelle: Abteilung Hydrologie, Bundesamt für Umwelt BAFU',
    url: 'https://www.hydrodaten.admin.ch/de/fragen',
  ),
  _MoreSource(
    name: 'Wasserwirtschaft Vorarlberg / VOWIS',
    data: 'Pegelstand sowie Umweltmesswerte',
    stations: 'Bregenz',
    licence: 'Quelle: VOWIS · Lizenz vor Veröffentlichung prüfen',
    url: 'https://vowis.vorarlberg.at/',
  ),
  _MoreSource(
    name: 'Deutscher Wetterdienst',
    data: 'Wind und Lufttemperatur',
    stations: 'Konstanz · Station 02712',
    licence: 'CC BY 4.0 · Quelle: Deutscher Wetterdienst (DWD)',
    url: 'https://opendata.dwd.de/climate_environment/CDC/',
  ),
  _MoreSource(
    name: 'MeteoSwiss',
    data: 'Wind und Lufttemperatur',
    stations: 'Romanshorn · Station Güttingen',
    licence: 'CC BY 4.0 · Quelle: MeteoSwiss',
    url: 'https://www.meteoswiss.admin.ch/services-and-publications/service/open-data.html',
  ),
  _MoreSource(
    name: 'OpenStreetMap',
    data: 'Kartendaten und Kartenbasis',
    stations: 'Kartenansicht',
    licence: '© OpenStreetMap contributors · ODbL',
    url: 'https://www.openstreetmap.org/copyright',
  ),
];

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({super.key});

  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage> {
  final _analysisService = AnalysisService();
  final _stations = const [
    PegelOnlineService.konstanz,
    BafuHydroService.romanshorn,
    VorarlbergHydroService.bregenz,
  ];
  PegelStation _station = PegelOnlineService.konstanz;
  late AnalysisPeriod _period;
  late Future<AnalysisSeries> _series;
  StationSelectionService? _stationSelection;

  @override
  void initState() {
    super.initState();
    _period = _analysisService.periodsFor(_station).first;
    _series = _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selection = StationSelectionScope.maybeOf(context);
    if (selection == _stationSelection) return;
    _stationSelection?.removeListener(_syncSharedStation);
    _stationSelection = selection;
    selection?.addListener(_syncSharedStation);
    _applyStation(selection?.currentStation ?? _station);
  }

  void _syncSharedStation() {
    final selection = _stationSelection;
    if (selection != null) _applyStation(selection.currentStation);
  }

  void _applyStation(PegelStation station) {
    if (station.uuid == _station.uuid) return;
    final period = _analysisService.resolvePeriodForStation(station, _period);
    setState(() {
      _station = station;
      _period = period;
      _series = _load();
    });
  }

  Future<AnalysisSeries> _load() {
    final request = _analysisService.fetch(_station, _period);
    // A station switch may replace this future before its request completes.
    // Observe its error regardless, while the active FutureBuilder continues
    // to render a clear unavailable-data state for the current request.
    request.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return request;
  }

  void _selectPeriod(AnalysisPeriod period) {
    if (period == _period) return;
    setState(() {
      _period = period;
      _series = _load();
    });
  }

  Future<void> _selectStation() async {
    final station = await showModalBottomSheet<PegelStation>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _StationSelector(stations: _stations, selectedStation: _station),
    );
    if (station == null || !mounted || station.uuid == _station.uuid) return;
    final selection = _stationSelection;
    if (selection != null) {
      selection.select(station);
    } else {
      _applyStation(station);
    }
  }

  @override
  void dispose() {
    _stationSelection?.removeListener(_syncSharedStation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final periods = _analysisService.periodsFor(_station);
    return Scaffold(
      bottomNavigationBar: _BottomNavigation(
        onToday: () => _navigateTo(context, AppDestination.today),
        onLive: () => _navigateTo(context, AppDestination.live),
        onMap: () => _navigateTo(context, AppDestination.map),
        onMore: () => _navigateTo(context, AppDestination.more),
        analysisActive: true,
      ),
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
                  const SizedBox(height: 42),
                  const Text(
                    'ANALYSE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _AnalysisStationButton(
                    station: _station,
                    onTap: _selectStation,
                  ),
                  const SizedBox(height: 24),
                  _PeriodTabs(
                    periods: periods,
                    selected: _period,
                    onSelected: _selectPeriod,
                  ),
                  const SizedBox(height: 18),
                  FutureBuilder<AnalysisSeries>(
                    future: _series,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const _UnavailableInfoCard(
                          icon: Icons.query_stats_rounded,
                          title: 'ANALYSEDATEN',
                          message: 'Daten aktuell nicht verfügbar.',
                        );
                      }
                      if (!snapshot.hasData) {
                        return const _AnalysisLoadingCard();
                      }
                      return _AnalysisContent(
                        station: _station,
                        series: snapshot.data!,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalysisStationButton extends StatelessWidget {
  const _AnalysisStationButton({required this.station, required this.onTap});

  final PegelStation station;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(22),
    child: InkWell(
      key: const ValueKey('analysis-station-selector'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(
          children: [
            const Icon(Icons.location_on_outlined, color: AppColors.deepBlue),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                station.name,
                style: const TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: AppColors.deepBlue,
            ),
          ],
        ),
      ),
    ),
  );
}

class _PeriodTabs extends StatelessWidget {
  const _PeriodTabs({
    required this.periods,
    required this.selected,
    required this.onSelected,
  });

  final List<AnalysisPeriod> periods;
  final AnalysisPeriod selected;
  final ValueChanged<AnalysisPeriod> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: periods
          .map(
            (period) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(period.label),
                selected: period == selected,
                onSelected: (_) => onSelected(period),
                showCheckmark: false,
                selectedColor: AppColors.blue,
                backgroundColor: Colors.white,
                labelStyle: TextStyle(
                  color: period == selected ? Colors.white : AppColors.deepBlue,
                  fontWeight: FontWeight.w800,
                ),
                side: BorderSide.none,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          )
          .toList(),
    ),
  );
}

class _AnalysisLoadingCard extends StatelessWidget {
  const _AnalysisLoadingCard();

  @override
  Widget build(BuildContext context) => Container(
    height: 290,
    decoration: _cardDecoration(),
    alignment: Alignment.center,
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: AppColors.blue),
        SizedBox(height: 14),
        Text(
          'Analysedaten werden geladen …',
          style: TextStyle(color: Color(0xFF64738D)),
        ),
      ],
    ),
  );
}

class _AnalysisContent extends StatelessWidget {
  const _AnalysisContent({required this.station, required this.series});

  final PegelStation station;
  final AnalysisSeries series;

  @override
  Widget build(BuildContext context) {
    final readings = series.readings;
    final annual = series.annualComparison;
    final minimum = readings
        .map((reading) => reading.valueCm)
        .reduce((a, b) => a < b ? a : b);
    final maximum = readings
        .map((reading) => reading.valueCm)
        .reduce((a, b) => a > b ? a : b);
    final change = readings.last.valueCm - readings.first.valueCm;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 15),
          decoration: _cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PEGELVERLAUF · ${series.period.label.toUpperCase()}',
                style: const TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 15),
              if (annual != null)
                _AnnualAnalysisChart(comparison: annual)
              else
                SizedBox(
                  height: 285,
                  child: CustomPaint(
                    painter: _AnalysisChartPainter(readings, series.period),
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        annual == null
            ? _AnalysisMetrics(
                current: readings.last.valueCm,
                minimum: minimum,
                maximum: maximum,
                change: change,
                period: series.period,
              )
            : _AnnualAnalysisMetrics(
                summary: AnnualAnalysisSummary.from(annual),
                referenceLabel: annual.referenceLabel,
              ),
        const SizedBox(height: 18),
        annual == null
            ? _ReferenceCard(
                station: station,
                seasonalReference: series.seasonalReference,
              )
            : _AnnualLegend(comparison: annual),
      ],
    );
  }
}

class _AnnualAnalysisMetrics extends StatelessWidget {
  const _AnnualAnalysisMetrics({
    required this.summary,
    required this.referenceLabel,
  });

  final AnnualAnalysisSummary summary;
  final String referenceLabel;

  @override
  Widget build(BuildContext context) {
    final difference = summary.referenceDifferenceCm;
    final shortReference = referenceLabel.contains('Median')
        ? 'ZUM MEDIAN'
        : 'ZUM MITTEL';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      decoration: _cardDecoration(radius: 22),
      child: Row(
        children: [
          _Metric(label: 'AKTUELL', value: _cm(summary.currentCm)),
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: Color(0xFFE1E9F4),
          ),
          _Metric(label: 'MINIMUM', value: _cm(summary.minimumCm)),
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: Color(0xFFE1E9F4),
          ),
          _Metric(label: 'MAXIMUM', value: _cm(summary.maximumCm)),
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: Color(0xFFE1E9F4),
          ),
          _Metric(
            label: shortReference,
            value: difference == null
                ? '–'
                : '${difference >= 0 ? '+' : ''}${_cm(difference)}',
            accent: AppColors.navy,
          ),
        ],
      ),
    );
  }

  String _cm(double value) {
    final digits = value == value.roundToDouble() ? 0 : 1;
    return '${value.toStringAsFixed(digits).replaceAll('.', ',')} cm';
  }
}

class _AnnualLegend extends StatelessWidget {
  const _AnnualLegend({required this.comparison});

  final AnnualComparison comparison;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: _cardDecoration(radius: 22),
    child: Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        const _LegendItem(color: AppColors.blue, label: 'Aktuelles Jahr'),
        if (comparison.previous != null)
          const _LegendItem(color: Color(0xB39AA8BC), label: 'Vorjahr'),
        _LegendItem(
          color: const Color(0xFF199469),
          label: comparison.referenceLabel,
        ),
        const _LegendItem(
          color: Color(0x16278BE6),
          label: 'Historischer Bereich',
          filled: true,
        ),
      ],
    ),
  );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.label,
    this.filled = false,
  });

  final Color color;
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 18,
        height: 8,
        decoration: BoxDecoration(
          color: filled ? color : null,
          borderRadius: BorderRadius.circular(4),
          border: filled
              ? null
              : Border(top: BorderSide(color: color, width: 2)),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF64738D),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _AnalysisMetrics extends StatelessWidget {
  const _AnalysisMetrics({
    required this.current,
    required this.minimum,
    required this.maximum,
    required this.change,
    required this.period,
  });

  final double current;
  final double minimum;
  final double maximum;
  final double change;
  final AnalysisPeriod period;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
    decoration: _cardDecoration(radius: 22),
    child: Row(
      children: [
        _Metric(label: 'AKTUELL', value: _cm(current)),
        const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE1E9F4)),
        _Metric(label: 'MINIMUM', value: _cm(minimum)),
        const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE1E9F4)),
        _Metric(label: 'MAXIMUM', value: _cm(maximum)),
        const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE1E9F4)),
        _Metric(
          label: 'ÄNDERUNG',
          value: '${change >= 0 ? '+' : ''}${_cm(change)}',
          accent: change < 0 ? AppColors.red : AppColors.green,
        ),
      ],
    ),
  );

  String _cm(double value) {
    final digits = value == value.roundToDouble() ? 0 : 1;
    return '${value.toStringAsFixed(digits).replaceAll('.', ',')} cm';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.accent = AppColors.navy,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF71809A),
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ReferenceCard extends StatelessWidget {
  const _ReferenceCard({required this.station, this.seasonalReference});

  final PegelStation station;
  final SeasonalReference? seasonalReference;

  @override
  Widget build(BuildContext context) {
    final isRomanshorn = station.source == StationSource.bafu;
    final reference = seasonalReference;
    final text = isRomanshorn
        ? _seasonalText(reference)
        : switch (station.source) {
            StationSource.pegelOnline =>
              'Langzeitreferenz · MW 341 cm · MNW 262 cm',
            StationSource.bafu => '',
            StationSource.vorarlberg =>
              'Langzeitreferenz 1864–2024 · Mittel · Min · Max',
          };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(radius: 22),
      child: Row(
        children: [
          const Icon(Icons.insights_rounded, color: AppColors.blue),
          const SizedBox(width: 12),
          Expanded(
            child: isRomanshorn && reference != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: const TextStyle(
                          color: AppColors.deepBlue,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Saisonaler Median: ${_formatCm(reference.medianCm)} cm',
                        style: const TextStyle(
                          color: Color(0xFF71809A),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : Text(
                    text,
                    style: const TextStyle(
                      color: AppColors.deepBlue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _seasonalText(SeasonalReference? reference) {
    if (reference == null) {
      return 'Saisonale BAFU-Referenz aktuell nicht verfügbar.';
    }
    if (reference.isWithinNormalRange) {
      return 'Aktuell im normalen saisonalen Bereich';
    }
    final difference = reference.differenceCm;
    final direction = difference < 0 ? 'unter' : 'über';
    return 'Aktuell ${_formatCm(difference.abs())} cm $direction dem saisonalen Median';
  }

  String _formatCm(double value) {
    final digits = value == value.roundToDouble() ? 0 : 1;
    return value.toStringAsFixed(digits).replaceAll('.', ',');
  }
}

class _AnnualAnalysisChart extends StatefulWidget {
  const _AnnualAnalysisChart({required this.comparison});

  final AnnualComparison comparison;

  @override
  State<_AnnualAnalysisChart> createState() => _AnnualAnalysisChartState();
}

class _AnnualAnalysisChartState extends State<_AnnualAnalysisChart> {
  AnalysisReading? _selected;

  @override
  void didUpdateWidget(covariant _AnnualAnalysisChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A selected day belongs to one specific station/year series. Clear the
    // overlay as soon as the chart receives another data set.
    if (!identical(oldWidget.comparison, widget.comparison)) {
      _selected = null;
    }
  }

  void _selectAt(Offset position, double width) {
    final chartWidth = math.max(1.0, width - 50);
    final fraction = ((position.dx - 42) / chartWidth).clamp(0.0, 1.0);
    final year = widget.comparison.current.first.timestamp.year;
    final start = DateTime(year);
    final end = DateTime(year + 1).subtract(const Duration(days: 1));
    final target = start.add(
      Duration(
        milliseconds: (end.difference(start).inMilliseconds * fraction).round(),
      ),
    );
    final selected = widget.comparison.current.reduce(
      (closest, candidate) =>
          candidate.timestamp.difference(target).inMilliseconds.abs() <
              closest.timestamp.difference(target).inMilliseconds.abs()
          ? candidate
          : closest,
    );
    setState(() => _selected = selected);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 285,
    child: LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) =>
            _selectAt(details.localPosition, constraints.maxWidth),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _AnnualChartPainter(widget.comparison),
              ),
            ),
            if (_selected != null)
              Positioned(
                top: 6,
                right: 2,
                child: _AnnualTooltip(
                  comparison: widget.comparison,
                  selected: _selected!,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _AnnualTooltip extends StatelessWidget {
  const _AnnualTooltip({required this.comparison, required this.selected});

  final AnnualComparison comparison;
  final AnalysisReading selected;

  @override
  Widget build(BuildContext context) {
    final previous = _valueOnDay(comparison.previous);
    final reference = _valueOnDay(comparison.reference);
    return Container(
      constraints: const BoxConstraints(maxWidth: 170),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1600275D),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: AppColors.deepBlue,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_date(selected.timestamp)),
            const SizedBox(height: 3),
            Text('Aktuell: ${_cm(selected.valueCm)}'),
            if (previous != null) Text('Vorjahr: ${_cm(previous)}'),
            if (reference != null)
              Text('${comparison.referenceLabel}: ${_cm(reference)}'),
          ],
        ),
      ),
    );
  }

  double? _valueOnDay(List<AnalysisReading>? readings) {
    if (readings == null) return null;
    for (final reading in readings) {
      if (reading.timestamp.month == selected.timestamp.month &&
          reading.timestamp.day == selected.timestamp.day) {
        return reading.valueCm;
      }
    }
    return null;
  }

  String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';

  String _cm(double value) {
    final digits = value == value.roundToDouble() ? 0 : 1;
    return '${value.toStringAsFixed(digits).replaceAll('.', ',')} cm';
  }
}

class _AnnualChartPainter extends CustomPainter {
  const _AnnualChartPainter(this.comparison);

  final AnnualComparison comparison;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 42.0;
    const right = 8.0;
    const top = 14.0;
    const bottom = 36.0;
    final chart = Rect.fromLTWH(
      left,
      top,
      size.width - left - right,
      size.height - top - bottom,
    );
    final year = comparison.current.first.timestamp.year;
    final start = DateTime(year);
    final end = DateTime(year + 1).subtract(const Duration(days: 1));
    final allValues = <double>[
      ...comparison.current.map((point) => point.valueCm),
      ...?comparison.previous?.map((point) => point.valueCm),
      ...?comparison.reference?.map((point) => point.valueCm),
      ...?comparison.band?.expand((point) => [point.lowerCm, point.upperCm]),
    ];
    final rawMin = allValues.reduce(math.min);
    final rawMax = allValues.reduce(math.max);
    final padding = math.max(.5, (rawMax - rawMin) * .12).toDouble();
    // Der sichtbare Bereich umfasst bewusst alle Reihen, einschließlich des
    // historischen Bands. Die Schrittweite wird auf etwa fünf Rasterabstände
    // abgestimmt, damit die Achse Daten nicht künstlich bis 0 aufspannt.
    final step = _niceStep((rawMax - rawMin + padding * 2) / 5);
    final minY = ((rawMin - padding) / step).floor() * step;
    final maxY = ((rawMax + padding) / step).ceil() * step;
    final grid = Paint()
      ..color = const Color(0xFFE8EFF8)
      ..strokeWidth = 1;
    final labelPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    for (var value = minY; value <= maxY + step / 100; value += step) {
      final y = chart.bottom - chart.height * (value - minY) / (maxY - minY);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      labelPainter.text = TextSpan(
        text: _axis(value),
        style: const TextStyle(color: Color(0xFF71809A), fontSize: 10),
      );
      labelPainter.layout();
      labelPainter.paint(
        canvas,
        Offset(
          chart.left - labelPainter.width - 7,
          y - labelPainter.height / 2,
        ),
      );
    }

    Offset position(DateTime timestamp, double value) {
      final fraction =
          timestamp.difference(start).inMilliseconds /
          math.max(1, end.difference(start).inMilliseconds);
      return Offset(
        chart.left + chart.width * fraction,
        chart.bottom - chart.height * (value - minY) / (maxY - minY),
      );
    }

    final band = comparison.band;
    if (band != null && band.length > 1) {
      final path = Path();
      for (var index = 0; index < band.length; index++) {
        final point = position(band[index].timestamp, band[index].upperCm);
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      for (var index = band.length - 1; index >= 0; index--) {
        final point = position(band[index].timestamp, band[index].lowerCm);
        path.lineTo(point.dx, point.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = const Color(0x12278BE6));
    }

    void drawSeries(
      List<AnalysisReading>? readings,
      Color color,
      double width,
    ) {
      if (readings == null || readings.length < 2) return;
      final path = Path();
      for (var index = 0; index < readings.length; index++) {
        final point = position(
          readings[index].timestamp,
          readings[index].valueCm,
        );
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    drawSeries(comparison.previous, const Color(0xB39AA8BC), 1.1);
    drawSeries(comparison.reference, const Color(0xFF199469), 1.7);
    drawSeries(comparison.current, AppColors.blue, 3);

    final monthPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var month = 1; month <= 12; month++) {
      final timestamp = DateTime(year, month);
      final fraction =
          timestamp.difference(start).inMilliseconds /
          math.max(1, end.difference(start).inMilliseconds);
      final x = chart.left + chart.width * fraction;
      monthPainter.text = TextSpan(
        text: _month(month),
        style: const TextStyle(color: Color(0xFF71809A), fontSize: 8),
      );
      monthPainter.layout();
      monthPainter.paint(
        canvas,
        Offset(
          (x - monthPainter.width / 2)
              .clamp(chart.left, chart.right - monthPainter.width)
              .toDouble(),
          chart.bottom + 9,
        ),
      );
    }
  }

  String _axis(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceAll('.', ',');

  double _niceStep(double value) {
    final exponent = math
        .pow(10, (math.log(value) / math.ln10).floor())
        .toDouble();
    final candidates = <double>[
      exponent / 10,
      exponent / 5,
      exponent / 4,
      exponent / 2,
      exponent,
      exponent * 2,
      exponent * 2.5,
      exponent * 5,
      exponent * 10,
    ];
    return candidates.reduce(
      (best, candidate) =>
          (candidate - value).abs() < (best - value).abs() ? candidate : best,
    );
  }

  String _month(int month) => const [
    'Jan',
    'Feb',
    'Mär',
    'Apr',
    'Mai',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Okt',
    'Nov',
    'Dez',
  ][month - 1];

  @override
  bool shouldRepaint(covariant _AnnualChartPainter oldDelegate) =>
      oldDelegate.comparison != comparison;
}

class _AnalysisChartPainter extends CustomPainter {
  const _AnalysisChartPainter(this.readings, this.period);

  final List<AnalysisReading> readings;
  final AnalysisPeriod period;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 42.0;
    const right = 8.0;
    const top = 14.0;
    const bottom = 36.0;
    final chart = Rect.fromLTWH(
      left,
      top,
      size.width - left - right,
      size.height - top - bottom,
    );
    final values = readings.map((reading) => reading.valueCm).toList();
    final rawMin = values.reduce((a, b) => a < b ? a : b);
    final rawMax = values.reduce((a, b) => a > b ? a : b);
    final padding = math.max(.5, (rawMax - rawMin) * .15).toDouble();
    final step = _niceStep((rawMax - rawMin + padding * 2) / 4);
    final minY = ((rawMin - padding) / step).floor() * step;
    final maxY = ((rawMax + padding) / step).ceil() * step;
    final start = readings.first.timestamp;
    final end = readings.last.timestamp;
    final duration = math
        .max(1, end.difference(start).inMilliseconds)
        .toDouble();
    final grid = Paint()
      ..color = const Color(0xFFE8EFF8)
      ..strokeWidth = 1;
    final yLabelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var value = minY; value <= maxY + step / 100; value += step) {
      final y = chart.bottom - chart.height * (value - minY) / (maxY - minY);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      yLabelPainter.text = TextSpan(
        text: _formatAxisValue(value),
        style: const TextStyle(color: Color(0xFF71809A), fontSize: 10),
      );
      yLabelPainter.layout();
      yLabelPainter.paint(
        canvas,
        Offset(
          chart.left - yLabelPainter.width - 7,
          y - yLabelPainter.height / 2,
        ),
      );
    }

    final plottedReadings = AnalysisDisplaySmoother.smooth(readings, period);
    final displayPoints = <Offset>[];
    for (final reading in plottedReadings) {
      final x =
          chart.left +
          chart.width *
              reading.timestamp.difference(start).inMilliseconds /
              duration;
      final y =
          chart.bottom -
          chart.height * (reading.valueCm - minY) / (maxY - minY);
      displayPoints.add(Offset(x, y));
    }
    final path = _boundedSmoothPath(displayPoints);
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final xTicks = _xTicks(start, end);
    final xLabelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (final tick in xTicks) {
      xLabelPainter.text = TextSpan(
        text: tick.label,
        style: const TextStyle(color: Color(0xFF71809A), fontSize: 10),
      );
      xLabelPainter.layout();
      final x = chart.left + chart.width * tick.fraction;
      xLabelPainter.paint(
        canvas,
        Offset(
          (x - xLabelPainter.width / 2)
              .clamp(chart.left, chart.right - xLabelPainter.width)
              .toDouble(),
          chart.bottom + 9,
        ),
      );
    }
  }

  Path _boundedSmoothPath(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    if (points.length == 1) return path;
    if (points.length == 2) {
      path.lineTo(points.last.dx, points.last.dy);
      return path;
    }
    // Quadratic segments end at consecutive midpoints. Their control points
    // and endpoints remain within the measured display range, unlike a free
    // spline they cannot create visible overshoot above or below the data.
    for (var index = 1; index < points.length - 1; index++) {
      final current = points[index];
      final next = points[index + 1];
      final midpoint = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(current.dx, current.dy, midpoint.dx, midpoint.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  List<_ChartTick> _xTicks(DateTime start, DateTime end) {
    final count = period == AnalysisPeriod.hours24 ? 5 : 4;
    return List.generate(count, (index) {
      final fraction = index / (count - 1);
      final time = start
          .add(
            Duration(
              milliseconds: (end.difference(start).inMilliseconds * fraction)
                  .round(),
            ),
          )
          .toLocal();
      return _ChartTick(fraction, _formatTime(time));
    });
  }

  String _formatTime(DateTime time) => switch (period) {
    AnalysisPeriod.hours24 =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    AnalysisPeriod.days7 =>
      '${_weekday(time.weekday)} ${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}',
    AnalysisPeriod.days30 =>
      '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}',
    AnalysisPeriod.year1 => _month(time.month),
  };

  String _formatAxisValue(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceAll('.', ',');

  double _niceStep(double value) {
    final exponent = math
        .pow(10, (math.log(value) / math.ln10).floor())
        .toDouble();
    final fraction = value / exponent;
    final niceFraction = fraction <= 1
        ? 1.0
        : fraction <= 2
        ? 2.0
        : fraction <= 5
        ? 5.0
        : 10.0;
    return niceFraction * exponent;
  }

  String _weekday(int weekday) =>
      const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'][weekday - 1];

  String _month(int month) => const [
    'Jan',
    'Feb',
    'Mär',
    'Apr',
    'Mai',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Okt',
    'Nov',
    'Dez',
  ][month - 1];

  @override
  bool shouldRepaint(covariant _AnalysisChartPainter oldDelegate) =>
      oldDelegate.readings != readings || oldDelegate.period != period;
}

class _ChartTick {
  const _ChartTick(this.fraction, this.label);

  final double fraction;
  final String label;
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
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: Color(0xFF127FC9)),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xD90052AE),
                  Color(0xA3108BD0),
                  Color(0x1AFFFFFF),
                ],
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
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Icon(Icons.waves_rounded, color: Colors.white, size: 43),
      ),
      const SizedBox(width: 14),
      const Expanded(
        child: Text(
          'Bodensee Pegel+',
          style: TextStyle(
            color: Colors.white,
            fontSize: 29,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
      ),
      const Icon(
        Icons.notifications_none_rounded,
        color: Colors.white,
        size: 34,
      ),
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
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final PegelStation selectedStation;
  final List<PegelStation> stations;
  final AsyncSnapshot<StationLiveData> liveSnapshot;
  final ValueChanged<List<PegelStation>> onOpenStationSelector;
  final VoidCallback onRefresh;
  final Future<bool> isFavorite;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final data =
        liveSnapshot.hasData &&
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
          Row(
            children: [
              const Icon(
                Icons.location_on_outlined,
                color: AppColors.deepBlue,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Messstelle auswählen',
                  child: InkWell(
                    key: const ValueKey('live-station-selector'),
                    onTap: stations.isEmpty
                        ? null
                        : () => onOpenStationSelector(stations),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              selectedStation.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.deepBlue,
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: AppColors.deepBlue,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('favorite-toggle'),
                onPressed: onToggleFavorite,
                tooltip: 'Favorit ändern',
                icon: FutureBuilder<bool>(
                  future: isFavorite,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: AppColors.blue,
                  ),
                ),
              ),
              IconButton(
                onPressed: loading ? null : onRefresh,
                tooltip: 'Live-Daten aktualisieren',
                icon: const Icon(Icons.refresh_rounded, color: AppColors.blue),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            updateLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: unavailable ? AppColors.red : const Color(0xFF64738D),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    level,
                    style: const TextStyle(
                      color: AppColors.navy,
                      fontSize: 96,
                      height: .82,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  data?.unit ?? '',
                  style: const TextStyle(
                    color: AppColors.navy,
                    fontSize: 29,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
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
              if (data?.current.officialState case final state?)
                _OfficialStatus(state: state),
            ],
          ),
          const SizedBox(height: 18),
          _HistorySparkline(
            history: data?.history24Hours,
            verticalMargin: selectedStation.source == StationSource.bafu
                ? .02
                : 2,
          ),
        ],
      ),
    );
  }
}

class BodenseeInsightCard extends StatelessWidget {
  const BodenseeInsightCard({super.key, required this.insight});

  final BodenseeInsight insight;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('bodensee-insight-card'),
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: _cardDecoration(radius: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0xFFE8F2FF),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.lightbulb_outline_rounded,
            color: AppColors.blue,
            size: 25,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'BODENSEE INSIGHT',
                style: TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                insight.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.navy,
                  fontSize: 15,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FavoritesSection extends StatelessWidget {
  const _FavoritesSection({
    required this.stations,
    required this.selectedStation,
    required this.loadLiveData,
    required this.onSelectStation,
  });

  final List<PegelStation> stations;
  final PegelStation selectedStation;
  final Future<StationLiveData> Function(PegelStation) loadLiveData;
  final ValueChanged<PegelStation> onSelectStation;

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      return const _FavoritesEmptyState();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 9),
          child: Text(
            'FAVORITEN',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: .5,
            ),
          ),
        ),
        SizedBox(
          height: 126,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 2),
            itemCount: stations.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final station = stations[index];
              return _FavoriteStationCard(
                key: ValueKey('favorite-card-${station.uuid}'),
                station: station,
                selected: station.uuid == selectedStation.uuid,
                liveData: loadLiveData(station),
                onTap: () => onSelectStation(station),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FavoritesEmptyState extends StatelessWidget {
  const _FavoritesEmptyState();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: _cardDecoration(radius: 22),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FAVORITEN',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: .5,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Noch keine Favoriten – Stern bei einer Station wählen.',
          style: TextStyle(color: Color(0xFF64738D), fontSize: 14),
        ),
      ],
    ),
  );
}

class _FavoriteStationCard extends StatelessWidget {
  const _FavoriteStationCard({
    super.key,
    required this.station,
    required this.selected,
    required this.liveData,
    required this.onTap,
  });

  final PegelStation station;
  final bool selected;
  final Future<StationLiveData> liveData;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 164,
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected ? AppColors.blue : const Color(0xFFE1E9F4),
              width: selected ? 1.6 : 1,
            ),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x160879EE),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ]
                : const [],
          ),
          child: FutureBuilder<StationLiveData>(
            future: liveData,
            builder: (context, snapshot) {
              final data = snapshot.hasData && !snapshot.hasError
                  ? snapshot.data
                  : null;
              final level = data == null
                  ? '–'
                  : '${data.formatValue(data.current.value)} ${data.unit}';
              final change = data?.change24Hours;
              final detail = change == null
                  ? '24 h nicht verfügbar'
                  : '${change > 0
                        ? '+'
                        : change < 0
                        ? '−'
                        : '±'}${data!.formatChange(change.abs())} ${data.unit} · 24 h';
              // A water-level change is information, not a warning. Warning
              // colours remain reserved for future, official alert states.
              final detailColor = change == null
                  ? const Color(0xFF71809A)
                  : AppColors.blue;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    station.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.navy,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    level,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.deepBlue,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: detailColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
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
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .68,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: SingleChildScrollView(
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
                            width: station.uuid == selectedStation.uuid
                                ? 1.5
                                : 1,
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
      final historyUnavailable =
          liveData != null && liveData.history24Hours == null;
      return Text(
        unavailable || historyUnavailable
            ? '24-h-Veränderung nicht verfügbar'
            : '24-h-Veränderung wird geladen …',
        style: const TextStyle(color: Color(0xFF64738D), fontSize: 16),
      );
    }
    final sign = change > 0
        ? '+'
        : change < 0
        ? '−'
        : '±';
    final value = data?.formatChange(change.abs()) ?? '';
    final unit = data!.unit;
    // A 24-hour trend describes a measurement only. Colour is therefore
    // deliberately neutral; warning colours remain reserved for official
    // warning and danger states.
    final color = change == 0 ? const Color(0xFF64738D) : AppColors.blue;
    final icon = change > 0
        ? Icons.arrow_upward_rounded
        : change < 0
        ? Icons.arrow_downward_rounded
        : Icons.remove_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 21),
          const SizedBox(width: 8),
          Text(
            '$sign$value $unit in 24 h',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
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
    final color = state == 'normal'
        ? AppColors.green
        : state == 'high'
        ? AppColors.red
        : const Color(0xFF64738D);
    return Row(
      children: [
        Icon(Icons.circle, color: color, size: 15),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _UnavailableInfoCard extends StatelessWidget {
  const _UnavailableInfoCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: _cardDecoration(),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0xFFEAF3FF),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppColors.blue),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                message,
                style: const TextStyle(
                  color: Color(0xFF64738D),
                  fontSize: 15,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ForecastCard extends StatelessWidget {
  const ForecastCard({
    super.key,
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
                style: TextStyle(
                  color: AppColors.deepBlue,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
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
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('forecast-detail-button'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ForecastDetailPage(forecast: data),
                ),
              ),
              borderRadius: BorderRadius.circular(11),
              child: Ink(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF3FF),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Diagramm ansehen',
                      style: TextStyle(
                        color: AppColors.blue,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.blue,
                      size: 25,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _trend(List<BafuForecastPoint> points) {
    final differenceCm =
        (points.last.medianMasl - points.first.medianMasl) * 100;
    if (differenceCm > .5) return 'steigend';
    if (differenceCm < -.5) return 'fallend';
    return 'etwa gleich';
  }

  BafuForecastPoint _pointAt(List<BafuForecastPoint> points, Duration offset) {
    final target = points.first.timestamp.add(offset);
    return points.reduce(
      (closest, candidate) =>
          candidate.timestamp.difference(target).inMilliseconds.abs() <
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
    final levelCm =
        (point.medianMasl - BafuHydroService.romanshornReferenceMasl) * 100;
    final local = point.timestamp.toLocal();
    final time =
        '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')} · '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final (icon, label) = switch (trend) {
      'steigend' => (Icons.arrow_upward_rounded, 'Langsam steigend'),
      'fallend' => (Icons.arrow_downward_rounded, 'Langsam fallend'),
      _ => (Icons.arrow_forward_rounded, 'Etwa gleich'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'MORGEN',
          style: TextStyle(
            color: Color(0xFF64738D),
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${levelCm.round()}',
          style: const TextStyle(
            color: AppColors.navy,
            fontSize: 42,
            height: .9,
            fontWeight: FontWeight.w900,
            letterSpacing: -2,
          ),
        ),
        const Text(
          'cm',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          time,
          style: const TextStyle(color: Color(0xFF8B98AC), fontSize: 10),
        ),
        const SizedBox(height: 9),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.blue, size: 17),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.blue,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class ForecastDetailPage extends StatefulWidget {
  const ForecastDetailPage({super.key, required this.forecast});

  final BafuForecastData forecast;

  @override
  State<ForecastDetailPage> createState() => _ForecastDetailPageState();
}

class _ForecastDetailPageState extends State<ForecastDetailPage> {
  BafuForecastPoint? _selectedPoint;

  void _selectPoint(Offset position, double width) {
    const left = 46.0;
    const right = 12.0;
    final chartWidth = width - left - right;
    if (chartWidth <= 0) return;
    final fraction = ((position.dx - left) / chartWidth).clamp(0.0, 1.0);
    final first = widget.forecast.points.first.timestamp;
    final last = widget.forecast.points.last.timestamp;
    final target = first.add(
      Duration(
        milliseconds: (last.difference(first).inMilliseconds * fraction)
            .round(),
      ),
    );
    final point = widget.forecast.points.reduce(
      (closest, candidate) =>
          candidate.timestamp.difference(target).abs() <
              closest.timestamp.difference(target).abs()
          ? candidate
          : closest,
    );
    setState(() => _selectedPoint = point);
  }

  @override
  Widget build(BuildContext context) {
    final chartHeight = math
        .max(390.0, MediaQuery.sizeOf(context).height * .5)
        .toDouble();
    return Scaffold(
      backgroundColor: const Color(0xFFF3F7FC),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 20, 12),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('forecast-detail-close'),
                    tooltip: 'Zurück',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: AppColors.navy,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'PROGNOSE · ROMANSHORN',
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
                  decoration: _cardDecoration(radius: 26),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.show_chart_rounded, color: AppColors.blue),
                          SizedBox(width: 9),
                          Text(
                            'BAFU-PROGNOSE',
                            style: TextStyle(
                              color: AppColors.deepBlue,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Auf die Kurve tippen für Zeitpunkt und Prognosebereich.',
                        style: TextStyle(
                          color: Color(0xFF71809A),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, constraints) => SizedBox(
                          height: chartHeight,
                          width: double.infinity,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (details) => _selectPoint(
                              details.localPosition,
                              constraints.maxWidth,
                            ),
                            onPanDown: (details) => _selectPoint(
                              details.localPosition,
                              constraints.maxWidth,
                            ),
                            onPanUpdate: (details) => _selectPoint(
                              details.localPosition,
                              constraints.maxWidth,
                            ),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.precise,
                              onHover: (event) => _selectPoint(
                                event.localPosition,
                                constraints.maxWidth,
                              ),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: _ForecastDetailChartPainter(
                                        widget.forecast.points,
                                        BafuHydroService
                                            .romanshornReferenceMasl,
                                        _selectedPoint,
                                      ),
                                    ),
                                  ),
                                  if (_selectedPoint != null)
                                    Positioned(
                                      top: 8,
                                      right: 4,
                                      child: _ForecastDetailTooltip(
                                        point: _selectedPoint!,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _ForecastDetailSummary(points: widget.forecast.points),
                      const SizedBox(height: 14),
                      const Text(
                        'Quelle: BAFU',
                        style: TextStyle(
                          color: Color(0xFF8B98AC),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForecastDetailSummary extends StatelessWidget {
  const _ForecastDetailSummary({required this.points});

  final List<BafuForecastPoint> points;

  static const _referenceMasl = BafuHydroService.romanshornReferenceMasl;

  @override
  Widget build(BuildContext context) {
    final start = (points.first.medianMasl - _referenceMasl) * 100;
    final end = (points.last.medianMasl - _referenceMasl) * 100;
    final change = end - start;
    final trend = change > .5
        ? 'Langsam steigend'
        : change < -.5
        ? 'Langsam fallend'
        : 'Etwa gleich';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F9FF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Start ${_cm(start)} → Ende ${_cm(end)}',
            style: const TextStyle(
              color: AppColors.navy,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${change >= 0 ? '+' : '−'}${_cm(change.abs())} · $trend',
            style: const TextStyle(
              color: AppColors.blue,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Der hellblaue Bereich zeigt die Unsicherheit der BAFU-Prognose.',
            style: TextStyle(color: Color(0xFF71809A), fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _cm(double value) {
    final digits = value == value.roundToDouble() ? 0 : 1;
    return '${value.toStringAsFixed(digits).replaceAll('.', ',')} cm';
  }
}

class _ForecastDetailTooltip extends StatelessWidget {
  const _ForecastDetailTooltip({required this.point});

  final BafuForecastPoint point;

  static const _referenceMasl = BafuHydroService.romanshornReferenceMasl;

  @override
  Widget build(BuildContext context) {
    final local = point.timestamp.toLocal();
    return Container(
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x16092E60),
            blurRadius: 12,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: AppColors.navy,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} · '
              '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
            ),
            const SizedBox(height: 3),
            Text('Median: ${_cm(point.medianMasl)}'),
            Text('Untergrenze: ${_cm(point.minimumMasl)}'),
            Text('Obergrenze: ${_cm(point.maximumMasl)}'),
          ],
        ),
      ),
    );
  }

  String _cm(double valueMasl) {
    final cm = (valueMasl - _referenceMasl) * 100;
    final digits = cm == cm.roundToDouble() ? 0 : 1;
    return '${cm.toStringAsFixed(digits).replaceAll('.', ',')} cm';
  }
}

class _ForecastDetailChartPainter extends CustomPainter {
  const _ForecastDetailChartPainter(
    this.points,
    this.referenceMasl,
    this.selected,
  );

  final List<BafuForecastPoint> points;
  final double referenceMasl;
  final BafuForecastPoint? selected;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    const left = 46.0;
    const right = 12.0;
    const top = 16.0;
    const bottom = 46.0;
    final chart = Rect.fromLTWH(
      left,
      top,
      size.width - left - right,
      size.height - top - bottom,
    );
    final sourceValues = <double>[
      ...points.map((point) => (point.minimumMasl - referenceMasl) * 100),
      ...points.map((point) => (point.maximumMasl - referenceMasl) * 100),
    ];
    final rawMin = sourceValues.reduce(math.min);
    final rawMax = sourceValues.reduce(math.max);
    final margin = math.max(1, (rawMax - rawMin) * .12).toDouble();
    final step = _niceStep((rawMax - rawMin + margin * 2) / 5);
    final minY = ((rawMin - margin) / step).floor() * step;
    final maxY = ((rawMax + margin) / step).ceil() * step;
    final first = points.first.timestamp;
    final duration = math.max(
      1,
      points.last.timestamp.difference(first).inMilliseconds,
    );

    Offset position(BafuForecastPoint point, double valueCm) {
      final elapsed = point.timestamp.difference(first).inMilliseconds;
      return Offset(
        chart.left + chart.width * elapsed / duration,
        chart.bottom - chart.height * (valueCm - minY) / (maxY - minY),
      );
    }

    final gridPaint = Paint()
      ..color = const Color(0xFFE2EAF5)
      ..strokeWidth = 1;
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var value = minY; value <= maxY + step / 100; value += step) {
      final y = chart.bottom - chart.height * (value - minY) / (maxY - minY);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      labelPainter.text = TextSpan(
        text: _axis(value),
        style: const TextStyle(color: Color(0xFF71809A), fontSize: 10),
      );
      labelPainter.layout();
      labelPainter.paint(
        canvas,
        Offset(
          chart.left - labelPainter.width - 7,
          y - labelPainter.height / 2,
        ),
      );
    }

    final upper = points
        .map(
          (point) => position(point, (point.maximumMasl - referenceMasl) * 100),
        )
        .toList();
    final lower = points
        .map(
          (point) => position(point, (point.minimumMasl - referenceMasl) * 100),
        )
        .toList();
    final band = Path()..moveTo(upper.first.dx, upper.first.dy);
    for (final point in upper.skip(1)) {
      band.lineTo(point.dx, point.dy);
    }
    for (final point in lower.reversed) {
      band.lineTo(point.dx, point.dy);
    }
    band.close();
    canvas.drawPath(
      band,
      Paint()..color = AppColors.blue.withValues(alpha: .10),
    );

    final median = Path();
    for (var index = 0; index < points.length; index++) {
      final point = position(
        points[index],
        (points[index].medianMasl - referenceMasl) * 100,
      );
      if (index == 0) {
        median.moveTo(point.dx, point.dy);
      } else {
        median.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      median,
      Paint()
        ..color = AppColors.deepBlue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    if (selected != null) {
      final selectedPosition = position(
        selected!,
        (selected!.medianMasl - referenceMasl) * 100,
      );
      canvas.drawLine(
        Offset(selectedPosition.dx, chart.top),
        Offset(selectedPosition.dx, chart.bottom),
        Paint()
          ..color = AppColors.blue.withValues(alpha: .45)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(selectedPosition, 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        selectedPosition,
        3.2,
        Paint()..color = AppColors.deepBlue,
      );
    }

    final hours = duration / Duration.millisecondsPerHour;
    final ticks = <double>[
      0,
      24,
      48,
      72,
      96,
    ].where((hour) => hour < hours).toList();
    if (hours > 0) ticks.add(hours);
    for (final hour in ticks) {
      final x = chart.left + chart.width * hour / hours;
      final label = _timeLabel(first, hour, isStart: hour == 0);
      labelPainter.text = TextSpan(
        text: label,
        style: const TextStyle(color: Color(0xFF71809A), fontSize: 9),
      );
      labelPainter.layout();
      labelPainter.paint(
        canvas,
        Offset(
          (x - labelPainter.width / 2)
              .clamp(chart.left, chart.right - labelPainter.width)
              .toDouble(),
          chart.bottom + 9,
        ),
      );
    }
  }

  String _axis(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceAll('.', ',');

  String _timeLabel(DateTime first, double hour, {required bool isStart}) {
    if (isStart) return 'Jetzt';
    final timestamp = first
        .add(
          Duration(milliseconds: (hour * Duration.millisecondsPerHour).round()),
        )
        .toLocal();
    const weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    return '${weekdays[timestamp.weekday - 1]}\n${timestamp.day.toString().padLeft(2, '0')}.${timestamp.month.toString().padLeft(2, '0')}';
  }

  double _niceStep(double value) {
    final exponent = math
        .pow(10, (math.log(value) / math.ln10).floor())
        .toDouble();
    final candidates = <double>[
      exponent / 10,
      exponent / 5,
      exponent / 4,
      exponent / 2,
      exponent,
      exponent * 2,
      exponent * 2.5,
      exponent * 5,
      exponent * 10,
    ];
    return candidates.reduce(
      (best, candidate) =>
          (candidate - value).abs() < (best - value).abs() ? candidate : best,
    );
  }

  @override
  bool shouldRepaint(covariant _ForecastDetailChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.selected != selected;
}

class _ForecastChartPainter extends CustomPainter {
  _ForecastChartPainter(this.points, this.referenceMasl);

  final List<BafuForecastPoint> points;
  final double referenceMasl;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final low = points
        .map((point) => (point.minimumMasl - referenceMasl) * 100)
        .reduce(math.min)
        .toDouble();
    final high = points
        .map((point) => (point.maximumMasl - referenceMasl) * 100)
        .reduce(math.max)
        .toDouble();
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
      final x =
          horizontalPadding +
          drawableWidth * (duration == 0 ? 0 : elapsed / duration);
      final y =
          verticalPadding + drawableHeight * (1 - (value - displayMin) / range);
      return Offset(x, y);
    }

    final upper = points
        .map(
          (point) => position(point, (point.maximumMasl - referenceMasl) * 100),
        )
        .toList();
    final lower = points
        .map(
          (point) => position(point, (point.minimumMasl - referenceMasl) * 100),
        )
        .toList();
    final median = points
        .map(
          (point) => position(point, (point.medianMasl - referenceMasl) * 100),
        )
        .toList();
    _drawTimeAxis(
      canvas,
      size,
      duration,
      horizontalPadding,
      verticalPadding,
      drawableWidth,
      drawableHeight,
    );

    final area = _smoothPath(upper);
    _appendSmoothPath(area, lower.reversed.toList());
    area.close();
    canvas.drawPath(
      area,
      Paint()..color = AppColors.blue.withValues(alpha: .10),
    );

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
    final tickHours = <double>[
      0,
      24,
      48,
      72,
      96,
    ].where((hour) => hour < durationHours).toList();
    if (durationHours > 0) tickHours.add(durationHours);

    final gridPaint = Paint()
      ..color = const Color(0xFFE2EAF5)
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(color: Color(0xFF64738D), fontSize: 9);
    for (final hour in tickHours) {
      final fraction = durationHours == 0 ? 0.0 : hour / durationHours;
      final x = horizontalPadding + drawableWidth * fraction;
      canvas.drawLine(
        Offset(x, verticalPadding),
        Offset(x, verticalPadding + drawableHeight),
        gridPaint,
      );
      final label = hour == 0
          ? 'Jetzt'
          : (hour - durationHours).abs() < .1 && durationHours >= 108
          ? '5 Tage'
          : '${hour.round()}h';
      final textPainter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = (x - textPainter.width / 2)
          .clamp(0.0, size.width - textPainter.width)
          .toDouble();
      textPainter.paint(
        canvas,
        Offset(labelX, verticalPadding + drawableHeight + 5),
      );
    }
  }

  Path _smoothPath(List<Offset> values) {
    final path = Path()..moveTo(values.first.dx, values.first.dy);
    _appendSmoothPath(path, values, moveToFirst: false);
    return path;
  }

  void _appendSmoothPath(
    Path path,
    List<Offset> values, {
    bool moveToFirst = true,
  }) {
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
      path.cubicTo(
        controlOne.dx,
        controlOne.dy,
        controlTwo.dx,
        controlTwo.dy,
        next.dx,
        next.dy,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ForecastChartPainter oldDelegate) =>
      oldDelegate.points != points;
}

class _EnvironmentInfoCard extends StatelessWidget {
  const _EnvironmentInfoCard({required this.config, required this.data});

  final EnvironmentStationConfig config;
  final StationEnvironmentData? data;

  @override
  Widget build(BuildContext context) {
    final noLocalWaterTemperature =
        data?.waterTemperatureC == null &&
        config.waterTemperatureUnavailableLabel != null;
    return Container(
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
                value: noLocalWaterTemperature
                    ? 'Nicht verfügbar'
                    : _temperature(data?.waterTemperatureC),
                detail: noLocalWaterTemperature
                    ? 'Keine lokale Messung'
                    : config.waterTemperatureLabel ?? '',
                accent: const Color(0xFF11B6C7),
                valueFontSize: noLocalWaterTemperature ? 12 : 16,
              ),
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xFFE1E9F4),
            ),
            Expanded(
              child: _EnvironmentSection(
                icon: Icons.air_rounded,
                title: 'WIND',
                value: _windValue(data),
                detail: data?.windSpeedMetersPerSecond == null
                    ? 'nicht verfügbar'
                    : _windDetail(
                        data?.windDirectionDegrees,
                        config.windSourceLabel,
                      ),
                accent: AppColors.blue,
                directionDegrees: data?.windDirectionDegrees,
              ),
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xFFE1E9F4),
            ),
            Expanded(
              child: _EnvironmentSection(
                icon: Icons.thermostat_rounded,
                title: 'LUFT',
                value: _temperature(data?.airTemperatureC),
                detail: data?.airTemperatureC == null
                    ? 'nicht verfügbar'
                    : config.airSourceLabel,
                accent: const Color(0xFFFFA91B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _temperature(double? value) => value == null
      ? '–'
      : '${value.toStringAsFixed(1).replaceAll('.', ',')} °C';

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
    this.valueFontSize = 16,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final Color accent;
  final double? directionDegrees;
  final double valueFontSize;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 7),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .11),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: accent, size: 25),
        ),
        const SizedBox(height: 9),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.navy,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: value == '–' || value == 'Nicht verfügbar'
                      ? const Color(0xFF71809A)
                      : accent,
                  fontSize: valueFontSize,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (directionDegrees != null) ...[
              const SizedBox(width: 2),
              Transform.rotate(
                angle: directionDegrees! * math.pi / 180,
                child: Icon(
                  Icons.arrow_upward_rounded,
                  color: AppColors.navy,
                  size: 13,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 3),
        Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF8B98AC), fontSize: 10),
        ),
      ],
    ),
  );
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    this.onToday,
    this.onLive,
    this.onAnalysis,
    this.onMap,
    this.onMore,
    this.todayActive = false,
    this.analysisActive = false,
    this.mapActive = false,
    this.moreActive = false,
  });

  final VoidCallback? onToday;
  final VoidCallback? onLive;
  final VoidCallback? onAnalysis;
  final VoidCallback? onMap;
  final VoidCallback? onMore;
  final bool todayActive;
  final bool analysisActive;
  final bool mapActive;
  final bool moreActive;

  @override
  Widget build(BuildContext context) => Container(
    height: 113,
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 18),
    decoration: const BoxDecoration(
      color: Colors.white,
      boxShadow: [
        BoxShadow(
          color: Color(0x14052F65),
          blurRadius: 18,
          offset: Offset(0, -4),
        ),
      ],
    ),
    child: Row(
      children: [
        Expanded(
          child: Center(
            child: _NavItem(
              key: const ValueKey('nav-today'),
              icon: Icons.calendar_today_rounded,
              label: 'Heute',
              active: todayActive,
              onTap: onToday,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _NavItem(
              key: const ValueKey('nav-live'),
              icon: Icons.waves_rounded,
              label: 'Live',
              active:
                  !todayActive && !analysisActive && !mapActive && !moreActive,
              onTap: onLive,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _NavItem(
              key: const ValueKey('nav-analysis'),
              icon: Icons.query_stats_rounded,
              label: 'Analyse',
              active: analysisActive,
              onTap: onAnalysis,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _NavItem(
              key: const ValueKey('nav-map'),
              icon: Icons.location_on_outlined,
              label: 'Karte',
              active: mapActive,
              onTap: onMap,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: _NavItem(
              key: const ValueKey('nav-more'),
              icon: Icons.person_outline_rounded,
              label: 'Mehr',
              active: moreActive,
              onTap:
                  onMore ??
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const MorePage()),
                  ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(22),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE7F1FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            icon,
            color: active ? AppColors.blue : AppColors.navy,
            size: 28,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: active ? AppColors.blue : AppColors.navy,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

BoxDecoration _cardDecoration({double radius = 26}) => BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(radius),
  boxShadow: const [
    BoxShadow(color: Color(0x10092E60), blurRadius: 22, offset: Offset(0, 9)),
  ],
);

class _HistorySparkline extends StatelessWidget {
  const _HistorySparkline({
    required this.history,
    required this.verticalMargin,
  });

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
              Text(
                'vor 24 h',
                style: TextStyle(color: Color(0xFF8B98AC), fontSize: 12),
              ),
              Text(
                'jetzt',
                style: TextStyle(color: Color(0xFF8B98AC), fontSize: 12),
              ),
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
    // A three-point weighted average smooths only the drawn line. Endpoints,
    // source timestamps and the raw range stay untouched; the convex weights
    // also prevent visual overshoots beyond neighbouring measurements.
    final renderedValues = <double>[];
    for (var index = 0; index < history.length; index++) {
      if (index == 0 || index == history.length - 1) {
        renderedValues.add(history[index].value);
      } else {
        renderedValues.add(
          (history[index - 1].value +
                  history[index].value * 2 +
                  history[index + 1].value) /
              4,
        );
      }
    }
    final points = <Offset>[];

    final firstTimestamp = history.first.timestamp;
    final lastTimestamp = history.last.timestamp;
    final durationMs = lastTimestamp.difference(firstTimestamp).inMilliseconds;
    for (var index = 0; index < history.length; index++) {
      final elapsedMs = history[index].timestamp
          .difference(firstTimestamp)
          .inMilliseconds;
      final relativePosition = durationMs == 0
          ? index / (history.length - 1)
          : elapsedMs / durationMs;
      final x =
          horizontalPadding +
          (size.width - 2 * horizontalPadding) *
              relativePosition.clamp(0.0, 1.0).toDouble();
      final normalizedValue = (renderedValues[index] - displayMin) / valueRange;
      final y = verticalPadding + drawableHeight * (1 - normalizedValue);
      points.add(Offset(x, y));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      path.lineTo(points[index].dx, points[index].dy);
    }
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
