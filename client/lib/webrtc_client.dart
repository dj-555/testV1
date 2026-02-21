import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mediasoup_client_flutter/mediasoup_client_flutter.dart' as ms;
import 'package:permission_handler/permission_handler.dart';

import 'signaling.dart';

class PeerSummary {
  final String id;
  final String role;
  final String name;
  final bool isActiveSpeaker;

  const PeerSummary({
    required this.id,
    required this.role,
    required this.name,
    required this.isActiveSpeaker,
  });

  factory PeerSummary.fromMap(Map<String, dynamic> map) {
    return PeerSummary(
      id: map['id']?.toString() ?? '',
      role: map['role']?.toString() ?? 'student',
      name: map['name']?.toString() ?? 'Unknown',
      isActiveSpeaker: map['isActiveSpeaker'] == true,
    );
  }
}

class QueueEntry {
  final String id;
  final String name;

  const QueueEntry({
    required this.id,
    required this.name,
  });

  factory QueueEntry.fromMap(Map<String, dynamic> map) {
    return QueueEntry(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Student',
    );
  }
}

class WebRtcClient {
  final SignalingClient _signaling;

  WebRtcClient({SignalingClient? signaling})
      : _signaling = signaling ?? SignalingClient() {
    _reconnectSub = _signaling.onReconnectStream.listen((_) async {
      if (_manualDisconnect) return;
      await _handleReconnect();
    });

    _disconnectSub = _signaling.onDisconnectStream.listen((reason) {
      if (_manualDisconnect) {
        connectionState.value = 'disconnected';
      } else {
        connectionState.value = 'reconnecting';
      }
      debugPrint('[webrtc] socket disconnected reason=$reason');
    });
  }

  final ValueNotifier<String> connectionState =
      ValueNotifier<String>('disconnected');
  final ValueNotifier<MediaStream?> localStreamNotifier =
      ValueNotifier<MediaStream?>(null);
  final ValueNotifier<MediaStream?> teacherRemoteStreamNotifier =
      ValueNotifier<MediaStream?>(null);
  final ValueNotifier<MediaStream?> activeStudentRemoteStreamNotifier =
      ValueNotifier<MediaStream?>(null);
  final ValueNotifier<List<PeerSummary>> peersNotifier =
      ValueNotifier<List<PeerSummary>>(<PeerSummary>[]);
  final ValueNotifier<String?> activeStudentIdNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<List<QueueEntry>> queueNotifier =
      ValueNotifier<List<QueueEntry>>(<QueueEntry>[]);

  String _role = 'student';
  String _displayName = 'Student';
  String _serverUrl = '';

  String? _peerId;

  bool _manualDisconnect = false;
  bool _rejoining = false;

  ms.Device? _device;
  ms.Transport? _sendTransport;
  ms.Transport? _recvTransport;

  MediaStream? _localStream;
  MediaStream? _teacherRemoteStream;
  MediaStream? _activeStudentRemoteStream;

  final Map<String, ms.Producer> _localProducersByKind =
      <String, ms.Producer>{};
  final Map<String, ms.Consumer> _consumersById = <String, ms.Consumer>{};
  final Map<String, ms.Consumer> _consumersByProducerId =
      <String, ms.Consumer>{};
  final Map<String, Map<String, dynamic>> _consumerMetaById =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _producerMetaById =
      <String, Map<String, dynamic>>{};

  StreamSubscription<int>? _reconnectSub;
  StreamSubscription<String>? _disconnectSub;
  Future<void> _rebuildRemoteStreamsQueue = Future<void>.value();

  bool get isTeacher => _role == 'teacher';
  String? get peerId => _peerId;

  Future<void> connect({
    required String serverUrl,
    required String role,
    required String displayName,
  }) async {
    if (connectionState.value == 'connecting') {
      return;
    }

    _role = role.toLowerCase() == 'teacher' ? 'teacher' : 'student';
    _displayName = displayName.trim().isEmpty
        ? (_role == 'teacher' ? 'Teacher' : 'Student')
        : displayName.trim();
    _serverUrl = serverUrl.trim();

    _manualDisconnect = false;
    connectionState.value = 'connecting';

    await _resetMediaState(notifyServer: false);

    await _signaling.connect(_serverUrl);
    _registerServerEvents();

    await _joinAndSetup();

    connectionState.value = 'connected';
    debugPrint('[webrtc] connected role=$_role peerId=$_peerId');
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    connectionState.value = 'disconnecting';

    await _resetMediaState(notifyServer: false);
    await _signaling.disconnect();

    _clearStateForUi();
    connectionState.value = 'disconnected';

    debugPrint('[webrtc] disconnected manually');
  }

  Future<void> dispose() async {
    await disconnect();

    await _reconnectSub?.cancel();
    await _disconnectSub?.cancel();

    await _signaling.dispose();

    connectionState.dispose();
    localStreamNotifier.dispose();
    teacherRemoteStreamNotifier.dispose();
    activeStudentRemoteStreamNotifier.dispose();
    peersNotifier.dispose();
    activeStudentIdNotifier.dispose();
    queueNotifier.dispose();
  }

  Future<void> approveTurn([String? studentId]) async {
    if (!isTeacher) {
      throw Exception('Only teacher can approve turns');
    }

    final payload = <String, dynamic>{};
    if (studentId != null && studentId.isNotEmpty) {
      payload['studentId'] = studentId;
    }
    await _signaling.request('approveTurn', payload);

    debugPrint('[webrtc] approveTurn -> ${studentId ?? 'first_in_queue'}');
  }

  Future<void> endTurn() async {
    if (!isTeacher) {
      throw Exception('Only teacher can end turns');
    }

    await _signaling.request('endTurn', const <String, dynamic>{
      'reason': 'ended_by_teacher',
    });

    debugPrint('[webrtc] endTurn sent');
  }

  Future<void> joinQueue() async {
    if (isTeacher) {
      throw Exception('Teacher does not join queue');
    }
    await _signaling.request('joinQueue');
  }

  Future<void> leaveQueue() async {
    if (isTeacher) {
      throw Exception('Teacher does not leave queue');
    }
    await _signaling.request('leaveQueue');
  }

  Future<void> _handleReconnect() async {
    if (_rejoining || _manualDisconnect) return;
    _rejoining = true;

    connectionState.value = 'reconnecting';
    debugPrint('[webrtc] reconnect flow started');

    try {
      await _resetMediaState(notifyServer: false);
      _registerServerEvents();
      await _joinAndSetup();
      connectionState.value = 'connected';
      debugPrint('[webrtc] reconnect flow completed');
    } catch (error) {
      connectionState.value = 'error';
      debugPrint('[webrtc] reconnect failed: $error');
    } finally {
      _rejoining = false;
    }
  }

  Future<void> _joinAndSetup() async {
    final joinResponse = await _signaling.request('joinRoom', <String, dynamic>{
      'role': _role,
      'name': _displayName,
    });

    _peerId = joinResponse['peerId']?.toString();
    activeStudentIdNotifier.value = joinResponse['activeStudentId']?.toString();

    _updatePeers(joinResponse['peers']);
    _absorbServerProducerState(joinResponse);
    final hasQueuePayload = _updateQueue(joinResponse['queue']);
    if (!hasQueuePayload) {
      _rebuildQueueFromPeers();
    }

    await _createDevice(joinResponse['rtpCapabilities']);
    await _createRecvTransport();

    if (isTeacher) {
      await _createSendTransportIfNeeded();
      await _startLocalMediaAndProduce();
      await _ensureActiveStudentConsumers();
    }

    final dynamic producersRaw = joinResponse['producers'];
    if (producersRaw is List) {
      for (final dynamic item in producersRaw) {
        final producerMap = _toMap(item);
        if (producerMap.isNotEmpty) {
          _rememberProducerMeta(producerMap);
          await _consumeProducer(producerMap);
        }
      }
    }
  }

  Future<void> _createDevice(dynamic rtpCapabilitiesRaw) async {
    final rtpCapabilities = _toMap(rtpCapabilitiesRaw);
    if (rtpCapabilities.isEmpty) {
      throw Exception('Invalid router RTP capabilities');
    }

    _device = ms.Device();
    await _device!.load(
      routerRtpCapabilities: ms.RtpCapabilities.fromMap(rtpCapabilities),
    );

    debugPrint('[webrtc] device loaded');
  }

  Future<void> _createRecvTransport() async {
    final response =
        await _signaling.request('createTransport', const <String, dynamic>{
      'direction': 'recv',
    });

    _recvTransport = _device!.createRecvTransportFromMap(
      response,
      consumerCallback: _onConsumerCreated,
    );

    _recvTransport!.on('connect', (dynamic data) async {
      await _onTransportConnect(_recvTransport!, _toMap(data));
    });

    _recvTransport!.on('connectionstatechange', (dynamic state) {
      debugPrint('[webrtc] recvTransport state=$state');
    });

    debugPrint('[webrtc] recv transport created id=${_recvTransport!.id}');
  }

  Future<void> _createSendTransportIfNeeded() async {
    if (_sendTransport != null) return;

    final response =
        await _signaling.request('createTransport', const <String, dynamic>{
      'direction': 'send',
    });

    _sendTransport = _device!.createSendTransportFromMap(
      response,
      producerCallback: _onProducerCreated,
    );

    _sendTransport!.on('connect', (dynamic data) async {
      await _onTransportConnect(_sendTransport!, _toMap(data));
    });

    _sendTransport!.on('produce', (dynamic data) async {
      await _onTransportProduce(_toMap(data));
    });

    _sendTransport!.on('connectionstatechange', (dynamic state) {
      debugPrint('[webrtc] sendTransport state=$state');
    });

    debugPrint('[webrtc] send transport created id=${_sendTransport!.id}');
  }

  Future<void> _onTransportConnect(
      ms.Transport transport, Map<String, dynamic> data) async {
    final dynamic callback = data['callback'];
    final dynamic errback = data['errback'];

    try {
      final dynamic dtlsRaw = data['dtlsParameters'];
      final Map<String, dynamic> dtlsParameters = _extractMap(dtlsRaw);

      await _signaling.request('connectTransport', <String, dynamic>{
        'transportId': transport.id,
        'dtlsParameters': dtlsParameters,
      });

      if (callback is Function) {
        callback();
      }
    } catch (error) {
      debugPrint('[webrtc] connectTransport failed: $error');
      if (errback is Function) {
        errback(error.toString());
      }
    }
  }

  Future<void> _onTransportProduce(Map<String, dynamic> data) async {
    final dynamic callback = data['callback'];
    final dynamic errback = data['errback'];

    try {
      final String kind = _normalizeKind(data['kind']);
      final Map<String, dynamic> rtpParameters =
          _extractMap(data['rtpParameters']);

      final response = await _signaling.request('produce', <String, dynamic>{
        'transportId': _sendTransport!.id,
        'kind': kind,
        'rtpParameters': rtpParameters,
        'appData': <String, dynamic>{
          'displayName': _displayName,
          'source': _role == 'teacher' ? 'teacher' : 'activeStudent',
        },
      });

      if (callback is Function) {
        callback(response['id']);
      }

      debugPrint('[webrtc] produce ack id=${response['id']} kind=$kind');
    } catch (error) {
      debugPrint('[webrtc] produce failed: $error');
      if (errback is Function) {
        errback(error.toString());
      }
    }
  }

  void _onProducerCreated(ms.Producer producer) {
    final String kind = _normalizeKind(producer.kind);
    _localProducersByKind[kind] = producer;

    debugPrint('[webrtc] local producer created id=${producer.id} kind=$kind');
  }

  Future<void> _startLocalMediaAndProduce() async {
    if (_sendTransport == null) {
      throw Exception('Send transport is not ready');
    }

    if (_localStream != null) {
      debugPrint('[webrtc] local stream already active');
      return;
    }

    final permissionsOk = await _ensureMediaPermissions();
    if (!permissionsOk) {
      throw Exception('Camera/Microphone permission denied');
    }

    final isStudent = _role == 'student';
    final legacyConstraints = <String, dynamic>{
      'audio': true,
      'video': <String, dynamic>{
        'facingMode': 'user',
        'mandatory': <String, dynamic>{
          'minWidth': isStudent ? '320' : '640',
          'minHeight': isStudent ? '180' : '360',
          'maxWidth': isStudent ? '320' : '640',
          'maxHeight': isStudent ? '180' : '360',
          'minFrameRate': isStudent ? '10' : '15',
          'maxFrameRate': isStudent ? '12' : '24',
        },
        'optional': <dynamic>[],
      },
    };

    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(legacyConstraints);
    } catch (error) {
      debugPrint('[webrtc] getUserMedia legacy constraints failed: $error');

      final fallbackConstraints = <String, dynamic>{
        'audio': true,
        'video': true,
      };
      _localStream =
          await navigator.mediaDevices.getUserMedia(fallbackConstraints);
    }

    if (_localStream == null) {
      throw Exception('Unable to open local media stream');
    }

    localStreamNotifier.value = _localStream;

    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isNotEmpty && !_localProducersByKind.containsKey('audio')) {
      _sendTransport!.produce(
        track: audioTracks.first,
        stream: _localStream!,
        stopTracks: false,
        source: 'microphone',
      );
    }

    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty && !_localProducersByKind.containsKey('video')) {
      _sendTransport!.produce(
        track: videoTracks.first,
        stream: _localStream!,
        stopTracks: false,
        source: 'webcam',
      );
    }

    debugPrint('[webrtc] local media started and produce requested');
  }

  Future<bool> _ensureMediaPermissions() async {
    final statuses = await <Permission>[
      Permission.camera,
      Permission.microphone,
    ].request();

    final cameraGranted = statuses[Permission.camera]?.isGranted ?? false;
    final micGranted = statuses[Permission.microphone]?.isGranted ?? false;

    return cameraGranted && micGranted;
  }

  Future<void> _consumeProducer(Map<String, dynamic> producerInfo) async {
    if (_recvTransport == null || _device == null) return;

    _rememberProducerMeta(producerInfo);

    final producerId = producerInfo['producerId']?.toString();
    final producerPeerId = producerInfo['peerId']?.toString();
    final producerRole = _normalizeRole(producerInfo['role']);
    final producerSource = _normalizeSource(producerInfo['source']);

    if (producerId == null || producerPeerId == null) return;
    if (producerPeerId == _peerId) return;
    final isTeacherProducer =
        producerSource == 'teacher' || producerRole == 'teacher';
    final activePeerId = activeStudentIdNotifier.value;
    final isActiveStudentProducer =
        producerSource == 'activestudent' || producerRole == 'student';
    final canStudentConsumeActiveStudent = isActiveStudentProducer &&
        activePeerId != null &&
        activePeerId.isNotEmpty &&
        activePeerId != _peerId &&
        producerPeerId == activePeerId;
    if (_role == 'student' &&
        !isTeacherProducer &&
        !canStudentConsumeActiveStudent) {
      return;
    }

    if (_consumersByProducerId.containsKey(producerId)) {
      return;
    }

    try {
      final response = await _signaling.request('consume', <String, dynamic>{
        'transportId': _recvTransport!.id,
        'producerId': producerId,
        'rtpCapabilities': _device!.rtpCapabilities.toMap(),
      });

      final consumerId = response['id']?.toString();
      if (consumerId == null || consumerId.isEmpty) {
        debugPrint(
            '[webrtc] consume failed producerId=$producerId error=missing consumer id');
        return;
      }

      final responseProducerId = response['producerId']?.toString();
      final responsePeerId = response['peerId']?.toString();
      final appData = _normalizeConsumerAppData(
        _toMap(response['appData']),
        fallbackProducerId: responseProducerId ?? producerId,
        fallbackPeerId: responsePeerId ?? producerPeerId,
        fallbackRole: producerInfo['role']?.toString(),
        fallbackSource: producerInfo['source']?.toString(),
      );
      _rememberProducerMeta(
        appData,
        fallbackProducerId: responseProducerId ?? producerId,
      );

      _consumerMetaById[consumerId] = appData;

      final String kind = _normalizeKind(response['kind']);
      final mediaKind = kind == 'audio'
          ? RTCRtpMediaType.RTCRtpMediaTypeAudio
          : RTCRtpMediaType.RTCRtpMediaTypeVideo;

      _recvTransport!.consume(
        id: consumerId,
        producerId: responseProducerId ?? producerId,
        peerId: responsePeerId ?? producerPeerId,
        kind: mediaKind,
        rtpParameters: ms.RtpParameters.fromMap(
          _toMap(response['rtpParameters']),
        ),
        appData: appData,
      );

      await _signaling.request('resumeConsumer', <String, dynamic>{
        'consumerId': consumerId,
      });

      debugPrint('[webrtc] consume success producerId=$producerId');
    } catch (error) {
      debugPrint('[webrtc] consume failed producerId=$producerId error=$error');
    }
  }

  void _onConsumerCreated(ms.Consumer consumer, dynamic _) {
    _consumersById[consumer.id] = consumer;
    _consumersByProducerId[consumer.producerId] = consumer;
    _consumerMetaById[consumer.id] = _normalizeConsumerAppData(
      _consumerMetaById[consumer.id] ?? _toMap(consumer.appData),
      fallbackProducerId: consumer.producerId,
    );
    _rememberProducerMeta(
      _consumerMetaById[consumer.id]!,
      fallbackProducerId: consumer.producerId,
    );

    debugPrint(
        '[webrtc] consumer created id=${consumer.id} producerId=${consumer.producerId}');

    unawaited(_rebuildRemoteStreams());
  }

  Future<void> _rebuildRemoteStreams() {
    _rebuildRemoteStreamsQueue = _rebuildRemoteStreamsQueue.then((_) async {
      try {
        await _rebuildRemoteStreamsInternal();
      } catch (error) {
        debugPrint('[webrtc] rebuildRemoteStreams failed: $error');
      }
    });

    return _rebuildRemoteStreamsQueue;
  }

  Future<void> _rebuildRemoteStreamsInternal() async {
    final teacherConsumers = <ms.Consumer>[];
    final activeStudentConsumers = <ms.Consumer>[];
    int unknownConsumers = 0;

    for (final consumer in _consumersById.values) {
      final appData = _normalizeConsumerAppData(
        _consumerMetaById[consumer.id] ?? _toMap(consumer.appData),
        fallbackProducerId: consumer.producerId,
      );
      _consumerMetaById[consumer.id] = appData;
      _rememberProducerMeta(appData, fallbackProducerId: consumer.producerId);

      final producerMeta =
          _producerMetaById[consumer.producerId] ?? const <String, dynamic>{};

      final source =
          _normalizeSource(producerMeta['source'] ?? appData['source']);
      final role = _normalizeRole(producerMeta['role'] ?? appData['role']);

      if (source == 'teacher' || role == 'teacher') {
        teacherConsumers.add(consumer);
      } else if (source == 'activestudent' || role == 'student') {
        activeStudentConsumers.add(consumer);
      } else {
        unknownConsumers += 1;
      }
    }

    final nextTeacherRemoteStream = await _buildRemoteStream(
      streamId: 'teacher-remote',
      label: 'teacher',
      consumers: teacherConsumers,
    );
    final nextActiveStudentRemoteStream = await _buildRemoteStream(
      streamId: 'active-student-remote',
      label: 'activeStudent',
      consumers: activeStudentConsumers,
    );

    final previousTeacherRemoteStream = _teacherRemoteStream;
    final previousActiveStudentRemoteStream = _activeStudentRemoteStream;

    _teacherRemoteStream = nextTeacherRemoteStream;
    _activeStudentRemoteStream = nextActiveStudentRemoteStream;

    teacherRemoteStreamNotifier.value = _teacherRemoteStream;
    activeStudentRemoteStreamNotifier.value = _activeStudentRemoteStream;

    await _disposeIfDifferent(
      oldStream: previousTeacherRemoteStream,
      newStream: _teacherRemoteStream,
      label: 'teacher',
    );
    await _disposeIfDifferent(
      oldStream: previousActiveStudentRemoteStream,
      newStream: _activeStudentRemoteStream,
      label: 'active student',
    );

    debugPrint(
        '[webrtc] rebuildRemoteStreams teacher=${teacherConsumers.length} activeStudent=${activeStudentConsumers.length} unknown=$unknownConsumers total=${_consumersById.length}');
  }

  Future<MediaStream?> _buildRemoteStream({
    required String streamId,
    required String label,
    required List<ms.Consumer> consumers,
  }) async {
    if (consumers.isEmpty) {
      return null;
    }

    final stream = await createLocalMediaStream(streamId);
    int attachedTracks = 0;

    for (final consumer in consumers) {
      try {
        stream.addTrack(consumer.track);
        attachedTracks += 1;
      } catch (error) {
        debugPrint(
            '[webrtc] addTrack failed while rebuilding $label stream consumerId=${consumer.id} producerId=${consumer.producerId} error=$error');
      }
    }

    if (attachedTracks == 0) {
      await stream.dispose();
      return null;
    }

    return stream;
  }

  Future<void> _disposeIfDifferent({
    required MediaStream? oldStream,
    required MediaStream? newStream,
    required String label,
  }) async {
    if (oldStream == null || identical(oldStream, newStream)) {
      return;
    }

    try {
      await oldStream.dispose();
    } catch (error) {
      debugPrint('[webrtc] $label remote stream dispose failed: $error');
    }
  }

  void _registerServerEvents() {
    _signaling.off('newProducer');
    _signaling.off('producerClosed');
    _signaling.off('turnApproved');
    _signaling.off('turnEnded');
    _signaling.off('peersUpdate');
    _signaling.off('activeStudentChanged');
    _signaling.off('teacherDisconnected');
    _signaling.off('consumerClosed');
    _signaling.off('queueUpdate');

    _signaling.on('newProducer', (dynamic data) async {
      final payload = _toMap(data);
      debugPrint('[webrtc] newProducer event payload=$payload');
      _rememberProducerMeta(payload);
      await _consumeProducer(payload);
    });

    _signaling.on('producerClosed', (dynamic data) async {
      final payload = _toMap(data);
      final producerId = payload['producerId']?.toString();
      if (producerId == null) return;
      _producerMetaById.remove(producerId);

      final consumer = _consumersByProducerId.remove(producerId);
      if (consumer != null) {
        _consumersById.remove(consumer.id);
        _consumerMetaById.remove(consumer.id);
        await consumer.close();
        await _rebuildRemoteStreams();
      }

      debugPrint('[webrtc] producerClosed event producerId=$producerId');
    });

    _signaling.on('consumerClosed', (dynamic data) async {
      final payload = _toMap(data);
      final consumerId = payload['consumerId']?.toString();
      if (consumerId == null) return;

      final consumer = _consumersById.remove(consumerId);
      if (consumer != null) {
        _consumersByProducerId.remove(consumer.producerId);
        _consumerMetaById.remove(consumer.id);
        await consumer.close();
        await _rebuildRemoteStreams();
      }

      debugPrint('[webrtc] consumerClosed event consumerId=$consumerId');
    });

    _signaling.on('turnApproved', (dynamic data) async {
      debugPrint('[webrtc] turnApproved event payload=${_toMap(data)}');

      if (_role != 'student') return;

      try {
        await _ensureTeacherConsumers();
        await _createSendTransportIfNeeded();
        await _startLocalMediaAndProduce();
        await _ensureTeacherConsumers();
        await _rebuildRemoteStreams();
        unawaited(_recoverTeacherStreamAfterApproval());
      } catch (error) {
        debugPrint('[webrtc] turnApproved flow failed: $error');
      }
    });

    _signaling.on('turnEnded', (dynamic data) async {
      debugPrint('[webrtc] turnEnded event payload=${_toMap(data)}');

      if (_role != 'student') return;

      await _stopLocalMediaAndProducers(notifyServer: false);
      await _closeSendTransportOnly();
    });

    _signaling.on('peersUpdate', (dynamic data) async {
      final payload = _toMap(data);
      _updatePeers(payload['peers']);
      activeStudentIdNotifier.value = payload['activeStudentId']?.toString();
      _absorbServerProducerState(payload);
      final hasQueuePayload = _updateQueue(payload['queue']);
      if (!hasQueuePayload) {
        _rebuildQueueFromPeers();
      }

      if (_role == 'student' &&
          _localStream != null &&
          activeStudentIdNotifier.value != _peerId) {
        await _stopLocalMediaAndProducers(notifyServer: false);
        await _closeSendTransportOnly();
      }
      if (_role == 'student') {
        await _ensureTeacherConsumers();
        await _rebuildRemoteStreams();
      }
      if (_role == 'teacher') {
        await _ensureActiveStudentConsumers();
      }

      debugPrint('[webrtc] peersUpdate peers=${peersNotifier.value.length}');
    });

    _signaling.on('activeStudentChanged', (dynamic data) async {
      final payload = _toMap(data);
      activeStudentIdNotifier.value = payload['studentId']?.toString();
      if (_role == 'teacher') {
        await _ensureActiveStudentConsumers();
      }
      debugPrint(
          '[webrtc] activeStudentChanged=${activeStudentIdNotifier.value}');
    });

    _signaling.on('teacherDisconnected', (dynamic data) {
      debugPrint('[webrtc] teacherDisconnected payload=${_toMap(data)}');
    });

    _signaling.on('queueUpdate', (dynamic data) {
      final payload = _toMap(data);
      final hasQueuePayload = _updateQueue(payload['queue']);
      if (!hasQueuePayload) {
        _rebuildQueueFromPeers();
      }
      if (payload['activeStudentId'] != null) {
        activeStudentIdNotifier.value = payload['activeStudentId']?.toString();
      }
    });
  }

  void _updatePeers(dynamic peersRaw) {
    if (peersRaw is! List) {
      peersNotifier.value = <PeerSummary>[];
      return;
    }

    final parsed = <PeerSummary>[];
    for (final dynamic item in peersRaw) {
      final map = _toMap(item);
      if (map.isEmpty) continue;
      parsed.add(PeerSummary.fromMap(map));
    }

    peersNotifier.value = parsed;
  }

  bool _updateQueue(dynamic queueRaw) {
    if (queueRaw is! List) {
      return false;
    }

    final parsed = <QueueEntry>[];
    for (final dynamic item in queueRaw) {
      final map = _toMap(item);
      if (map.isEmpty) {
        final id = item?.toString() ?? '';
        if (id.isEmpty) continue;
        parsed.add(QueueEntry(id: id, name: 'Student'));
        continue;
      }
      final entry = QueueEntry.fromMap(map);
      if (entry.id.isEmpty) continue;
      parsed.add(entry);
    }

    queueNotifier.value = parsed;
    return true;
  }

  void _rebuildQueueFromPeers() {
    final activeStudentId = activeStudentIdNotifier.value;
    final peersById = <String, PeerSummary>{
      for (final peer in peersNotifier.value) peer.id: peer,
    };

    final rebuilt = <QueueEntry>[];
    final seen = <String>{};

    for (final existing in queueNotifier.value) {
      final peer = peersById[existing.id];
      if (peer == null || peer.role != 'student') continue;
      if (peer.id == activeStudentId) continue;
      if (!seen.add(peer.id)) continue;
      rebuilt.add(QueueEntry(id: peer.id, name: peer.name));
    }

    for (final peer in peersNotifier.value) {
      if (peer.role != 'student') continue;
      if (peer.id == activeStudentId) continue;
      if (!seen.add(peer.id)) continue;
      rebuilt.add(QueueEntry(id: peer.id, name: peer.name));
    }

    queueNotifier.value = rebuilt;
  }

  void _absorbServerProducerState(Map<String, dynamic> payload) {
    final teacherMap = _toMap(payload['teacherProducers']);
    for (final key in const <String>['audio', 'video']) {
      final producerId = teacherMap[key]?.toString();
      if (producerId == null || producerId.isEmpty) continue;
      _rememberProducerMeta(<String, dynamic>{
        'producerId': producerId,
        'role': 'teacher',
        'source': 'teacher',
      });
    }

    final activeMap = _toMap(payload['activeStudentProducers']);
    final activePeerId = payload['activeStudentId']?.toString();
    for (final key in const <String>['audio', 'video']) {
      final producerId = activeMap[key]?.toString();
      if (producerId == null || producerId.isEmpty) continue;
      _rememberProducerMeta(<String, dynamic>{
        'producerId': producerId,
        'peerId': activePeerId,
        'role': 'student',
        'source': 'activestudent',
      });
    }
  }

  Future<void> _recoverTeacherStreamAfterApproval() async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (_role != 'student' || _localStream == null) {
      return;
    }
    try {
      await _ensureTeacherConsumers();
      await _rebuildRemoteStreams();
    } catch (error) {
      debugPrint('[webrtc] delayed teacher stream recovery failed: $error');
    }
  }

  Future<void> _stopLocalMediaAndProducers({required bool notifyServer}) async {
    final producers = _localProducersByKind.values.toList(growable: false);

    for (final producer in producers) {
      if (notifyServer && _signaling.isConnected) {
        try {
          await _signaling.request('closeProducer', <String, dynamic>{
            'producerId': producer.id,
          });
        } catch (error) {
          debugPrint(
              '[webrtc] closeProducer request failed producerId=${producer.id} error=$error');
        }
      }
      producer.close();
    }

    _localProducersByKind.clear();

    if (_localStream != null) {
      final localStream = _localStream!;
      _localStream = null;
      localStreamNotifier.value = null;
      try {
        await localStream.dispose();
      } catch (error) {
        debugPrint('[webrtc] local stream dispose failed: $error');
      }
    }
  }

  Future<void> _closeConsumers() async {
    final consumers = _consumersById.values.toList(growable: false);
    _consumersById.clear();
    _consumersByProducerId.clear();
    _consumerMetaById.clear();
    _producerMetaById.clear();

    teacherRemoteStreamNotifier.value = null;
    activeStudentRemoteStreamNotifier.value = null;
    await _disposeRemoteStreams();

    for (final consumer in consumers) {
      await consumer.close();
    }
  }

  Future<void> _closeTransports() async {
    _sendTransport?.close();
    _recvTransport?.close();

    _sendTransport = null;
    _recvTransport = null;
  }

  Future<void> _closeSendTransportOnly() async {
    _sendTransport?.close();
    _sendTransport = null;
  }

  Future<void> _ensureActiveStudentConsumers() async {
    if (_recvTransport == null || _device == null || _role != 'teacher') return;

    final activePeerId = activeStudentIdNotifier.value;
    if (activePeerId == null || activePeerId.isEmpty) {
      final staleConsumers = <ms.Consumer>[];
      for (final consumer in _consumersById.values) {
        final meta = _producerMetaById[consumer.producerId] ??
            _consumerMetaById[consumer.id] ??
            const <String, dynamic>{};
        final source = _normalizeSource(meta['source']);
        final role = _normalizeRole(meta['role']);
        if (source == 'activestudent' || role == 'student') {
          staleConsumers.add(consumer);
        }
      }
      for (final consumer in staleConsumers) {
        _consumersById.remove(consumer.id);
        _consumersByProducerId.remove(consumer.producerId);
        _consumerMetaById.remove(consumer.id);
        await consumer.close();
      }
      await _rebuildRemoteStreams();
      return;
    }

    final missingActiveProducerIds = <String>[];
    for (final entry in _producerMetaById.entries) {
      final producerId = entry.key;
      final meta = entry.value;
      final source = _normalizeSource(meta['source']);
      final role = _normalizeRole(meta['role']);
      final peerId = meta['peerId']?.toString();
      final isActiveStudentProducer =
          (source == 'activestudent' || role == 'student') &&
              (peerId == null || peerId.isEmpty || peerId == activePeerId);
      if (!isActiveStudentProducer) continue;
      if (_consumersByProducerId.containsKey(producerId)) continue;
      missingActiveProducerIds.add(producerId);
    }

    for (final producerId in missingActiveProducerIds) {
      final meta = _producerMetaById[producerId] ?? const <String, dynamic>{};
      await _consumeProducer(<String, dynamic>{
        'producerId': producerId,
        'peerId': meta['peerId'] ?? activePeerId,
        'role': 'student',
        'source': 'activestudent',
      });
    }

    await _rebuildRemoteStreams();
  }

  Future<void> _disposeRemoteStreams() async {
    if (_teacherRemoteStream != null) {
      try {
        await _teacherRemoteStream!.dispose();
      } catch (error) {
        debugPrint('[webrtc] teacher remote stream dispose failed: $error');
      }
      _teacherRemoteStream = null;
    }

    if (_activeStudentRemoteStream != null) {
      try {
        await _activeStudentRemoteStream!.dispose();
      } catch (error) {
        debugPrint('[webrtc] active student stream dispose failed: $error');
      }
      _activeStudentRemoteStream = null;
    }
  }

  Future<void> _resetMediaState({required bool notifyServer}) async {
    await _stopLocalMediaAndProducers(notifyServer: notifyServer);
    await _closeConsumers();
    await _closeTransports();

    _device = null;
    _peerId = null;
  }

  void _clearStateForUi() {
    peersNotifier.value = <PeerSummary>[];
    activeStudentIdNotifier.value = null;
    queueNotifier.value = <QueueEntry>[];

    localStreamNotifier.value = null;
    teacherRemoteStreamNotifier.value = null;
    activeStudentRemoteStreamNotifier.value = null;
  }

  String _normalizeKind(dynamic kind) {
    final text = kind?.toString().toLowerCase() ?? '';
    if (text.contains('audio')) return 'audio';
    if (text.contains('video')) return 'video';
    return text;
  }

  String _normalizeRole(dynamic role) {
    final text = role?.toString().toLowerCase() ?? '';
    if (text.contains('teacher')) return 'teacher';
    if (text.contains('student')) return 'student';
    return text;
  }

  String _normalizeSource(dynamic source) {
    final text = source?.toString().toLowerCase() ?? '';
    if (text.contains('teacher')) return 'teacher';
    if (text.contains('active') && text.contains('student')) {
      return 'activestudent';
    }
    return text.replaceAll(RegExp(r'[^a-z]'), '');
  }

  Map<String, dynamic> _normalizeConsumerAppData(
    Map<String, dynamic> appData, {
    String? fallbackProducerId,
    String? fallbackPeerId,
    String? fallbackRole,
    String? fallbackSource,
  }) {
    final normalized = <String, dynamic>{...appData};

    final existingRole = _normalizeRole(normalized['role']);
    final role =
        existingRole.isEmpty ? _normalizeRole(fallbackRole) : existingRole;
    if (role.isNotEmpty) {
      normalized['role'] = role;
    }

    final existingSource = _normalizeSource(normalized['source']);
    String? source;
    if (existingSource.isNotEmpty) {
      source = existingSource;
    } else if (fallbackSource != null && fallbackSource.isNotEmpty) {
      source = _normalizeSource(fallbackSource);
    } else if (role == 'teacher') {
      source = 'teacher';
    } else if (role == 'student') {
      source = 'activestudent';
    }

    if (source != null) {
      normalized['source'] = source;
    }

    final producerId = normalized['producerId']?.toString();
    if ((producerId == null || producerId.isEmpty) &&
        fallbackProducerId != null &&
        fallbackProducerId.isNotEmpty) {
      normalized['producerId'] = fallbackProducerId;
    }

    final peerId = normalized['peerId']?.toString();
    if ((peerId == null || peerId.isEmpty) &&
        fallbackPeerId != null &&
        fallbackPeerId.isNotEmpty) {
      normalized['peerId'] = fallbackPeerId;
    }

    return normalized;
  }

  void _rememberProducerMeta(
    Map<String, dynamic> raw, {
    String? fallbackProducerId,
  }) {
    final producerId = raw['producerId']?.toString() ?? fallbackProducerId;
    if (producerId == null || producerId.isEmpty) return;

    final role = _normalizeRole(raw['role']);
    String source = _normalizeSource(raw['source']);
    if (source.isEmpty && role == 'teacher') {
      source = 'teacher';
    } else if (source.isEmpty && role == 'student') {
      source = 'activestudent';
    }

    final next = <String, dynamic>{
      'producerId': producerId,
    };

    final peerId = raw['peerId']?.toString();
    if (peerId != null && peerId.isNotEmpty) {
      next['peerId'] = peerId;
    }
    if (role.isNotEmpty) {
      next['role'] = role;
    }
    if (source.isNotEmpty) {
      next['source'] = source;
    }

    _producerMetaById[producerId] = <String, dynamic>{
      ...?_producerMetaById[producerId],
      ...next,
    };
  }

  Future<void> _ensureTeacherConsumers() async {
    if (_recvTransport == null || _device == null) return;

    final missingTeacherProducerIds = <String>[];
    final missingActiveStudentProducerIds = <String>[];
    final activePeerId = activeStudentIdNotifier.value;

    for (final entry in _producerMetaById.entries) {
      final producerId = entry.key;
      final meta = entry.value;
      final source = _normalizeSource(meta['source']);
      final role = _normalizeRole(meta['role']);
      final peerId = meta['peerId']?.toString();
      final isTeacher = source == 'teacher' || role == 'teacher';
      if (_consumersByProducerId.containsKey(producerId)) continue;

      if (isTeacher) {
        missingTeacherProducerIds.add(producerId);
        continue;
      }

      final isActiveStudent = source == 'activestudent' || role == 'student';
      final shouldConsumeActiveStudent = _role == 'student' &&
          isActiveStudent &&
          activePeerId != null &&
          activePeerId.isNotEmpty &&
          activePeerId != _peerId &&
          (peerId == null || peerId.isEmpty || peerId == activePeerId);
      if (shouldConsumeActiveStudent) {
        missingActiveStudentProducerIds.add(producerId);
      }
    }

    for (final producerId in missingTeacherProducerIds) {
      final meta = _producerMetaById[producerId] ?? const <String, dynamic>{};
      await _consumeProducer(<String, dynamic>{
        'producerId': producerId,
        'peerId': meta['peerId'],
        'role': 'teacher',
        'source': 'teacher',
      });
    }

    for (final producerId in missingActiveStudentProducerIds) {
      final meta = _producerMetaById[producerId] ?? const <String, dynamic>{};
      await _consumeProducer(<String, dynamic>{
        'producerId': producerId,
        'peerId': meta['peerId'] ?? activePeerId,
        'role': 'student',
        'source': 'activestudent',
      });
    }
  }

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
    }

    if (raw == null) {
      return <String, dynamic>{};
    }

    try {
      final dynamic converted = raw.toMap();
      if (converted is Map) {
        return Map<String, dynamic>.from(converted);
      }
    } catch (_) {
      return <String, dynamic>{};
    }

    return <String, dynamic>{};
  }

  Map<String, dynamic> _extractMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    if (raw == null) {
      return <String, dynamic>{};
    }

    try {
      final dynamic converted = raw.toMap();
      if (converted is Map) {
        return Map<String, dynamic>.from(converted);
      }
    } catch (_) {
      return <String, dynamic>{};
    }

    return <String, dynamic>{};
  }
}
