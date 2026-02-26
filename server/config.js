const fs = require('fs');
const net = require('net');
const path = require('path');
const dotenv = require('dotenv');

const ENV_PATH = path.resolve(__dirname, '.env');

function log(message, payload) {
  const timestamp = new Date().toISOString();
  if (payload !== undefined) {
    console.log(`[${timestamp}] [config] ${message}`, payload);
    return;
  }
  console.log(`[${timestamp}] [config] ${message}`);
}

function normalizeIp(ip) {
  if (!ip) return '';
  return String(ip).trim().replace(/^::ffff:/, '');
}

function loadEnvSafely() {
  if (!fs.existsSync(ENV_PATH)) {
    log('No .env file found. Using existing environment variables only.', { envPath: ENV_PATH });
    return;
  }

  const result = dotenv.config({ path: ENV_PATH, override: false });
  if (result.error) {
    throw new Error(`Unable to parse ${ENV_PATH}: ${result.error.message}`);
  }

  log('Loaded environment variables from file', { envPath: ENV_PATH });
}

function parseInteger(name, rawValue, fallback, options = {}) {
  const value = rawValue === undefined || rawValue === '' ? fallback : Number(rawValue);
  if (!Number.isInteger(value)) {
    throw new Error(`${name} must be an integer. Received: ${rawValue}`);
  }

  const { min, max } = options;
  if (min !== undefined && value < min) {
    throw new Error(`${name} must be >= ${min}. Received: ${value}`);
  }
  if (max !== undefined && value > max) {
    throw new Error(`${name} must be <= ${max}. Received: ${value}`);
  }

  return value;
}

function parseBoolean(name, rawValue, fallback) {
  if (rawValue === undefined || rawValue === '') {
    return fallback;
  }

  const normalized = String(rawValue).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) {
    return true;
  }
  if (['0', 'false', 'no', 'off'].includes(normalized)) {
    return false;
  }

  throw new Error(`${name} must be a boolean (true/false). Received: ${rawValue}`);
}

function parseCsv(rawValue, fallback = '') {
  const value = rawValue === undefined ? fallback : rawValue;
  return String(value)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function parseIp(name, rawValue, fallback, options = {}) {
  const { optional = false } = options;
  const selected = rawValue === undefined || rawValue === '' ? fallback : rawValue;

  if ((selected === undefined || selected === '') && optional) {
    return undefined;
  }

  const normalized = normalizeIp(selected);
  if (net.isIP(normalized) === 0) {
    throw new Error(`${name} must be a valid IPv4/IPv6 address. Received: ${selected}`);
  }

  return normalized;
}

loadEnvSafely();

const httpHost = parseIp('SERVER_HOST', process.env.SERVER_HOST, '0.0.0.0');
const httpPort = parseInteger(
  'HTTP_PORT/PORT',
  process.env.HTTP_PORT ?? process.env.PORT,
  3000,
  { min: 1, max: 65535 }
);

const corsEntries = parseCsv(process.env.CORS_ORIGIN, '*');
const allowAnyCorsOrigin = corsEntries.length === 0 || corsEntries.includes('*');
const corsOrigins = allowAnyCorsOrigin ? [] : corsEntries;

const allowedClientIps = parseCsv(process.env.ALLOWED_CLIENT_IPS)
  .map((ip) => parseIp('ALLOWED_CLIENT_IPS', ip, undefined, { optional: false }));

const mediasoupListenIp = parseIp('MEDIASOUP_LISTEN_IP', process.env.MEDIASOUP_LISTEN_IP, '0.0.0.0');
const mediasoupAnnouncedIp = parseIp(
  'MEDIASOUP_ANNOUNCED_IP',
  process.env.MEDIASOUP_ANNOUNCED_IP,
  undefined,
  { optional: true }
);

const rtcMinPort = parseInteger('MEDIASOUP_MIN_PORT', process.env.MEDIASOUP_MIN_PORT, 20000, {
  min: 1,
  max: 65535
});
const rtcMaxPort = parseInteger('MEDIASOUP_MAX_PORT', process.env.MEDIASOUP_MAX_PORT, 29999, {
  min: 1,
  max: 65535
});

if (rtcMaxPort < rtcMinPort) {
  throw new Error(`MEDIASOUP_MAX_PORT (${rtcMaxPort}) must be >= MEDIASOUP_MIN_PORT (${rtcMinPort})`);
}

const config = {
  envPath: ENV_PATH,
  debugLogs: parseBoolean('DEBUG_LOGS', process.env.DEBUG_LOGS, true),
  trustProxy: parseBoolean('TRUST_PROXY', process.env.TRUST_PROXY, false),
  requireOrigin: parseBoolean('REQUIRE_ORIGIN', process.env.REQUIRE_ORIGIN, false),

  httpHost,
  httpPort,

  corsOrigin: allowAnyCorsOrigin ? '*' : corsOrigins,
  corsOrigins,
  allowAnyCorsOrigin,

  allowedClientIps,
  socketSharedSecret: process.env.SOCKET_SHARED_SECRET || '',

  mediasoup: {
    worker: {
      rtcMinPort,
      rtcMaxPort,
      logLevel: process.env.MEDIASOUP_LOG_LEVEL || 'warn',
      logTags: ['info', 'ice', 'dtls', 'rtp', 'srtp', 'rtcp']
    },
    router: {
      mediaCodecs: [
        {
          kind: 'audio',
          mimeType: 'audio/opus',
          clockRate: 48000,
          channels: 2
        },
        {
          kind: 'video',
          mimeType: 'video/VP8',
          clockRate: 90000,
          parameters: {
            'x-google-start-bitrate': 1000
          }
        },
        {
          kind: 'video',
          mimeType: 'video/H264',
          clockRate: 90000,
          parameters: {
            'packetization-mode': 1,
            'profile-level-id': '42e01f',
            'level-asymmetry-allowed': 1,
            'x-google-start-bitrate': 1000
          }
        }
      ]
    },
    webRtcTransport: {
      listenIps: [
        {
          ip: mediasoupListenIp,
          announcedIp: mediasoupAnnouncedIp
        }
      ],
      enableUdp: true,
      enableTcp: true,
      preferUdp: true,
      initialAvailableOutgoingBitrate: 1_000_000,
      maxIncomingBitrate: 1_500_000
    }
  }
};

module.exports = config;
