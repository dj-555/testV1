require('dotenv').config();

const express = require('express');
const fs = require('fs');
const http = require('http');
const https = require('https');
const cors = require('cors');
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

function createPrimaryServer(app) {
  if (!config.httpsEnabled) {
    return {
      server: http.createServer(app),
      scheme: 'http',
      port: config.httpPort
    };
  }

  if (!config.httpsKeyPath || !config.httpsCertPath) {
    throw new Error(
      'HTTPS_ENABLED is true, but HTTPS_KEY_PATH or HTTPS_CERT_PATH is missing in .env'
    );
  }

  const tlsOptions = {
    key: fs.readFileSync(config.httpsKeyPath),
    cert: fs.readFileSync(config.httpsCertPath)
  };

  return {
    server: https.createServer(tlsOptions, app),
    scheme: 'https',
    port: config.httpsPort
  };
}

function createHttpRedirectServer() {
  if (!config.httpsEnabled || !config.redirectHttpToHttps) {
    return null;
  }

  const redirectApp = express();
  redirectApp.use((req, res) => {
    const hostHeader = String(req.headers.host || '').trim();
    const hostWithoutPort = hostHeader.split(':')[0] || '';
    const configuredHost = String(config.httpsPublicHost || '').trim();
    const targetHost = configuredHost || hostWithoutPort;
    const targetPort = Number(config.httpsPort) || 443;
    const explicitPort = targetPort === 443 ? '' : `:${targetPort}`;
    const originalUrl = req.originalUrl || req.url || '/';

    const redirectTo = `https://${targetHost}${explicitPort}${originalUrl}`;
    res.redirect(308, redirectTo);
  });

  return http.createServer(redirectApp);
}

async function bootstrap() {
  const app = express();
  app.use(cors({ origin: config.corsOrigin }));
  app.use(express.json());

  const primary = createPrimaryServer(app);
  const primaryServer = primary.server;

  const io = new Server(primaryServer, {
    cors: {
      origin: config.corsOrigin,
      methods: ['GET', 'POST']
    },
    transports: ['websocket', 'polling'],
    path: config.socketPath
  });
  io.engine.on('connection_error', (err) => {
    log('engine connection_error', {
      code: err.code,
      message: err.message,
      context: err.context
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

  io.on('connection', (socket) => {
    log('socket connected', {
      socketId: socket.id,
      from: socket.handshake.address
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

    socket.on('requestQueueReentry', async (payload = {}, ack) => {
      log('requestQueueReentry', { socketId: socket.id, payload });
      try {
        const data = await room.requestQueueReentry(socket.id);
        ackOk(ack, data);
      } catch (error) {
        log('requestQueueReentry error', { socketId: socket.id, error: error.message });
        ackError(ack, error);
      }
    });

    socket.on('approveQueueReentry', async (payload = {}, ack) => {
      log('approveQueueReentry', { socketId: socket.id, payload });
      try {
        const data = await room.approveQueueReentry(socket.id, payload.studentId);
        ackOk(ack, data);
      } catch (error) {
        log('approveQueueReentry error', { socketId: socket.id, error: error.message });
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

  const redirectServer = createHttpRedirectServer();

  primaryServer.listen(primary.port, () => {
    const label = primary.scheme.toUpperCase();
    log(`${label} + Socket.IO listening on :${primary.port}`);
    log(`Socket.IO path: ${config.socketPath}`);
    log('Set MEDIASOUP_ANNOUNCED_IP to your machine LAN/WAN IP for real devices');
  });

  if (redirectServer) {
    redirectServer.listen(config.httpPort, () => {
      log(
        `HTTP redirect server listening on :${config.httpPort} -> https:${config.httpsPort}`
      );
    });
  }

  const shutdown = async (signal) => {
    log(`Received ${signal}, shutting down...`);
    io.close();
    primaryServer.close(() => {
      log('Primary server closed');
      if (redirectServer) {
        redirectServer.close(() => {
          log('HTTP redirect server closed');
          process.exit(0);
        });
        return;
      }
      process.exit(0);
    });
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  return { app, io, room, worker: getWorker() };
}

bootstrap().catch((error) => {
  log('Fatal bootstrap error', error);
  process.exit(1);
});
