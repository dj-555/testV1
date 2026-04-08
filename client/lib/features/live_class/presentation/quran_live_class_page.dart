import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/connection_card.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/streams_layout.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/student_queue_card.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/teacher_queue_card.dart';
import 'package:quran_live_class_client/webrtc_client.dart';

class QuranLiveClassPage extends StatefulWidget {
  const QuranLiveClassPage({super.key});

  @override
  State<QuranLiveClassPage> createState() => _QuranLiveClassPageState();
}

class _QuranLiveClassPageState extends State<QuranLiveClassPage> {
  final TextEditingController _serverController =
      TextEditingController(text: 'http://62.171.178.72:3000/');
  final TextEditingController _nameController =
      TextEditingController(text: 'Teacher');

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _teacherRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _activeStudentRenderer = RTCVideoRenderer();

  late final WebRtcClient _client;

  String _selectedRole = 'teacher';
  String _status = 'disconnected';
  bool _isBusy = false;
  bool _renderersReady = false;
  bool _studentPipSwapped = false;
  bool _teacherPipSwapped = false;
  bool _teacherHasApprovedAtLeastOnce = false;

  List<PeerSummary> _peers = <PeerSummary>[];
  List<QueueEntry> _queue = <QueueEntry>[];
  String? _activeStudentId;

  @override
  void initState() {
    super.initState();
    _client = WebRtcClient();

    _client.connectionState.addListener(_onConnectionStateChanged);
    _client.localStreamNotifier.addListener(_onLocalStreamChanged);
    _client.teacherRemoteStreamNotifier.addListener(_onTeacherStreamChanged);
    _client.activeStudentRemoteStreamNotifier
        .addListener(_onActiveStudentStreamChanged);
    _client.peersNotifier.addListener(_onPeersChanged);
    _client.activeStudentIdNotifier.addListener(_onActiveStudentChanged);
    _client.queueNotifier.addListener(_onQueueChanged);

    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await Future.wait(<Future<void>>[
      _localRenderer.initialize(),
      _teacherRenderer.initialize(),
      _activeStudentRenderer.initialize(),
    ]);

    _localRenderer.onResize = _onRendererResize;
    _teacherRenderer.onResize = _onRendererResize;
    _activeStudentRenderer.onResize = _onRendererResize;

    if (!mounted) return;
    setState(() {
      _renderersReady = true;
    });
  }

  void _onRendererResize() {
    if (!mounted) return;
    setState(() {});
  }

  void _onConnectionStateChanged() {
    if (!mounted) return;
    setState(() {
      _status = _client.connectionState.value;
    });
  }

  void _onLocalStreamChanged() {
    _localRenderer.srcObject = _client.localStreamNotifier.value;
    if (!mounted) return;
    setState(() {});
  }

  void _onTeacherStreamChanged() {
    _teacherRenderer.srcObject = _client.teacherRemoteStreamNotifier.value;
    if (!mounted) return;
    setState(() {});
  }

  void _onActiveStudentStreamChanged() {
    _activeStudentRenderer.srcObject =
        _client.activeStudentRemoteStreamNotifier.value;
    if (!mounted) return;
    setState(() {});
  }

  void _onPeersChanged() {
    if (!mounted) return;
    setState(() {
      _peers = _client.peersNotifier.value;
    });
  }

  void _onActiveStudentChanged() {
    if (!mounted) return;
    final nextActiveStudentId = _client.activeStudentIdNotifier.value;
    setState(() {
      _activeStudentId = nextActiveStudentId;
      if (_selectedRole == 'teacher' &&
          nextActiveStudentId != null &&
          nextActiveStudentId.isNotEmpty) {
        _teacherHasApprovedAtLeastOnce = true;
      }
    });
  }

  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {
      _queue = _client.queueNotifier.value;
    });
  }

  void _toggleStudentPipSwap() {
    if (!mounted) return;
    setState(() {
      _studentPipSwapped = !_studentPipSwapped;
    });
  }

  void _toggleTeacherPipSwap() {
    if (!mounted) return;
    setState(() {
      _teacherPipSwapped = !_teacherPipSwapped;
    });
  }

  bool get _isConnected =>
      _status == 'connected' ||
      _status == 'reconnecting' ||
      _status == 'connecting';

  Future<void> _toggleConnection() async {
    if (_isBusy) return;

    setState(() {
      _isBusy = true;
    });

    try {
      if (_isConnected) {
        await _client.disconnect();
        if (mounted) {
          setState(() {
            _teacherHasApprovedAtLeastOnce = false;
          });
        }
      } else {
        await _client.connect(
          serverUrl: _serverController.text.trim(),
          role: _selectedRole,
          displayName: _nameController.text.trim(),
        );
      }
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _approveNextInQueue() async {
    try {
      await _client.approveTurn();
      if (!mounted) return;
      setState(() {
        _teacherHasApprovedAtLeastOnce = true;
      });
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _joinQueue() async {
    try {
      await _client.joinQueue();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _leaveQueue() async {
    try {
      await _client.leaveQueue();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _endTurn() async {
    try {
      await _client.endTurn();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _client.connectionState.removeListener(_onConnectionStateChanged);
    _client.localStreamNotifier.removeListener(_onLocalStreamChanged);
    _client.teacherRemoteStreamNotifier.removeListener(_onTeacherStreamChanged);
    _client.activeStudentRemoteStreamNotifier
        .removeListener(_onActiveStudentStreamChanged);
    _client.peersNotifier.removeListener(_onPeersChanged);
    _client.activeStudentIdNotifier.removeListener(_onActiveStudentChanged);
    _client.queueNotifier.removeListener(_onQueueChanged);
    if (_renderersReady) {
      _localRenderer.srcObject = null;
      _teacherRenderer.srcObject = null;
      _activeStudentRenderer.srcObject = null;
    }
    unawaited(_client.dispose());
    unawaited(_localRenderer.dispose());
    unawaited(_teacherRenderer.dispose());
    unawaited(_activeStudentRenderer.dispose());

    _serverController.dispose();
    _nameController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Live Class'),
        backgroundColor: Colors.transparent,
      ),
      body: _renderersReady
          ? Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Color(0xFF0F2027),
                    Color(0xFF203A43),
                    Color(0xFF2C5364),
                  ],
                ),
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ConnectionCard(
                        nameController: _nameController,
                        serverController: _serverController,
                        selectedRole: _selectedRole,
                        isConnected: _isConnected,
                        isBusy: _isBusy,
                        status: _status,
                        onRoleChanged: _handleRoleChanged,
                        onToggleConnection: _toggleConnection,
                      ),
                      const SizedBox(height: 16),
                      if (_selectedRole == 'teacher' && _isConnected)
                        TeacherQueueCard(
                          activeStudentName: _nameForPeerId(_activeStudentId),
                          nextStudentName: _queue.isNotEmpty
                              ? _queue.first.name
                              : 'No one waiting',
                          queue: _queue,
                          approveLabel: _teacherHasApprovedAtLeastOnce
                              ? 'Next'
                              : 'Approve First',
                          canApprove: _isConnected && _queue.isNotEmpty,
                          canEndTurn: _activeStudentId != null,
                          onApproveNext: _approveNextInQueue,
                          onEndTurn: _endTurn,
                        ),
                      if (_selectedRole == 'student' && _isConnected)
                        StudentQueueCard(
                          isActive: _activeStudentId == _client.peerId,
                          isQueued: _myQueueIndex() >= 0,
                          queuePosition:
                              _myQueueIndex() >= 0 ? _myQueueIndex() + 1 : null,
                          activeStudentName: _nameForPeerId(_activeStudentId),
                          nextStudentName:
                              _queue.isNotEmpty ? _queue.first.name : null,
                          onJoinQueue: _joinQueue,
                          onLeaveQueue: _leaveQueue,
                        ),
                      if (_isConnected) const SizedBox(height: 16),
                      LiveClassStreamsLayout(
                        selectedRole: _selectedRole,
                        isConnected: _isConnected,
                        currentPeerId: _client.peerId,
                        activeStudentId: _activeStudentId,
                        activeStudentName: _nameForPeerId(_activeStudentId),
                        localRenderer: _localRenderer,
                        teacherRenderer: _teacherRenderer,
                        activeStudentRenderer: _activeStudentRenderer,
                        studentPipSwapped: _studentPipSwapped,
                        teacherPipSwapped: _teacherPipSwapped,
                        onToggleStudentPipSwap: _toggleStudentPipSwap,
                        onToggleTeacherPipSwap: _toggleTeacherPipSwap,
                      ),
                    ],
                  ),
                ),
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  void _handleRoleChanged(String? value) {
    if (value == null) return;

    setState(() {
      _selectedRole = value;
      _studentPipSwapped = false;
      _teacherPipSwapped = false;
      _teacherHasApprovedAtLeastOnce = false;
      _nameController.text = value == 'teacher' ? 'Teacher' : 'Student';
    });
  }

  String _nameForPeerId(String? peerId) {
    if (peerId == null || peerId.isEmpty) {
      return 'None';
    }
    for (final peer in _peers) {
      if (peer.id == peerId) {
        return peer.name;
      }
    }
    return peerId;
  }

  int _myQueueIndex() {
    final myId = _client.peerId;
    if (myId == null || myId.isEmpty) {
      return -1;
    }
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == myId) {
        return i;
      }
    }
    return -1;
  }
}
