import http from 'node:http';
import { inflateRawSync } from 'node:zlib';

const port = Number(process.env.BAFU_PROXY_PORT ?? 8787);
const bafuHistoryRoute = '/api/bafu/stations/2032/water-level-history';
const bafuSourceUrl =
  'https://www.hydrodaten.admin.ch/plots/p_q_7days/2032_p_q_7days_de.json';
const bafuHistory40DaysSourceUrl =
  'https://www.hydrodaten.admin.ch/plots/p_q_40days/2032_p_q_40days_de.json';
const bafuAnnualRoute = '/api/bafu/stations/2032/water-level-annual';
const bafuForecastRoute = '/api/bafu/stations/2032/water-level-forecast';
const bafuForecastSourceUrl =
  'https://www.hydrodaten.admin.ch/plots/p_forecast/2032_p_forecast_de.json';
const vorarlbergLiveRoute = '/api/vorarlberg/stations/200337/water-level';
const vorarlbergSourceUrl = 'https://vowis.vorarlberg.at/api/see';
const vorarlbergAnnualRoute =
  '/api/vorarlberg/stations/200337/water-level-annual';
const vorarlbergAnnualSourceUrl =
  'https://vowis.vorarlberg.at/api/see/jahresganglinie';
const konstanzEnvironmentRoute =
  '/api/environment/aa9179c1-17ef-4c61-a48a-74193fa7bfdf';
const romanshornEnvironmentRoute = '/api/environment/bafu-2032';
const bregenzEnvironmentRoute = '/api/environment/vowis-200337';
const dwdKonstanzTemperatureUrl =
  'https://opendata.dwd.de/climate_environment/CDC/observations_germany/climate/10_minutes/air_temperature/now/10minutenwerte_TU_02712_now.zip';
const dwdKonstanzWindUrl =
  'https://opendata.dwd.de/climate_environment/CDC/observations_germany/climate/10_minutes/wind/now/10minutenwerte_wind_02712_now.zip';
const dwdMosmixKonstanzRoute = '/api/dwd/mosmix/konstanz';
const dwdMosmixKonstanzSourceUrl =
  'https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/single_stations/10929/kml/MOSMIX_L_LATEST_10929.kmz';
const dwdWarningsKonstanzRoute = '/api/dwd/warnings/konstanz';
const dwdWarningsKonstanzSourceUrl =
  'https://opendata.dwd.de/weather/alerts/cap/COMMUNEUNION_DWD_STAT/Z_CAP_C_EDZW_LATEST_PVW_STATUS_PREMIUMDWD_COMMUNEUNION_DE.zip';
const meteoSwissGuettingenUrl =
  'https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/gut/ogd-smn_gut_t_now.csv';
const meteoSwissRomanshornRoute = '/api/meteoswiss/forecast/romanshorn';
const meteoSwissStacItemsUrl =
  'https://data.geo.admin.ch/api/stac/v1/collections/ch.meteoschweiz.ogd-local-forecasting/items?limit=10';
const meteoSwissRomanshornPoint = {
  pointId: '859000',
  pointTypeId: '2',
  postalCode: '8590',
  name: 'Romanshorn',
  latitude: 47.566578,
  longitude: 9.370531,
  elevationMeters: 412,
};
const meteoSwissParameters = [
  'tre200h0',
  'rre150h0',
  'fu3010h0',
  'fu3010h1',
  'dkl010h0',
  'jww003i0',
];
let meteoSwissForecastCache;
let meteoSwissForecastCacheAt;
let meteoSwissForecastInFlight;

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(JSON.stringify(payload));
}

function normalizedPoints(payload) {
  const traces = payload?.plot?.data;
  if (!Array.isArray(traces)) throw new Error('BAFU response has no data traces.');
  const trace = traces.find(
    (candidate) => Array.isArray(candidate?.x) && Array.isArray(candidate?.y),
  );
  if (!trace || trace.x.length !== trace.y.length) {
    throw new Error('BAFU response has no matching time and value arrays.');
  }
  const points = trace.x
    .map((timestamp, index) => ({ timestamp, value: Number(trace.y[index]) }))
    .filter(
      (point) =>
        typeof point.timestamp === 'string' &&
        Number.isFinite(point.value) &&
        !Number.isNaN(Date.parse(point.timestamp)),
    );
  if (points.length < 2) throw new Error('BAFU response contains too few valid points.');
  return points;
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function lastCsvRecord(csvText) {
  const lines = csvText.trim().split(/\r?\n/);
  if (lines.length < 2) throw new Error('Source CSV has no data rows.');
  const header = lines[0].replace(/^\uFEFF/, '').split(';').map((field) => field.trim());
  const values = lines.at(-1).trim().split(';').map((field) => field.trim());
  if (values.length !== header.length) throw new Error('Source CSV has an invalid final row.');
  return Object.fromEntries(header.map((field, index) => [field, values[index]]));
}

function unzipSingleText(buffer) {
  const endOfCentralDirectory = buffer.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (endOfCentralDirectory < 0) throw new Error('DWD response is not a ZIP file.');
  const centralDirectoryOffset = buffer.readUInt32LE(endOfCentralDirectory + 16);
  if (buffer.readUInt32LE(centralDirectoryOffset) !== 0x02014b50) {
    throw new Error('DWD ZIP central directory is invalid.');
  }
  const compression = buffer.readUInt16LE(centralDirectoryOffset + 10);
  const compressedSize = buffer.readUInt32LE(centralDirectoryOffset + 20);
  const localHeaderOffset = buffer.readUInt32LE(centralDirectoryOffset + 42);
  if (buffer.readUInt32LE(localHeaderOffset) !== 0x04034b50) {
    throw new Error('DWD ZIP local header is invalid.');
  }
  const nameLength = buffer.readUInt16LE(localHeaderOffset + 26);
  const extraLength = buffer.readUInt16LE(localHeaderOffset + 28);
  const start = localHeaderOffset + 30 + nameLength + extraLength;
  const compressed = buffer.subarray(start, start + compressedSize);
  if (compression === 0) return compressed.toString('utf8');
  if (compression === 8) return inflateRawSync(compressed).toString('utf8');
  throw new Error(`Unsupported DWD ZIP compression method ${compression}.`);
}

async function fetchText(sourceUrl) {
  const sourceResponse = await fetch(sourceUrl, {
    headers: { Accept: 'text/csv, application/zip, */*' },
    signal: AbortSignal.timeout(12000),
  });
  if (!sourceResponse.ok) throw new Error(`Source responded with HTTP ${sourceResponse.status}.`);
  return sourceResponse.text();
}

function parseMeteoSwissRun(name) {
  const match = /^vnut12\.lssw\.(\d{12})\.([a-z0-9]+)\.csv$/i.exec(name);
  if (!match) return null;
  const [, rawTimestamp, parameter] = match;
  const timestamp = Date.UTC(
    Number(rawTimestamp.slice(0, 4)),
    Number(rawTimestamp.slice(4, 6)) - 1,
    Number(rawTimestamp.slice(6, 8)),
    Number(rawTimestamp.slice(8, 10)),
    Number(rawTimestamp.slice(10, 12)),
  );
  return Number.isFinite(timestamp) ? { timestamp, parameter } : null;
}

function meteoswissTimestampUtc(raw) {
  if (!/^\d{12}$/.test(raw)) return null;
  const timestamp = Date.UTC(
    Number(raw.slice(0, 4)),
    Number(raw.slice(4, 6)) - 1,
    Number(raw.slice(6, 8)),
    Number(raw.slice(8, 10)),
    Number(raw.slice(10, 12)),
  );
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

async function loadMeteoSwissRomanshornParameter(sourceUrl, parameter) {
  const sourceResponse = await fetch(sourceUrl, {
    headers: { Accept: 'text/csv; charset=ISO-8859-1, text/csv, */*' },
    signal: AbortSignal.timeout(120000),
  });
  if (!sourceResponse.ok) {
    throw new Error(`MeteoSwiss ${parameter} responded with HTTP ${sourceResponse.status}.`);
  }
  // The official point files contain all Swiss forecast points. Filter only
  // Romanshorn while the data is server-side, so Flutter receives no bulky
  // nationwide dataset and never has to access the cross-origin CSV directly.
  const text = await sourceResponse.text();
  const values = new Map();
  const expression = /^859000;2;(\d{12});([^\r\n]*)$/gm;
  for (const match of text.matchAll(expression)) {
    const timestampUtc = meteoswissTimestampUtc(match[1]);
    if (timestampUtc) values.set(timestampUtc, numberOrNull(match[2]?.trim()));
  }
  if (values.size === 0) {
    throw new Error(`MeteoSwiss ${parameter} has no Romanshorn point rows.`);
  }
  return values;
}

async function fetchMeteoSwissRomanshornForecast() {
  const catalogResponse = await fetch(meteoSwissStacItemsUrl, {
    headers: { Accept: 'application/geo+json, application/json' },
    signal: AbortSignal.timeout(20000),
  });
  if (!catalogResponse.ok) {
    throw new Error(`MeteoSwiss STAC responded with HTTP ${catalogResponse.status}.`);
  }
  const catalog = await catalogResponse.json();
  if (!Array.isArray(catalog?.features)) {
    throw new Error('MeteoSwiss STAC has no forecast items.');
  }
  const newestByParameter = new Map();
  let updatedAtUtc = null;
  for (const item of catalog.features) {
    const updated = Date.parse(item?.properties?.updated ?? '');
    if (Number.isFinite(updated) && (!updatedAtUtc || updated > Date.parse(updatedAtUtc))) {
      updatedAtUtc = new Date(updated).toISOString();
    }
    for (const [name, asset] of Object.entries(item?.assets ?? {})) {
      const parsed = parseMeteoSwissRun(name);
      if (!parsed || !meteoSwissParameters.includes(parsed.parameter) || !asset?.href) continue;
      const existing = newestByParameter.get(parsed.parameter);
      if (!existing || parsed.timestamp > existing.timestamp) {
        newestByParameter.set(parsed.parameter, { ...parsed, href: asset.href });
      }
    }
  }
  if (newestByParameter.size !== meteoSwissParameters.length) {
    throw new Error('MeteoSwiss STAC is missing a required Romanshorn forecast parameter.');
  }

  const rawParameters = new Map();
  // Process sequentially to limit the memory footprint of the large official
  // all-Switzerland CSV files. Results are cached below for 30 minutes.
  for (const parameter of meteoSwissParameters) {
    const asset = newestByParameter.get(parameter);
    rawParameters.set(
      parameter,
      await loadMeteoSwissRomanshornParameter(asset.href, parameter),
    );
  }
  const timestamps = new Set();
  for (const values of rawParameters.values()) {
    for (const timestamp of values.keys()) timestamps.add(timestamp);
  }
  const points = [...timestamps]
    .sort()
    .map((timestampUtc) => ({
      timestampUtc,
      temperatureCelsius: rawParameters.get('tre200h0').get(timestampUtc) ?? null,
      precipitationMillimeters: rawParameters.get('rre150h0').get(timestampUtc) ?? null,
      windKilometersPerHour: rawParameters.get('fu3010h0').get(timestampUtc) ?? null,
      gustKilometersPerHour: rawParameters.get('fu3010h1').get(timestampUtc) ?? null,
      windDirectionDegrees: rawParameters.get('dkl010h0').get(timestampUtc) ?? null,
      weatherCode: rawParameters.get('jww003i0').get(timestampUtc) ?? null,
    }));
  if (points.length === 0) throw new Error('MeteoSwiss has no Romanshorn forecast points.');
  const runAtUtc = new Date(
    Math.max(...[...newestByParameter.values()].map((asset) => asset.timestamp)),
  ).toISOString();
  return {
    source: 'MeteoSwiss Open Data · Localised forecasting data – Point data',
    station: meteoSwissRomanshornPoint,
    updatedAtUtc,
    runAtUtc,
    sourceUrls: Object.fromEntries(
      [...newestByParameter.entries()].map(([parameter, asset]) => [parameter, asset.href]),
    ),
    points,
  };
}

async function loadMeteoSwissRomanshornForecast() {
  const cacheStillValid =
    meteoSwissForecastCache &&
    meteoSwissForecastCacheAt &&
    Date.now() - meteoSwissForecastCacheAt < 30 * 60 * 1000;
  if (cacheStillValid) return meteoSwissForecastCache;
  meteoSwissForecastInFlight ??= fetchMeteoSwissRomanshornForecast()
    .then((forecast) => {
      meteoSwissForecastCache = forecast;
      meteoSwissForecastCacheAt = Date.now();
      return forecast;
    })
    .finally(() => {
      meteoSwissForecastInFlight = undefined;
    });
  return meteoSwissForecastInFlight;
}

async function fetchDwdRecord(sourceUrl) {
  const sourceResponse = await fetch(sourceUrl, {
    headers: { Accept: 'application/zip' },
    signal: AbortSignal.timeout(12000),
  });
  if (!sourceResponse.ok) throw new Error(`DWD responded with HTTP ${sourceResponse.status}.`);
  return lastCsvRecord(unzipSingleText(Buffer.from(await sourceResponse.arrayBuffer())));
}

async function fetchVorarlbergStationData() {
  const sourceResponse = await fetch(vorarlbergSourceUrl, {
    headers: { Accept: 'application/json' },
    signal: AbortSignal.timeout(12000),
  });
  if (!sourceResponse.ok) {
    throw new Error(`Vorarlberg responded with HTTP ${sourceResponse.status}.`);
  }
  const sourcePayload = await sourceResponse.json();
  const stationData = Array.isArray(sourcePayload) ? sourcePayload[0] : sourcePayload;
  if (
    !stationData?.wasserstand ||
    !Number.isFinite(Number(stationData.wasserstand.wert)) ||
    Number.isNaN(Date.parse(stationData.wasserstand.datum))
  ) {
    throw new Error('Vorarlberg response has no valid water level.');
  }
  return stationData;
}

const server = http.createServer(async (request, response) => {
  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
    });
    response.end();
    return;
  }
  if (request.method !== 'GET') {
    sendJson(response, 404, { error: 'Not found.' });
    return;
  }

  try {
    const requestUrl = new URL(request.url, `http://${request.headers.host}`);

    if (requestUrl.pathname === vorarlbergLiveRoute) {
      sendJson(response, 200, await fetchVorarlbergStationData());
      return;
    }

    if (requestUrl.pathname === dwdMosmixKonstanzRoute) {
      const sourceResponse = await fetch(dwdMosmixKonstanzSourceUrl, {
        headers: { Accept: 'application/vnd.google-earth.kmz, application/zip, */*' },
        signal: AbortSignal.timeout(12000),
      });
      if (!sourceResponse.ok) {
        throw new Error(`DWD MOSMIX responded with HTTP ${sourceResponse.status}.`);
      }
      const kmz = Buffer.from(await sourceResponse.arrayBuffer());
      response.writeHead(200, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Content-Type': 'application/vnd.google-earth.kmz',
        'Cache-Control': 'no-store',
      });
      response.end(kmz);
      return;
    }

    // DWD CAP does not allow browser CORS. Keep the official ZIP byte-for-byte
    // intact; Flutter performs the CAP parsing and filters Konstanz by the
    // documented WarnCellID 808335043.
    if (requestUrl.pathname === dwdWarningsKonstanzRoute) {
      const sourceResponse = await fetch(dwdWarningsKonstanzSourceUrl, {
        headers: { Accept: 'application/zip, */*' },
        signal: AbortSignal.timeout(12000),
      });
      if (!sourceResponse.ok) {
        throw new Error(`DWD CAP warnings responded with HTTP ${sourceResponse.status}.`);
      }
      const zip = Buffer.from(await sourceResponse.arrayBuffer());
      response.writeHead(200, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Content-Type': 'application/zip',
        'Cache-Control': 'no-store',
      });
      response.end(zip);
      return;
    }

    if (requestUrl.pathname === meteoSwissRomanshornRoute) {
      sendJson(response, 200, await loadMeteoSwissRomanshornForecast());
      return;
    }

    if (requestUrl.pathname === vorarlbergAnnualRoute) {
      const sourceResponse = await fetch(vorarlbergAnnualSourceUrl, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(12000),
      });
      if (!sourceResponse.ok) {
        throw new Error(`Vorarlberg annual history responded with HTTP ${sourceResponse.status}.`);
      }
      sendJson(response, 200, await sourceResponse.json());
      return;
    }

    if (request.url === konstanzEnvironmentRoute) {
      const [temperature, wind] = await Promise.all([
        fetchDwdRecord(dwdKonstanzTemperatureUrl),
        fetchDwdRecord(dwdKonstanzWindUrl),
      ]);
      sendJson(response, 200, {
        source: 'DWD',
        station: '02712',
        waterTemperatureC: null,
        waterTemperatureTimestamp: null,
        airTemperatureC: numberOrNull(temperature.TT_10),
        windSpeedMetersPerSecond: numberOrNull(wind.FF_10),
        windDirectionDegrees: numberOrNull(wind.DD_10),
      });
      return;
    }

    if (request.url === romanshornEnvironmentRoute) {
      const csv = await fetchText(meteoSwissGuettingenUrl);
      const record = lastCsvRecord(csv);
      sendJson(response, 200, {
        source: 'MeteoSwiss',
        station: 'GUT',
        waterTemperatureC: null,
        waterTemperatureTimestamp: null,
        airTemperatureC: numberOrNull(record.tre200s0),
        windSpeedMetersPerSecond: numberOrNull(record.fkl010z0),
        windDirectionDegrees: numberOrNull(record.dkl010z0),
      });
      return;
    }

    if (request.url === bregenzEnvironmentRoute) {
      const stationData = await fetchVorarlbergStationData();
      sendJson(response, 200, {
        source: 'Wasserwirtschaft Vorarlberg',
        station: 'Bregenz (Seepegel), 200337',
        waterTemperatureC: numberOrNull(stationData.wtMilli05?.wert),
        waterTemperatureTimestamp: stationData.wtMilli05?.datum ?? null,
        windSpeedMetersPerSecond: numberOrNull(stationData.windgeschwindigkeit?.wert),
        windDirectionDegrees: numberOrNull(stationData.windrichtung?.wert),
        airTemperatureC: numberOrNull(stationData.lufttemperatur?.wert),
      });
      return;
    }

    if (requestUrl.pathname === bafuForecastRoute) {
      const sourceResponse = await fetch(bafuForecastSourceUrl, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(12000),
      });
      if (!sourceResponse.ok) {
        throw new Error(`BAFU forecast responded with HTTP ${sourceResponse.status}.`);
      }
      const sourcePayload = await sourceResponse.json();
      if (!Array.isArray(sourcePayload?.plot?.data)) {
        throw new Error('BAFU forecast response has no plot data.');
      }
      sendJson(response, 200, sourcePayload);
      return;
    }

    if (requestUrl.pathname === bafuAnnualRoute) {
      const year = requestUrl.searchParams.get('year');
      if (!/^\d{4}$/.test(year ?? '')) throw new Error('Invalid BAFU comparison year.');
      const sourceResponse = await fetch(
        `https://www.hydrodaten.admin.ch/web/hydro/de/p_annual/2032/${year}/plot`,
        { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(12000) },
      );
      if (!sourceResponse.ok) throw new Error(`BAFU annual history responded with HTTP ${sourceResponse.status}.`);
      sendJson(response, 200, await sourceResponse.json());
      return;
    }

    if (requestUrl.pathname !== bafuHistoryRoute) {
      sendJson(response, 404, { error: 'Not found.' });
      return;
    }

    const historySourceUrl = requestUrl.searchParams.get('range') === '40d'
      ? bafuHistory40DaysSourceUrl
      : bafuSourceUrl;
    const sourceResponse = await fetch(historySourceUrl, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(12000),
    });
    if (!sourceResponse.ok) {
      throw new Error(`BAFU responded with HTTP ${sourceResponse.status}.`);
    }
    const sourcePayload = await sourceResponse.json();
    sendJson(response, 200, {
      source: historySourceUrl,
      stationId: 2032,
      unit: 'm ü. M.',
      points: normalizedPoints(sourcePayload),
    });
  } catch (error) {
    console.error('Hydrology/environment proxy failed:', error);
    sendJson(response, 502, { error: 'Official source is currently unavailable.' });
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`BAFU history proxy listening on http://127.0.0.1:${port}${bafuHistoryRoute}`);
  console.log(`BAFU forecast proxy listening on http://127.0.0.1:${port}${bafuForecastRoute}`);
  console.log(`DWD MOSMIX proxy listening on http://127.0.0.1:${port}${dwdMosmixKonstanzRoute}`);
  console.log(`DWD CAP warning proxy listening on http://127.0.0.1:${port}${dwdWarningsKonstanzRoute}`);
  console.log(`MeteoSwiss Romanshorn proxy listening on http://127.0.0.1:${port}${meteoSwissRomanshornRoute}`);
  console.log(`Vorarlberg live proxy listening on http://127.0.0.1:${port}${vorarlbergLiveRoute}`);
  console.log(`Environment proxy listening on http://127.0.0.1:${port}/api/environment/{stationUuid}`);
});
