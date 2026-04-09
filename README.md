# Quran Live Class

Realtime Quran class platform with:

- Flutter mobile client (`teacher` and `student` roles)
- Node.js signaling/API server (Express + Socket.IO)
- mediasoup SFU for WebRTC media routing
- Queue + turn-based speaking control with re-entry approval

## Tech Stack

- Client: Flutter, `flutter_webrtc`, `socket_io_client`, `mediasoup_client_flutter`
- Server: Node.js, Express, Socket.IO, mediasoup
- Network/Media: WebRTC, ICE, STUN/TURN, DTLS, SRTP, RTP
- Video codecs: VP8, H264
- Audio codec: Opus

## Repository Structure

```text
.
|- client/
|  \- lib/
|     |- main.dart
|     |- app.dart
|     |- quran_live_class_page.dart
|     |- signaling.dart
|     |- webrtc_client.dart
|     \- widgets/
|        |- quran_live_class_page_shared_widgets.dart
|        |- quran_live_class_page_connection_widgets.dart
|        |- quran_live_class_page_teacher_widgets.dart
|        |- quran_live_class_page_student_widgets.dart
|        |- quran_live_class_page_stream_widgets.dart
|        \- quran_live_class_page_video_utils.dart
\- server/
   |- index.js
   |- room.js
   |- mediasoup.js
   |- config.js
   |- package.json
   \- nginx_quran_socketio.conf
```

## Core Flow (Teacher + Student)

1. Client connects to Socket.IO signaling.
2. Client calls `joinRoom` with role and display name.
3. Client loads mediasoup `Device` from router RTP capabilities.
4. Client creates recv transport and connects DTLS.
5. Teacher also creates send transport, starts local media, and calls `produce`.
6. Peers receive `newProducer`, then `consume` + `resumeConsumer`.
7. Queue flow:
   - Student `joinQueue`
   - Teacher `approveTurn`
   - Teacher `endTurn`
   - Student can request `requestQueueReentry`
   - Teacher approves with `approveQueueReentry`
8. On disconnect/reconnect, client rebuilds transports/consumers and syncs room state.

## File Responsibilities

- `client/lib/main.dart`: app entry + portrait lock
- `client/lib/app.dart`: `MaterialApp` setup
- `client/lib/quran_live_class_page.dart`: main page/state wiring
- `client/lib/signaling.dart`: Socket.IO connection, retries, request/ack wrapper
- `client/lib/webrtc_client.dart`: WebRTC/mediasoup logic (join/setup/produce/consume/recovery)
- `server/index.js`: server bootstrap, REST endpoints, socket event handlers
- `server/room.js`: room state, queue/re-entry rules, producer/consumer lifecycle
- `server/mediasoup.js`: worker/router/transport creation
- `server/config.js`: all env-driven config (HTTPS, TURN/STUN, ICE, codecs, ports)

## Signaling Events Used

Client requests:

- `joinRoom`
- `createTransport`
- `connectTransport`
- `produce`
- `consume`
- `resumeConsumer`
- `closeProducer`
- `joinQueue`
- `leaveQueue`
- `requestQueueReentry`
- `approveQueueReentry`
- `approveTurn`
- `endTurn`

Server push events:

- `newProducer`
- `producerClosed`
- `consumerClosed`
- `turnApproved`
- `turnEnded`
- `peersUpdate`
- `queueUpdate`
- `activeStudentChanged`
- `teacherDisconnected`
- `queueReentryApproved`

## HTTP API Endpoints (Server)

- `GET /health`
- `GET /peers`
- `GET /teacherProducers`
- `GET /activeStudent`
- `GET /queue`

## Protocols Explained (Short)

- `WSS` (WebSocket Secure): encrypted signaling channel
- `ICE`: connectivity checks and candidate selection
- `STUN`: discover public address through NAT
- `TURN`: relay media when direct peer path fails
- `DTLS`: secure key exchange on WebRTC transport
- `SRTP`: encrypted audio/video packets
- `RTP`: media packet format/transport

## Prerequisites

- Flutter SDK
- Android SDK (for Android builds)
- Node.js 20+ (recommended)
- Open UDP range for mediasoup (default: `20000-29999`)

## Run Server

```bash
cd server
npm install
npm start
```

Default server port is `3000`.

### Environment Variables (`server/.env`)

Common keys:

- `PORT` (default `3000`)
- `SOCKET_IO_PATH` (default `/socket.io`)
- `HTTPS_ENABLED`, `HTTPS_PORT`, `HTTPS_KEY_PATH`, `HTTPS_CERT_PATH`
- `HTTP_REDIRECT_TO_HTTPS`, `HTTPS_PUBLIC_HOST`
- `CORS_ORIGIN`
- `MEDIASOUP_LISTEN_IP`, `MEDIASOUP_ANNOUNCED_IP`
- `MEDIASOUP_MIN_PORT`, `MEDIASOUP_MAX_PORT`
- `TURN_ENABLED`, `TURN_HOST`, `TURN_PORT`, `TURN_TLS_PORT`
- `TURN_USERNAME`, `TURN_PASSWORD`
- `TURN_STATIC_AUTH_SECRET`, `TURN_REALM`, `TURN_CREDENTIAL_TTL_SEC`
- `WEBRTC_FORCE_RELAY`, `WEBRTC_ICE_POLICY`

## Run Flutter Client

```bash
cd client
flutter pub get
flutter run \
  --dart-define=APP_SERVER_URL=https://your-domain-or-ip \
  --dart-define=APP_SOCKET_PATH=/quran-socket.io
```

If `--dart-define` is not provided, the app uses defaults from `quran_live_class_page.dart`.

## Nginx Reverse Proxy (Optional)

An example config is provided in:

- `server/nginx_quran_socketio.conf`

It proxies:

- `/quran-socket.io/` -> Node server socket path
- `/quran-health` -> `/health`

## Troubleshooting

- Connection timeout:
  - Verify `APP_SERVER_URL`, socket path, and CORS settings.
- Media not flowing:
  - Check UDP ports (`MEDIASOUP_MIN_PORT..MAX_PORT`) and TURN config.
- Mobile devices cannot connect across network:
  - Set `MEDIASOUP_ANNOUNCED_IP` to your public/LAN reachable IP.
- Strict networks/firewalls:
  - Enable TURN and optionally force relay (`WEBRTC_FORCE_RELAY=true`).

---

This README is aligned with the current implementation in `client/lib` and `server/`.
