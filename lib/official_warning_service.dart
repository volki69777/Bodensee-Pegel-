import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:xml/xml.dart';

/// Official weather warnings only. Forecast values are deliberately never used
/// to create or infer a warning.
enum OfficialWarningSource { dwd, geoSphere }

class OfficialWarning {
  const OfficialWarning({
    required this.source,
    required this.nativeId,
    required this.nativeType,
    required this.nativeSeverity,
    required this.startsAt,
    required this.endsAt,
    this.issuedAt,
    this.updatedAt,
    this.headline,
    this.description,
    this.instruction,
    this.areaName,
  });

  final OfficialWarningSource source;
  final String nativeId;
  final String nativeType;
  final String nativeSeverity;
  final DateTime startsAt;
  final DateTime endsAt;
  final DateTime? issuedAt;
  final DateTime? updatedAt;
  final String? headline;
  final String? description;
  final String? instruction;
  final String? areaName;

  String get sourceLabel => switch (source) {
    OfficialWarningSource.dwd => 'Deutscher Wetterdienst (DWD)',
    OfficialWarningSource.geoSphere => 'GeoSphere Austria',
  };

  /// Retains the issuing authority's original scale. No cross-authority
  /// severity conversion happens in this model.
  String get severityLabel => switch (source) {
    OfficialWarningSource.dwd => switch (nativeSeverity.toLowerCase()) {
      'minor' => 'Geringe Warnstufe',
      'moderate' => 'Warnstufe: moderat',
      'severe' => 'Warnstufe: schwer',
      'extreme' => 'Warnstufe: extrem',
      _ => nativeSeverity,
    },
    OfficialWarningSource.geoSphere => switch (nativeSeverity) {
      '1' => 'Gelbe Warnung',
      '2' => 'Orange Warnung',
      '3' => 'Rote Warnung',
      _ => 'Amtliche Warnstufe $nativeSeverity',
    },
  };
}

class OfficialWarnings {
  const OfficialWarnings({
    required this.source,
    required this.warnings,
    this.updatedAt,
  });

  final OfficialWarningSource source;
  final List<OfficialWarning> warnings;
  final DateTime? updatedAt;

  /// A warning belongs to a day only if its real validity period intersects
  /// that station's local calendar day.
  List<OfficialWarning> forLocalDay(DateTime date, tz.Location location) {
    final start = tz.TZDateTime(location, date.year, date.month, date.day);
    final end = tz.TZDateTime(location, date.year, date.month, date.day + 1);
    return warnings
        .where(
          (warning) =>
              warning.startsAt.isBefore(end.toUtc()) &&
              warning.endsAt.isAfter(start.toUtc()),
        )
        .toList(growable: false);
  }
}

class DwdCapWarningParser {
  static const konstanzWarnCellId = '808335043';

  static OfficialWarnings parseZip(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final xmlFiles = archive.files
        .where(
          (file) => file.isFile && file.name.toLowerCase().endsWith('.xml'),
        )
        .toList(growable: false);
    if (xmlFiles.isEmpty) {
      throw const FormatException('DWD-CAP-ZIP enthält keine XML-Datei.');
    }
    final parsed = xmlFiles
        .map((file) => parseXml(String.fromCharCodes(file.content)))
        .toList(growable: false);
    final updatedAt = parsed
        .map((value) => value.updatedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, candidate) =>
              latest == null || candidate.isAfter(latest) ? candidate : latest,
        );
    return OfficialWarnings(
      source: OfficialWarningSource.dwd,
      warnings: List.unmodifiable(
        parsed.expand((value) => value.warnings).toList(growable: false),
      ),
      updatedAt: updatedAt,
    );
  }

  static OfficialWarnings parseXml(String source) {
    final document = XmlDocument.parse(source);
    final alert = document.rootElement;
    if (alert.name.local != 'alert') {
      throw const FormatException('DWD-CAP enthält kein alert-Element.');
    }
    final issuedAt = _date(_childText(alert, 'sent'));
    final alertId = _childText(alert, 'identifier') ?? 'dwd-unknown';
    final warnings = <OfficialWarning>[];
    for (final info in _children(alert, 'info')) {
      final matchingAreas = _children(info, 'area')
          .where(
            (area) => area.innerText.contains('WARNCELLID$konstanzWarnCellId'),
          )
          .toList(growable: false);
      if (matchingAreas.isEmpty) continue;
      final startsAt =
          _date(_childText(info, 'onset')) ??
          _date(_childText(info, 'effective'));
      final endsAt = _date(_childText(info, 'expires'));
      final event = _childText(info, 'event');
      final severity = _childText(info, 'severity');
      if (startsAt == null ||
          endsAt == null ||
          event == null ||
          severity == null) {
        continue;
      }
      warnings.add(
        OfficialWarning(
          source: OfficialWarningSource.dwd,
          nativeId: alertId,
          nativeType: event,
          nativeSeverity: severity,
          startsAt: startsAt,
          endsAt: endsAt,
          issuedAt: issuedAt,
          updatedAt: issuedAt,
          headline: _childText(info, 'headline'),
          description: _childText(info, 'description'),
          instruction: _childText(info, 'instruction'),
          areaName: matchingAreas
              .map((area) => _childText(area, 'areaDesc'))
              .whereType<String>()
              .join(', '),
        ),
      );
    }
    return OfficialWarnings(
      source: OfficialWarningSource.dwd,
      warnings: List.unmodifiable(warnings),
      updatedAt: issuedAt,
    );
  }
}

class GeoSphereWarningParser {
  static OfficialWarnings parseJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('GeoSphere-Warnantwort ist kein Objekt.');
    }
    final properties = decoded['properties'];
    if (properties is! Map) {
      throw const FormatException(
        'GeoSphere-Warnantwort enthält keine Eigenschaften.',
      );
    }
    final location = properties['location'];
    final locationProperties = location is Map ? location['properties'] : null;
    final areaName =
        locationProperties is Map && locationProperties['name'] is String
        ? locationProperties['name'] as String
        : null;
    final rawWarnings = properties['warnings'];
    if (rawWarnings is! List) {
      throw const FormatException(
        'GeoSphere-Warnantwort enthält keine Warnliste.',
      );
    }
    final warnings = <OfficialWarning>[];
    for (final raw in rawWarnings) {
      if (raw is! Map) continue;
      final startsAt = _date(raw['begin']);
      final endsAt = _date(raw['end']);
      final level = raw['warnstufeid'];
      final type = raw['warntypid'];
      final id = raw['warnid'];
      if (startsAt == null ||
          endsAt == null ||
          level == null ||
          type == null ||
          id == null) {
        continue;
      }
      warnings.add(
        OfficialWarning(
          source: OfficialWarningSource.geoSphere,
          nativeId: id.toString(),
          nativeType: _geoSphereType(type),
          nativeSeverity: level.toString(),
          startsAt: startsAt,
          endsAt: endsAt,
          issuedAt: _date(raw['create']),
          updatedAt: _date(raw['create']),
          headline: _string(raw['text']),
          description:
              _string(raw['meteotext']) ?? _string(raw['auswirkungen']),
          instruction: _string(raw['empfehlungen']),
          areaName: areaName,
        ),
      );
    }
    final updatedAt = warnings
        .map((warning) => warning.updatedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, candidate) =>
              latest == null || candidate.isAfter(latest) ? candidate : latest,
        );
    return OfficialWarnings(
      source: OfficialWarningSource.geoSphere,
      warnings: List.unmodifiable(warnings),
      updatedAt: updatedAt,
    );
  }
}

class OfficialWarningService {
  OfficialWarningService({http.Client? client})
    : _client = client ?? http.Client();

  static const dwdKonstanzProxyUrl =
      'http://127.0.0.1:8787/api/dwd/warnings/konstanz';
  static const geoSphereBregenzUrl =
      'https://warnungen.zamg.at/wsapp/api/getWarningsForCoords?lat=47.5037&lon=9.7432&lang=de';
  static const cacheDuration = Duration(minutes: 5);

  final http.Client _client;
  final Map<OfficialWarningSource, OfficialWarnings> _cache = {};
  final Map<OfficialWarningSource, DateTime> _cachedAt = {};
  final Map<OfficialWarningSource, Future<OfficialWarnings>> _inFlight = {};

  Future<OfficialWarnings> loadDwdKonstanz({bool forceRefresh = false}) =>
      _load(OfficialWarningSource.dwd, forceRefresh, () async {
        final response = await _client
            .get(Uri.parse(dwdKonstanzProxyUrl))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw const OfficialWarningException(
            'DWD-Warnungen sind derzeit nicht verfügbar.',
          );
        }
        return DwdCapWarningParser.parseZip(response.bodyBytes);
      });

  Future<OfficialWarnings> loadGeoSphereBregenz({bool forceRefresh = false}) =>
      _load(OfficialWarningSource.geoSphere, forceRefresh, () async {
        final response = await _client
            .get(
              Uri.parse(geoSphereBregenzUrl),
              headers: const {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw const OfficialWarningException(
            'GeoSphere-Warnungen sind derzeit nicht verfügbar.',
          );
        }
        return GeoSphereWarningParser.parseJson(response.body);
      });

  Future<OfficialWarnings> _load(
    OfficialWarningSource source,
    bool forceRefresh,
    Future<OfficialWarnings> Function() loader,
  ) {
    final cached = _cache[source];
    final cachedAt = _cachedAt[source];
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < cacheDuration) {
      return Future.value(cached);
    }
    return _inFlight[source] ??= loader()
        .then((value) {
          _cache[source] = value;
          _cachedAt[source] = DateTime.now();
          return value;
        })
        .whenComplete(() {
          _inFlight.remove(source);
        });
  }
}

class OfficialWarningTimeZones {
  static final berlin = _location('Europe/Berlin');
  static final vienna = _location('Europe/Vienna');

  static tz.Location _location(String name) {
    timezone_data.initializeTimeZones();
    return tz.getLocation(name);
  }
}

class OfficialWarningException implements Exception {
  const OfficialWarningException(this.message);
  final String message;

  @override
  String toString() => message;
}

List<XmlElement> _children(XmlElement parent, String localName) => parent
    .children
    .whereType<XmlElement>()
    .where((element) => element.name.local == localName)
    .toList(growable: false);

String? _childText(XmlElement parent, String localName) =>
    _children(parent, localName)
        .map((element) => element.innerText.trim())
        .where((value) => value.isNotEmpty)
        .firstOrNull;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? _string(Object? value) {
  final result = value is String ? value.trim() : null;
  return result == null || result.isEmpty ? null : result;
}

String _geoSphereType(Object value) => switch (value.toString()) {
  '1' => 'Sturm',
  '2' => 'Regen',
  '3' => 'Schnee',
  '4' => 'Glatteis',
  '5' => 'Gewitter',
  '6' => 'Hitze',
  '7' => 'Kälte',
  _ => 'Amtliche Warnart ${value.toString()}',
};
