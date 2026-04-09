import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_client.dart';

part 'widgets/quran_live_class_page_shared_widgets.dart';
part 'widgets/quran_live_class_page_connection_widgets.dart';
part 'widgets/quran_live_class_page_teacher_widgets.dart';
part 'widgets/quran_live_class_page_student_widgets.dart';
part 'widgets/quran_live_class_page_stream_widgets.dart';
part 'widgets/quran_live_class_page_video_utils.dart';

const int _globalQuarterTurnOffset = 2;
const String _serverUrl = String.fromEnvironment(
  'APP_SERVER_URL',
  defaultValue: 'https://sbc.itcallinfo.info',
);
const String _socketPath = String.fromEnvironment(
  'APP_SOCKET_PATH',
  defaultValue: '/quran-socket.io',
);

class _StreamCardSpec {
  final String title;
  final RTCVideoRenderer renderer;
  final bool isLocal;
  final bool preferContain;
  final bool preferPortraitFallback;
  final bool featured;

  const _StreamCardSpec({
    required this.title,
    required this.renderer,
    this.isLocal = false,
    this.preferContain = false,
    this.preferPortraitFallback = false,
    this.featured = false,
  });
}

class QuranLiveClassPage extends StatefulWidget {
  const QuranLiveClassPage({super.key});

  @override
  State<QuranLiveClassPage> createState() => _QuranLiveClassPageState();
}

class _QuranLiveClassPageState extends State<QuranLiveClassPage> {
  final TextEditingController _nameController =
      TextEditingController(text: 'Teacher');

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _teacherRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _activeStudentRenderer = RTCVideoRenderer();

  late final WebRtcClient _client;
  final Connectivity _connectivity = Connectivity();

  String _selectedRole = 'teacher';
  String _status = 'disconnected';
  String _networkType = 'detecting...';
  String _iceMethod = 'not-detected';
  bool _isBusy = false;
  bool _renderersReady = false;
  String? _startupError;
  bool _studentPipSwapped = false;
  bool _teacherPipSwapped = false;

  List<PeerSummary> _peers = <PeerSummary>[];
  List<QueueEntry> _queue = <QueueEntry>[];
  List<QueueEntry> _reentryRequests = <QueueEntry>[];
  String? _activeStudentId;
  StreamSubscription<dynamic>? _networkSubscription;

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
    _client.reentryRequestsNotifier.addListener(_onReentryRequestsChanged);
    _client.iceMethodNotifier.addListener(_onIceMethodChanged);

    _initRenderers();
    unawaited(_initNetworkInfo());
  }

  Future<void> _initRenderers() async {
    try {
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
        _startupError = null;
      });
    } catch (error, stackTrace) {
      debugPrint('[ui] renderer init failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _renderersReady = false;
        _startupError = error.toString();
      });
    }
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
    setState(() {
      _activeStudentId = _client.activeStudentIdNotifier.value;
    });
  }

  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {
      _queue = _client.queueNotifier.value;
    });
  }

  void _onReentryRequestsChanged() {
    if (!mounted) return;
    setState(() {
      _reentryRequests = _client.reentryRequestsNotifier.value;
    });
  }

  void _onIceMethodChanged() {
    if (!mounted) return;
    setState(() {
      _iceMethod = _client.iceMethodNotifier.value;
    });
  }

  Future<void> _initNetworkInfo() async {
    try {
      final current = await _connectivity.checkConnectivity();
      _setNetworkTypeFromRaw(current);

      _networkSubscription = _connectivity.onConnectivityChanged.listen(
        _setNetworkTypeFromRaw,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[ui] connectivity stream error: $error');
          debugPrintStack(stackTrace: stackTrace);
        },
      );
    } catch (error, stackTrace) {
      debugPrint('[ui] connectivity detection failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _networkType = 'unavailable';
      });
    }
  }

  void _setNetworkTypeFromRaw(dynamic raw) {
    final values = raw is List ? raw : <dynamic>[raw];
    final labels = <String>[];
    for (final value in values) {
      final label = _networkLabel(value);
      if (label.isEmpty || label == 'Offline') continue;
      if (!labels.contains(label)) {
        labels.add(label);
      }
    }

    final result = labels.isEmpty ? 'Offline' : labels.join(' + ');
    if (!mounted) return;
    setState(() {
      _networkType = result;
    });
  }

  String _networkLabel(dynamic value) {
    final text = value?.toString().toLowerCase() ?? '';
    if (text.contains('wifi')) return 'Wi-Fi';
    if (text.contains('mobile')) return 'Mobile';
    if (text.contains('ethernet')) return 'Ethernet';
    if (text.contains('vpn')) return 'VPN';
    if (text.contains('bluetooth')) return 'Bluetooth';
    if (text.contains('none')) return 'Offline';
    if (text.contains('other')) return 'Other';
    return text.trim().isEmpty ? '' : value.toString();
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
      } else {
        await _client.connect(
          serverUrl: _serverUrl,
          role: _selectedRole,
          displayName: _nameController.text.trim(),
          socketPath: _socketPath,
          networkType: _networkType,
        );
      }
    } catch (error, stackTrace) {
      debugPrint('[ui] connect/disconnect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
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

  Future<void> _requestQueueReentry() async {
    try {
      await _client.requestQueueReentry();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _approveNextReentryRequest() async {
    try {
      await _client.approveQueueReentry();
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

  void _applyRoleSelection(String value) {
    setState(() {
      _selectedRole = value;
      _studentPipSwapped = false;
      _teacherPipSwapped = false;
      _nameController.text = value == 'teacher' ? 'Teacher' : 'Student';
    });
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
    _client.reentryRequestsNotifier.removeListener(_onReentryRequestsChanged);
    _client.iceMethodNotifier.removeListener(_onIceMethodChanged);
    unawaited(_networkSubscription?.cancel());
    if (_renderersReady) {
      _localRenderer.srcObject = null;
      _teacherRenderer.srcObject = null;
      _activeStudentRenderer.srcObject = null;
    }
    unawaited(_client.dispose());
    unawaited(_localRenderer.dispose());
    unawaited(_teacherRenderer.dispose());
    unawaited(_activeStudentRenderer.dispose());

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
                      _buildConnectionCard(),
                      const SizedBox(height: 16),
                      if (_selectedRole == 'teacher' && _isConnected)
                        _buildTeacherQueueCard(),
                      if (_selectedRole == 'student' && _isConnected)
                        _buildStudentQueueCard(),
                      if (_isConnected) const SizedBox(height: 16),
                      _buildStreamsLayout(),
                    ],
                  ),
                ),
              ),
            )
          : _buildStartupState(),
    );
  }
}
