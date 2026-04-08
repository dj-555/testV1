# Live Class Architecture Guide

This project is a teacher-and-student live class app built on top of:

- Flutter on the client
- Socket.IO for signaling
- mediasoup as the SFU on the server
- WebRTC transports for audio and video

The app is now split so the entrypoint stays small and the live-class feature is easier to follow.

## 1. File Layout

Client:

- `client/lib/main.dart`
  Starts Flutter, locks portrait mode, and runs the app.
- `client/lib/app.dart`
  Creates `QuranLiveClassApp`.
- `client/lib/features/live_class/presentation/quran_live_class_page.dart`
  Main page state, renderer lifecycle, queue actions, and screen composition.
- `client/lib/features/live_class/presentation/widgets/connection_card.dart`
  Server URL, role, name, and connect/disconnect UI.
- `client/lib/features/live_class/presentation/widgets/teacher_queue_card.dart`
  Teacher queue controls.
- `client/lib/features/live_class/presentation/widgets/student_queue_card.dart`
  Student request/queue state UI.
- `client/lib/features/live_class/presentation/widgets/streams_layout.dart`
  Video layout, PiP behavior, rotation handling, and stream surfaces.
- `client/lib/signaling.dart`
  Socket.IO wrapper with ack-based requests.
- `client/lib/webrtc_client.dart`
  The client-side signaling and mediasoup orchestration layer.

Server:

- `server/index.js`
  HTTP server, Socket.IO, and event routing.
- `server/room.js`
  Room state, queue logic, transports, producers, consumers, and turn control.
- `server/mediasoup.js`
  Worker/router creation and transport-level logging.
- `server/config.js`
  mediasoup transport config and env parsing.
- `server/.env`
  Runtime networking settings.

## 2. End-to-End Flow

### Step 1: The app connects to the signaling server

1. The Flutter page calls `WebRtcClient.connect()`.
2. `client/lib/signaling.dart` opens a Socket.IO websocket.
3. The client sends `joinRoom` with:
   - role: `teacher` or `student`
   - name: display name

### Step 2: The server registers the peer

1. `server/index.js` forwards `joinRoom` to `Room.joinPeer()`.
2. `server/room.js` stores the peer in memory.
3. The server sends back:
   - `peerId`
   - router RTP capabilities
   - current peers
   - current queue
   - teacher producer state
   - active student producer state

Important queue rule now:

- Students are not auto-added to the queue when they connect.
- A student must explicitly ask for a turn with `joinQueue`.
- After a turn ends, that student is not auto-requeued.

## 3. How Media Starts

### Teacher media

1. The client creates a recv transport first.
2. If the role is `teacher`, it also creates a send transport.
3. The teacher opens camera/mic with `getUserMedia`.
4. The teacher produces audio and video to mediasoup.
5. The server stores those producers in `teacherProducers`.

### Student media

1. A student connects in listen mode only.
2. The student consumes teacher media through the recv transport.
3. The student only creates a send transport after the teacher approves the turn.

## 4. Queue and Turn Logic

### Student request flow

1. Student taps `Ask To Talk`.
2. The client sends `joinQueue`.
3. `server/room.js` marks `wantsQueue = true` and puts that student into `studentQueue`.
4. The teacher sees the queue update immediately.

### Teacher approval flow

1. Teacher taps `Approve First` for the first approval in the session.
2. After at least one approval, the button label changes to `Next`.
3. The server approves only the first queued student.
4. The approved student receives `turnApproved`.
5. That student creates a send transport if needed and starts producing audio/video.

### Turn ending flow

1. Teacher taps `End Turn`, or approving another student replaces the current one.
2. `server/room.js` clears `activeStudentId`.
3. The active student producers are closed.
4. The student receives `turnEnded`.
5. The student goes back to listen mode.
6. The student is not placed back into the queue automatically.

That means the same student cannot immediately jump back into a call unless:

- the student asks again
- the teacher approves again

## 5. Why mediasoup Works Here

This app is using mediasoup as an SFU, not peer-to-peer calling.

That means:

- every client sends media to the server
- every client receives media from the server
- students are not directly connected to each other

This is why the server networking setup matters so much.

## 6. STUN, TURN, and ICE in This Project

Current reality in this repo:

- There is no external TURN server configured.
- mediasoup creates WebRTC transports and returns ICE parameters/candidates to the clients.
- The server is effectively the media relay point.

So when people say "STUN/TURN" here, the important practical part is:

- the client must be able to reach the mediasoup transport candidates
- the server must announce the correct public IP
- the media port range must be open

I also added transport ICE restart recovery:

- if a mediasoup transport goes `disconnected` or `failed`, the Flutter client now requests `restartIce`
- the server generates fresh ICE parameters
- the client restarts ICE on that transport

This helps with flaky network paths and can recover some frozen or half-broken sessions without forcing a full reconnect.

## 7. Port Management

There are two main networking layers:

### Signaling

- Port: `3000`
- Used by: HTTP health endpoints and Socket.IO signaling
- Config source: `server/.env` -> `PORT=3000`

### Media

- Port range: `20000-29999`
- Used by: mediasoup WebRTC transports
- Config source:
  - `MEDIASOUP_MIN_PORT=20000`
  - `MEDIASOUP_MAX_PORT=29999`

For real devices, the server must allow:

- TCP `3000`
- UDP `20000-29999`
- TCP `20000-29999` if TCP fallback is enabled

## 8. Announced IP

In `server/.env`:

- `MEDIASOUP_LISTEN_IP=0.0.0.0`
- `MEDIASOUP_ANNOUNCED_IP=62.171.178.72`

Meaning:

- mediasoup listens on all local interfaces
- clients are told to connect to the public IP `62.171.178.72`

If `MEDIASOUP_ANNOUNCED_IP` is wrong, remote devices may connect to signaling but fail to get audio/video.

## 9. Same-WiFi Problem Notes

When two students are on the same WiFi and one of them fails to join media, the usual causes are:

1. Wrong announced public IP
2. Firewall/security group not opening the full mediasoup port range
3. A bad ICE path that never recovers
4. UDP issues on the network path

The changes in this refactor help by:

- keeping remote streams more stable on the Flutter side
- adding ICE restart recovery
- exposing TCP/UDP preference controls in `server/.env`

Relevant env options now supported:

- `MEDIASOUP_ENABLE_UDP`
- `MEDIASOUP_ENABLE_TCP`
- `MEDIASOUP_PREFER_UDP`
- `MEDIASOUP_PREFER_TCP`
- `MEDIASOUP_ICE_CONSENT_TIMEOUT`

If the WiFi issue still happens in production, the next deployment check should be:

1. Confirm port range `20000-29999` is open for UDP and TCP on the server firewall/provider.
2. Verify the public IP in `MEDIASOUP_ANNOUNCED_IP`.
3. Temporarily try `MEDIASOUP_PREFER_TCP=true` and `MEDIASOUP_PREFER_UDP=false` to test whether the network path is the problem.
4. If the environment is very restrictive, add a TURN server as a future upgrade path.

## 10. Important Socket Events

Client -> Server:

- `joinRoom`
- `createTransport`
- `connectTransport`
- `restartIce`
- `produce`
- `consume`
- `resumeConsumer`
- `closeProducer`
- `joinQueue`
- `leaveQueue`
- `approveTurn`
- `endTurn`

Server -> Client:

- `newProducer`
- `producerClosed`
- `consumerClosed`
- `peersUpdate`
- `queueUpdate`
- `turnApproved`
- `turnEnded`
- `activeStudentChanged`
- `teacherDisconnected`

## 11. Quick Mental Model

If you want the shortest way to reason about the app, think of it like this:

1. Socket.IO chooses who is allowed to do what.
2. mediasoup creates one recv transport for everyone.
3. Teachers always send media.
4. Students only send media while approved.
5. Queue membership is now explicit and request-based.
6. The server is the media hub, so public IP and port range correctness are critical.
