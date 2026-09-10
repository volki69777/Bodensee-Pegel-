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
const meteoSwissGuettingenUrl =
  'https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/gut/ogd-smn_gut_t_now.csv';
const lindauWaterTemperatureUrl =
  'https://www.gkd.bayern.de/de/seen/wassertemperatur/bayern/lindau-20001001/messwerte';

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

async function fetchDwdRecord(sourceUrl) {
  const sourceResponse = await fetch(sourceUrl, {
    headers: { Accept: 'application/zip' },
    signal: AbortSignal.timeout(12000),
  });
  if (!sourceResponse.ok) throw new Error(`DWD responded with HTTP ${sourceResponse.status}.`);
  return lastCsvRecord(unzipSingleText(Buffer.from(await sourceResponse.arrayBuffer())));
}

function lindauWaterTemperatureRecord(html) {
  const table = html.match(/<table[^>]*class=["'][^"']*tblsort[^"']*["'][^>]*>([\s\S]*?)<\/table>/i)?.[1];
  const row = table?.match(
    /<tr[^>]*>\s*<td[^>]*>\s*([^<]+?)\s*<\/td>\s*<td[^>]*>\s*([\d,.]+)\s*<\/td>\s*<\/tr>/i,
  );
  if (!row) throw new Error('LfU Bayern response has no current Lindau temperature.');
  const [, germanTimestamp, germanValue] = row;
  const timestamp = germanTimestamp.match(/(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2})\s+Uhr/);
  if (!timestamp) throw new Error('LfU Bayern response has an invalid Lindau timestamp.');
  const [, day, month, year, hour, minute] = timestamp;
  const value = Number(germanValue.replace(',', '.'));
  if (!Number.isFinite(value)) throw new Error('LfU Bayern response has an invalid Lindau temperature.');
  // GKD Bayern publishes the table in German local time (Europe/Berlin).
  return {
    waterTemperatureC: value,
    waterTemperatureTimestamp: `${year}-${month}-${day}T${hour}:${minute}:00`,
  };
}

async function fetchLindauWaterTemperature() {
  const sourceResponse = await fetch(lindauWaterTemperatureUrl, {
    headers: { Accept: 'text/html, */*' },
    signal: AbortSignal.timeout(12000),
  });
  if (!sourceResponse.ok) throw new Error(`LfU Bayern responded with HTTP ${sourceResponse.status}.`);
  return lindauWaterTemperatureRecord(await sourceResponse.text());
}

async function fetchOptionalLindauWaterTemperature() {
  try {
    return await fetchLindauWaterTemperature();
  } catch (error) {
    console.error('LfU Bayern Lindau water temperature unavailable:', error);
    return { waterTemperatureC: null, waterTemperatureTimestamp: null };
  }
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
      const [temperature, wind, waterTemperature] = await Promise.all([
        fetchDwdRecord(dwdKonstanzTemperatureUrl),
        fetchDwdRecord(dwdKonstanzWindUrl),
        fetchOptionalLindauWaterTemperature(),
      ]);
      sendJson(response, 200, {
        source: 'DWD',
        station: '02712',
        ...waterTemperature,
        airTemperatureC: numberOrNull(temperature.TT_10),
        windSpeedMetersPerSecond: numberOrNull(wind.FF_10),
        windDirectionDegrees: numberOrNull(wind.DD_10),
      });
      return;
    }

    if (request.url === romanshornEnvironmentRoute) {
      const [csv, waterTemperature] = await Promise.all([
        fetchText(meteoSwissGuettingenUrl),
        fetchOptionalLindauWaterTemperature(),
      ]);
      const record = lastCsvRecord(csv);
      sendJson(response, 200, {
        source: 'MeteoSwiss',
        station: 'GUT',
        ...waterTemperature,
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
  console.log(`Vorarlberg live proxy listening on http://127.0.0.1:${port}${vorarlbergLiveRoute}`);
  console.log(`Environment proxy listening on http://127.0.0.1:${port}/api/environment/{stationUuid}`);
});
