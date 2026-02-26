const express = require('express');
const http = require('http');
const cors = require('cors');
const os = require('os');
const { Server } = require('socket.io');

const config = require('./config');
const { createMediasoupWorkerAndRouter, getWorker } = require('./mediasoup');
const Room = require('./room');

function log(event, payload) {
  const timestamp = new Date().toISOString();
  if (payload !== undefined) {
    console.log(`[${timestamp}] [server] ${event}`, payload);
    return;
  }
  console.log(`[${timestamp}] [server] ${event}`);
}

function ackOk(ack, data = {}) {
  if (typeof ack === 'function') {
    ack({ ok: true, data });
  }
}

function ackError(ack, error) {
  const message = error instanceof Error ? error.message : String(error);
  if (typeof ack === 'function') {
    ack({ ok: false, error: message });
  }
}

function errorPayload(error) {
  if (error instanceof Error) {
    return {
      message: error.message,
      stack: config.debugLogs ? error.stack : undefined
    };
  }
  return { message: String(error) };
}

function normalizeIp(ip) {
  if (!ip) return '';
  return String(ip).trim().replace(/^::ffff:/, '');
}

function getForwardedIp(forwardedHeaderValue) {
  if (!forwardedHeaderValue) return '';
  const first = String(forwardedHeaderValue).split(',')[0];
  return normalizeIp(first);
}

function getClientIpFromRequest(req) {
  const forwardedIp = config.trustProxy ? getForwardedIp(req.headers['x-forwarded-for']) : '';
  const socketIp = normalizeIp(req.socket?.remoteAddress);
  return forwardedIp || socketIp || '';
}

function getClientIpFromSocket(socket) {
  const forwardedIp = config.trustProxy
    ? getForwardedIp(socket.handshake.headers?.['x-forwarded-for'])
    : '';
  const handshakeIp = normalizeIp(socket.handshake.address);
  return forwardedIp || handshakeIp || '';
}

function isOriginAllowed(origin) {
  if (config.allowAnyCorsOrigin) {
    return true;
  }

  if (!origin) {
    return !config.requireOrigin;
  }

  return config.corsOrigins.includes(origin);
}

function isClientIpAllowed(clientIp) {
  if (!config.allowedClientIps.length) {
    return true;
  }

  return config.allowedClientIps.includes(normalizeIp(clientIp));
}

function validateIncomingConnection({ origin, clientIp }) {
  if (!isOriginAllowed(origin)) {
    return { ok: false, reason: `Origin not allowed: ${origin || 'none'}` };
  }

  if (!isClientIpAllowed(clientIp)) {
    return { ok: false, reason: `Client IP not allowed: ${clientIp || 'unknown'}` };
  }

  return { ok: true };
}

function validateSocketSecret(socket) {
  if (!config.socketSharedSecret) {
    return { ok: true };
  }

  const token =
    socket.handshake.auth?.token ||
    socket.handshake.headers['x-socket-token'] ||
    socket.handshake.query?.token;

  if (token !== config.socketSharedSecret) {
    return { ok: false, reason: 'Invalid socket shared secret' };
  }

  return { ok: true };
}

function getLocalInterfaceAddresses() {
  const addresses = [];
  const networkInterfaces = os.networkInterfaces();

  for (const [interfaceName, records] of Object.entries(networkInterfaces)) {
    for (const record of records || []) {
      if (record.internal) continue;
      addresses.push({
        interface: interfaceName,
        family: record.family,
        address: record.address
      });
    }
  }

  return addresses;
}

async function bootstrap() {
  const app = express();
  app.set('trust proxy', config.trustProxy ? 1 : false);
  app.use(cors({ origin: config.corsOrigin }));
  app.use(express.json());
  app.use((req, res, next) => {
    const clientIp = getClientIpFromRequest(req);
    const origin = req.headers.origin;
    const validation = validateIncomingConnection({ origin, clientIp });

    if (!validation.ok) {
      log('HTTP request rejected', {
        reason: validation.reason,
        method: req.method,
        path: req.originalUrl,
        origin: origin || null,
        clientIp
      });
      return res.status(403).json({ ok: false, error: 'Forbidden' });
    }

    return next();
  });

  const httpServer = http.createServer(app);
  httpServer.on('error', (error) => {
    log('HTTP server error', errorPayload(error));
  });

  const io = new Server(httpServer, {
    cors: {
      origin: config.corsOrigin,
      methods: ['GET', 'POST']
    },
    transports: ['websocket', 'polling'],
    allowRequest: (req, callback) => {
      const clientIp = getClientIpFromRequest(req);
      const origin = req.headers.origin;
      const validation = validateIncomingConnection({ origin, clientIp });

      if (!validation.ok) {
        log('Socket handshake rejected', {
          reason: validation.reason,
          origin: origin || null,
          clientIp
        });
        callback(validation.reason, false);
        return;
      }

      callback(null, true);
    }
  });

  io.use((socket, next) => {
    const secretValidation = validateSocketSecret(socket);
    if (!secretValidation.ok) {
      log('Socket auth rejected', {
        socketId: socket.id,
        clientIp: getClientIpFromSocket(socket),
        reason: secretValidation.reason
      });
      next(new Error('Unauthorized'));
      return;
    }

    next();
  });

  io.engine.on('connection_error', (error) => {
    log('Socket engine connection error', {
      message: error.message,
      code: error.code
    });
  });

  const { worker, router } = await createMediasoupWorkerAndRouter();
  const room = new Room({ router, io });

  app.get('/health', (req, res) => {
    res.json({
      ...room.getHealth(),
      workerPid: worker.pid
    });
  });

  app.get('/peers', (req, res) => {
    res.json(room.getPeersForApi());
  });

  app.get('/teacherProducers', (req, res) => {
    res.json(room.getTeacherProducersState());
  });

  app.get('/activeStudent', (req, res) => {
    res.json(room.getActiveStudentState());
  });

  app.get('/queue', (req, res) => {
    res.json(room.getQueueState());
  });

  app.use((error, req, res, next) => {
    log('Express error', {
      method: req.method,
      path: req.originalUrl,
      error: errorPayload(error)
    });

    if (res.headersSent) {
      return next(error);
    }

    return res.status(500).json({
      ok: false,
      error: 'Internal server error'
    });
  });

  io.on('connection', (socket) => {
    log('socket connected', {
      socketId: socket.id,
      from: getClientIpFromSocket(socket),
      origin: socket.handshake.headers.origin || null
    });

    socket.on('error', (error) => {
      log('socket error', {
        socketId: socket.id,
        error: errorPayload(error)
      });
    });

    socket.on('joinRoom', async (payload = {}, ack) => {
      log('joinRoom', { socketId: socket.id, payload });
      try {
        const data = await room.joinPeer(socket, payload);
        ackOk(ack, data);
      } catch (error) {
        log('joinRoom error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('createTransport', async (payload = {}, ack) => {
      log('createTransport', { socketId: socket.id, payload });
      try {
        const data = await room.createTransport(socket.id, payload.direction);
        ackOk(ack, data);
      } catch (error) {
        log('createTransport error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('connectTransport', async (payload = {}, ack) => {
      log('connectTransport', { socketId: socket.id, payload });
      try {
        await room.connectTransport(socket.id, payload.transportId, payload.dtlsParameters);
        ackOk(ack, { connected: true });
      } catch (error) {
        log('connectTransport error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('produce', async (payload = {}, ack) => {
      log('produce', { socketId: socket.id, payloadSummary: { transportId: payload.transportId, kind: payload.kind } });
      try {
        const data = await room.produce(
          socket.id,
          payload.transportId,
          payload.kind,
          payload.rtpParameters,
          payload.appData
        );
        ackOk(ack, data);
      } catch (error) {
        log('produce error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('consume', async (payload = {}, ack) => {
      log('consume', { socketId: socket.id, payloadSummary: { transportId: payload.transportId, producerId: payload.producerId } });
      try {
        const data = await room.consume(
          socket.id,
          payload.transportId,
          payload.producerId,
          payload.rtpCapabilities
        );
        ackOk(ack, data);
      } catch (error) {
        log('consume error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('resumeConsumer', async (payload = {}, ack) => {
      log('resumeConsumer', { socketId: socket.id, payload });
      try {
        await room.resumeConsumer(socket.id, payload.consumerId);
        ackOk(ack, { resumed: true });
      } catch (error) {
        log('resumeConsumer error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('closeProducer', async (payload = {}, ack) => {
      log('closeProducer', { socketId: socket.id, payload });
      try {
        await room.closeProducer(socket.id, payload.producerId, { emit: true, shouldClose: true });
        ackOk(ack, { closed: true });
      } catch (error) {
        log('closeProducer error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('approveTurn', async (payload = {}, ack) => {
      log('approveTurn', { socketId: socket.id, payload });
      try {
        const data = await room.approveTurn(socket.id, payload.studentId);
        ackOk(ack, data);
      } catch (error) {
        log('approveTurn error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('endTurn', async (payload = {}, ack) => {
      log('endTurn', { socketId: socket.id, payload });
      try {
        const data = await room.endTurn(socket.id, payload.reason || 'ended_by_teacher');
        ackOk(ack, data);
      } catch (error) {
        log('endTurn error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('joinQueue', async (payload = {}, ack) => {
      log('joinQueue', { socketId: socket.id, payload });
      try {
        const data = await room.joinQueue(socket.id);
        ackOk(ack, data);
      } catch (error) {
        log('joinQueue error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('leaveQueue', async (payload = {}, ack) => {
      log('leaveQueue', { socketId: socket.id, payload });
      try {
        const data = await room.leaveQueue(socket.id);
        ackOk(ack, data);
      } catch (error) {
        log('leaveQueue error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('disconnect', async (reason) => {
      log('socket disconnected', { socketId: socket.id, reason });
      try {
        await room.removePeer(socket.id);
      } catch (error) {
        log('disconnect cleanup error', { socketId: socket.id, error: error.message });
      }
    });
  });

  httpServer.listen(config.httpPort, config.httpHost, () => {
    const address = httpServer.address();
    const bindAddress =
      typeof address === 'string' ? address : `${address.address}:${address.port}`;

    log('HTTP + Socket.IO listening', {
      bindAddress,
      host: config.httpHost,
      port: config.httpPort
    });

    log('mediasoup bind configuration', {
      listenIps: config.mediasoup.webRtcTransport.listenIps,
      rtcPortRange: `${config.mediasoup.worker.rtcMinPort}-${config.mediasoup.worker.rtcMaxPort}`
    });

    if (config.debugLogs) {
      log('local network interfaces', getLocalInterfaceAddresses());
      log('incoming connection rules', {
        requireOrigin: config.requireOrigin,
        allowAnyCorsOrigin: config.allowAnyCorsOrigin,
        allowedClientIps: config.allowedClientIps,
        tokenProtection: Boolean(config.socketSharedSecret)
      });
    }

    if (!config.mediasoup.webRtcTransport.listenIps[0].announcedIp) {
      log('MEDIASOUP_ANNOUNCED_IP is empty; internet clients usually require your public server IP');
    }
  });

  let shuttingDown = false;

  const shutdown = async (signal) => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;

    log(`Received ${signal}, shutting down gracefully...`);
    const forceExitTimer = setTimeout(() => {
      log('Shutdown timeout reached, forcing exit');
      process.exit(1);
    }, 10_000);
    forceExitTimer.unref();

    try {
      io.close();
      await new Promise((resolve) => {
        httpServer.close(() => resolve());
      });

      const mediasoupWorker = getWorker();
      if (mediasoupWorker && !mediasoupWorker.closed) {
        mediasoupWorker.close();
      }

      clearTimeout(forceExitTimer);
      log('Shutdown complete');
      process.exit(0);
    } catch (error) {
      clearTimeout(forceExitTimer);
      log('Shutdown error', errorPayload(error));
      process.exit(1);
    }
  };

  process.on('SIGINT', () => {
    shutdown('SIGINT').catch((error) => {
      log('SIGINT shutdown failure', errorPayload(error));
      process.exit(1);
    });
  });

  process.on('SIGTERM', () => {
    shutdown('SIGTERM').catch((error) => {
      log('SIGTERM shutdown failure', errorPayload(error));
      process.exit(1);
    });
  });

  process.on('unhandledRejection', (reason) => {
    log('Unhandled promise rejection', reason instanceof Error ? errorPayload(reason) : { reason });
  });

  process.on('uncaughtException', (error) => {
    log('Uncaught exception', errorPayload(error));
    shutdown('uncaughtException').catch(() => {
      process.exit(1);
    });
  });

  return { app, io, room, worker: getWorker() };
}

bootstrap().catch((error) => {
  log('Fatal bootstrap error', errorPayload(error));
  process.exit(1);
});
