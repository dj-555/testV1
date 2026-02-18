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

  StreamSubscription<int>? _reconnectSub;
  StreamSubscription<String>? _disconnectSub;

  bool get isTeacher => _role == 'teacher';

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
  }

  Future<void> approveTurn(String studentId) async {
    if (!isTeacher) {
      throw Exception('Only teacher can approve turns');
    }

    await _signaling.request('approveTurn', <String, dynamic>{
      'studentId': studentId,
    });

    debugPrint('[webrtc] approveTurn -> $studentId');
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

    await _createDevice(joinResponse['rtpCapabilities']);
    await _createRecvTransport();

    if (isTeacher) {
      await _createSendTransportIfNeeded();
      await _startLocalMediaAndProduce();
    }

    final dynamic producersRaw = joinResponse['producers'];
    if (producersRaw is List) {
      for (final dynamic item in producersRaw) {
        final producerMap = _toMap(item);
        if (producerMap.isNotEmpty) {
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

    final legacyConstraints = <String, dynamic>{
      'audio': true,
      'video': <String, dynamic>{
        'facingMode': 'user',
        'mandatory': <String, dynamic>{
          'minWidth': '640',
          'minHeight': '360',
          'minFrameRate': '15',
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
        source: 'microphone',
      );
    }

    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty && !_localProducersByKind.containsKey('video')) {
      _sendTransport!.produce(
        track: videoTracks.first,
        stream: _localStream!,
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

    final producerId = producerInfo['producerId']?.toString();
    final producerPeerId = producerInfo['peerId']?.toString();

    if (producerId == null || producerPeerId == null) return;
    if (producerPeerId == _peerId) return;

    if (_consumersByProducerId.containsKey(producerId)) {
      return;
    }

    try {
      final response = await _signaling.request('consume', <String, dynamic>{
        'transportId': _recvTransport!.id,
        'producerId': producerId,
        'rtpCapabilities': _device!.rtpCapabilities.toMap(),
      });

      final String kind = _normalizeKind(response['kind']);
      final mediaKind = kind == 'audio'
          ? RTCRtpMediaType.RTCRtpMediaTypeAudio
          : RTCRtpMediaType.RTCRtpMediaTypeVideo;

      _recvTransport!.consume(
        id: response['id']?.toString() ?? '',
        producerId: response['producerId']?.toString() ?? '',
        peerId: response['peerId']?.toString() ?? '',
        kind: mediaKind,
        rtpParameters: ms.RtpParameters.fromMap(
          _toMap(response['rtpParameters']),
        ),
        appData: _toMap(response['appData']),
      );

      await _signaling.request('resumeConsumer', <String, dynamic>{
        'consumerId': response['id']?.toString() ?? '',
      });

      debugPrint('[webrtc] consume success producerId=$producerId');
    } catch (error) {
      debugPrint('[webrtc] consume failed producerId=$producerId error=$error');
    }
  }

  void _onConsumerCreated(ms.Consumer consumer, dynamic _) {
    _consumersById[consumer.id] = consumer;
    _consumersByProducerId[consumer.producerId] = consumer;

    debugPrint(
        '[webrtc] consumer created id=${consumer.id} producerId=${consumer.producerId}');

    unawaited(_rebuildRemoteStreams());
  }

  Future<void> _rebuildRemoteStreams() async {
    final teacherConsumers = <ms.Consumer>[];
    final activeStudentConsumers = <ms.Consumer>[];

    for (final consumer in _consumersById.values) {
      final appData = _toMap(consumer.appData);
      final role = appData['role']?.toString();
      if (role == 'teacher') {
        teacherConsumers.add(consumer);
      } else if (role == 'student') {
        activeStudentConsumers.add(consumer);
      }
    }

    await _disposeRemoteStreams();

    if (teacherConsumers.isNotEmpty) {
      _teacherRemoteStream = await createLocalMediaStream('teacher-remote');
      for (final consumer in teacherConsumers) {
        _teacherRemoteStream!.addTrack(consumer.track);
      }
    }

    if (activeStudentConsumers.isNotEmpty) {
      _activeStudentRemoteStream =
          await createLocalMediaStream('active-student-remote');
      for (final consumer in activeStudentConsumers) {
        _activeStudentRemoteStream!.addTrack(consumer.track);
      }
    }

    teacherRemoteStreamNotifier.value = _teacherRemoteStream;
    activeStudentRemoteStreamNotifier.value = _activeStudentRemoteStream;
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

    _signaling.on('newProducer', (dynamic data) async {
      final payload = _toMap(data);
      debugPrint('[webrtc] newProducer event payload=$payload');
      await _consumeProducer(payload);
    });

    _signaling.on('producerClosed', (dynamic data) async {
      final payload = _toMap(data);
      final producerId = payload['producerId']?.toString();
      if (producerId == null) return;

      final consumer = _consumersByProducerId.remove(producerId);
      if (consumer != null) {
        _consumersById.remove(consumer.id);
        consumer.close();
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
        consumer.close();
        await _rebuildRemoteStreams();
      }

      debugPrint('[webrtc] consumerClosed event consumerId=$consumerId');
    });

    _signaling.on('turnApproved', (dynamic data) async {
      debugPrint('[webrtc] turnApproved event payload=${_toMap(data)}');

      if (_role != 'student') return;

      try {
        await _createSendTransportIfNeeded();
        await _startLocalMediaAndProduce();
      } catch (error) {
        debugPrint('[webrtc] turnApproved flow failed: $error');
      }
    });

    _signaling.on('turnEnded', (dynamic data) async {
      debugPrint('[webrtc] turnEnded event payload=${_toMap(data)}');

      if (_role != 'student') return;

      await _stopLocalMediaAndProducers(notifyServer: false);
    });

    _signaling.on('peersUpdate', (dynamic data) {
      final payload = _toMap(data);
      _updatePeers(payload['peers']);
      activeStudentIdNotifier.value = payload['activeStudentId']?.toString();

      debugPrint('[webrtc] peersUpdate peers=${peersNotifier.value.length}');
    });

    _signaling.on('activeStudentChanged', (dynamic data) {
      final payload = _toMap(data);
      activeStudentIdNotifier.value = payload['studentId']?.toString();
      debugPrint(
          '[webrtc] activeStudentChanged=${activeStudentIdNotifier.value}');
    });

    _signaling.on('teacherDisconnected', (dynamic data) {
      debugPrint('[webrtc] teacherDisconnected payload=${_toMap(data)}');
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
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
      localStreamNotifier.value = null;
    }
  }

  Future<void> _closeConsumers() async {
    final consumers = _consumersById.values.toList(growable: false);
    for (final consumer in consumers) {
      consumer.close();
    }

    _consumersById.clear();
    _consumersByProducerId.clear();

    await _disposeRemoteStreams();

    teacherRemoteStreamNotifier.value = null;
    activeStudentRemoteStreamNotifier.value = null;
  }

  Future<void> _closeTransports() async {
    _sendTransport?.close();
    _recvTransport?.close();

    _sendTransport = null;
    _recvTransport = null;
  }

  Future<void> _disposeRemoteStreams() async {
    if (_teacherRemoteStream != null) {
      await _teacherRemoteStream!.dispose();
      _teacherRemoteStream = null;
    }

    if (_activeStudentRemoteStream != null) {
      await _activeStudentRemoteStream!.dispose();
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

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
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
