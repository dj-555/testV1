function numberFromEnv(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function boolFromEnv(value, fallback = false) {
  if (value == null) return fallback;

  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return fallback;
}

const config = {
  httpPort: Number(process.env.PORT || 3000),
  corsOrigin: process.env.CORS_ORIGIN || '*',
  turn: {
    enabled: boolFromEnv(process.env.TURN_ENABLED, false),
    host: process.env.TURN_HOST || process.env.MEDIASOUP_ANNOUNCED_IP || '',
    port: numberFromEnv(process.env.TURN_PORT, 3478),
    tlsPort: numberFromEnv(process.env.TURN_TLS_PORT, 5349),
    username: process.env.TURN_USERNAME || '',
    password: process.env.TURN_PASSWORD || '',
    staticAuthSecret: process.env.TURN_STATIC_AUTH_SECRET || '',
    realm: process.env.TURN_REALM || '',
    credentialTtlSec: numberFromEnv(process.env.TURN_CREDENTIAL_TTL_SEC, 3600),
    forceRelay: boolFromEnv(process.env.WEBRTC_FORCE_RELAY, false)
  },
  mediasoup: {
    worker: {
      rtcMinPort: Number(process.env.MEDIASOUP_MIN_PORT || 20000),
      rtcMaxPort: Number(process.env.MEDIASOUP_MAX_PORT || 29999),
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
          ip: process.env.MEDIASOUP_LISTEN_IP || '0.0.0.0',
          announcedIp: process.env.MEDIASOUP_ANNOUNCED_IP || undefined
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

