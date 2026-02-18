const mediasoup = require('mediasoup');
const config = require('./config');

let worker;
let router;

function log(message, extra) {
  const timestamp = new Date().toISOString();
  if (extra !== undefined) {
    console.log(`[${timestamp}] [mediasoup] ${message}`, extra);
    return;
  }
  console.log(`[${timestamp}] [mediasoup] ${message}`);
}

async function createMediasoupWorkerAndRouter() {
  worker = await mediasoup.createWorker(config.mediasoup.worker);

  worker.on('died', () => {
    log('Worker died, exiting in 2 seconds...');
    setTimeout(() => process.exit(1), 2000);
  });

  router = await worker.createRouter(config.mediasoup.router);

  log(`Worker created (pid=${worker.pid})`);
  log('Router created with codecs', config.mediasoup.router.mediaCodecs.map((c) => c.mimeType));

  return { worker, router };
}

async function createWebRtcTransport(routerInstance) {
  const transport = await routerInstance.createWebRtcTransport(config.mediasoup.webRtcTransport);

  if (config.mediasoup.webRtcTransport.maxIncomingBitrate) {
    try {
      await transport.setMaxIncomingBitrate(config.mediasoup.webRtcTransport.maxIncomingBitrate);
    } catch (error) {
      log('setMaxIncomingBitrate failed', error.message);
    }
  }

  transport.on('dtlsstatechange', (dtlsState) => {
    log(`Transport ${transport.id} dtlsstatechange=${dtlsState}`);
    if (dtlsState === 'closed') {
      transport.close();
    }
  });

  transport.on('close', () => {
    log(`Transport ${transport.id} closed`);
  });

  return transport;
}

function getWorker() {
  return worker;
}

function getRouter() {
  return router;
}

module.exports = {
  createMediasoupWorkerAndRouter,
  createWebRtcTransport,
  getWorker,
  getRouter
};
