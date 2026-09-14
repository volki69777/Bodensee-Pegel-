import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bodensee_pegel/official_warning_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('DWD CAP parser accepts only Konstanz WarnCellID', () {
    final result = DwdCapWarningParser.parseZip(
      _zip(_dwdCap(warnCellId: DwdCapWarningParser.konstanzWarnCellId)),
    );

    expect(result.source, OfficialWarningSource.dwd);
    expect(result.warnings, hasLength(1));
    expect(result.warnings.single.nativeType, 'Gewitter');
    expect(result.warnings.single.nativeSeverity, 'Severe');
    expect(result.warnings.single.headline, 'Amtliche Gewitterwarnung');

    final other = DwdCapWarningParser.parseZip(_zip(_dwdCap(warnCellId: '1')));
    expect(other.warnings, isEmpty);
  });

  test('DWD CAP parser evaluates every CAP file in a status ZIP', () {
    final archive = Archive()
      ..addFile(
        ArchiveFile('first.xml', 10, utf8.encode(_dwdCap(warnCellId: '1'))),
      )
      ..addFile(
        ArchiveFile(
          'second.xml',
          10,
          utf8.encode(
            _dwdCap(warnCellId: DwdCapWarningParser.konstanzWarnCellId),
          ),
        ),
      );

    final result = DwdCapWarningParser.parseZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    expect(result.warnings, hasLength(1));
  });

  test('GeoSphere parser keeps official warning fields', () {
    final result = GeoSphereWarningParser.parseJson(_geoJson());

    expect(result.source, OfficialWarningSource.geoSphere);
    expect(result.warnings, hasLength(1));
    final warning = result.warnings.single;
    expect(warning.nativeType, 'Sturm');
    expect(warning.nativeSeverity, '2');
    expect(warning.severityLabel, 'Orange Warnung');
    expect(warning.areaName, 'Bregenz');
  });

  test('warnings are assigned only to overlapping local calendar days', () {
    final warning = OfficialWarning(
      source: OfficialWarningSource.dwd,
      nativeId: 'x',
      nativeType: 'Gewitter',
      nativeSeverity: 'Severe',
      startsAt: DateTime.parse('2026-09-13T21:30:00Z'),
      endsAt: DateTime.parse('2026-09-14T00:30:00Z'),
    );
    final warnings = OfficialWarnings(
      source: OfficialWarningSource.dwd,
      warnings: [warning],
    );

    expect(
      warnings.forLocalDay(
        DateTime(2026, 9, 13),
        OfficialWarningTimeZones.berlin,
      ),
      hasLength(1),
    );
    expect(
      warnings.forLocalDay(
        DateTime(2026, 9, 14),
        OfficialWarningTimeZones.berlin,
      ),
      hasLength(1),
    );
    expect(
      warnings.forLocalDay(
        DateTime(2026, 9, 15),
        OfficialWarningTimeZones.berlin,
      ),
      isEmpty,
    );
  });

  test(
    'service reports HTTP failures instead of treating them as no warning',
    () async {
      final service = OfficialWarningService(
        client: MockClient((_) async => http.Response('unavailable', 503)),
      );

      await expectLater(
        service.loadDwdKonstanz(),
        throwsA(isA<OfficialWarningException>()),
      );
      await expectLater(
        service.loadGeoSphereBregenz(),
        throwsA(isA<OfficialWarningException>()),
      );
    },
  );
}

Uint8List _zip(String xml) {
  final archive = Archive()
    ..addFile(ArchiveFile('warning.xml', xml.length, utf8.encode(xml)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _dwdCap({required String warnCellId}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>dwd-1</identifier><sent>2026-09-13T09:00:00+00:00</sent>
  <info><event>Gewitter</event><severity>Severe</severity>
    <onset>2026-09-13T12:00:00+00:00</onset><expires>2026-09-13T18:00:00+00:00</expires>
    <headline>Amtliche Gewitterwarnung</headline><description>Starke Gewitter.</description>
    <area><areaDesc>Konstanz</areaDesc><geocode><valueName>WARNCELLID</valueName><value>$warnCellId</value></geocode></area>
  </info>
</alert>''';

String _geoJson() => jsonEncode({
  'properties': {
    'location': {
      'properties': {'name': 'Bregenz'},
    },
    'warnings': [
      {
        'warnid': '42',
        'warnstufeid': 2,
        'warntypid': 1,
        'create': '2026-09-13T08:00:00Z',
        'begin': '2026-09-13T11:00:00Z',
        'end': '2026-09-13T19:00:00Z',
        'text': 'Sturmwarnung',
        'meteotext': 'Stürmische Böen.',
        'empfehlungen': 'Vorsicht.',
      },
    ],
  },
});
