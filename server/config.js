function boolFromEnv(name, fallback) {
  const value = process.env[name];
  if (value == null) {
    return fallback;
  }

  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

const config = {
  httpPort: Number(process.env.PORT || 3000),
  corsOrigin: process.env.CORS_ORIGIN || '*',
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
      enableUdp: boolFromEnv('MEDIASOUP_ENABLE_UDP', true),
      enableTcp: boolFromEnv('MEDIASOUP_ENABLE_TCP', true),
      preferUdp: boolFromEnv('MEDIASOUP_PREFER_UDP', true),
      preferTcp: boolFromEnv('MEDIASOUP_PREFER_TCP', false),
      iceConsentTimeout: Number(process.env.MEDIASOUP_ICE_CONSENT_TIMEOUT || 30),
      initialAvailableOutgoingBitrate: 1_000_000,
      maxIncomingBitrate: 1_500_000
    }
  }
};

module.exports = config;
