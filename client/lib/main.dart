import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_client.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(
    <DeviceOrientation>[DeviceOrientation.portraitUp],
  );
  runApp(const QuranLiveClassApp());
}

class QuranLiveClassApp extends StatelessWidget {
  const QuranLiveClassApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Quran Live Class',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const QuranLiveClassPage(),
    );
  }
}

class QuranLiveClassPage extends StatefulWidget {
  const QuranLiveClassPage({super.key});

  @override
  State<QuranLiveClassPage> createState() => _QuranLiveClassPageState();
}

class _QuranLiveClassPageState extends State<QuranLiveClassPage> {
  static const int _globalQuarterTurnOffset = 2;
  static const String _serverUrl = String.fromEnvironment(
    'APP_SERVER_URL',
    defaultValue: 'https://sbc.itcallinfo.info',
  );
  static const String _socketPath = String.fromEnvironment(
    'APP_SOCKET_PATH',
    defaultValue: '/quran-socket.io',
  );

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

  Widget _buildStartupState() {
    if (_startupError == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 42, color: Colors.redAccent),
            const SizedBox(height: 12),
            const Text(
              'App startup failed',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _startupError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _initRenderers,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
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
    for (int i = 0; i < _queue.length; i++) {
      if (_queue[i].id == myId) {
        return i;
      }
    }
    return -1;
  }

  Widget _buildTeacherQueueCard() {
    final next = _queue.isNotEmpty ? _queue.first : null;

    return Card(
      color: Colors.white.withOpacity(0.95),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Queue Control',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Active: ${_nameForPeerId(_activeStudentId)}'),
            Text('Next in queue: ${next?.name ?? 'No one waiting'}'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isConnected ? _approveNextInQueue : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Approve First'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _activeStudentId == null ? null : _endTurn,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade400,
                    ),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('End Turn'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Waiting Queue',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (_queue.isEmpty)
              const Text('No students waiting')
            else
              Column(
                children: _queue.asMap().entries.map((entry) {
                  final index = entry.key;
                  final student = entry.value;
                  final isFirst = index == 0;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      child: Text('${index + 1}'),
                    ),
                    title: Text(student.name),
                    subtitle: Text(student.id),
                    trailing: isFirst
                        ? const Chip(label: Text('Next'))
                        : const SizedBox.shrink(),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudentQueueCard() {
    final myQueueIndex = _myQueueIndex();
    final isActive =
        _activeStudentId != null && _activeStudentId == _client.peerId;
    final isQueued = myQueueIndex >= 0;

    return Card(
      color: Colors.white.withOpacity(0.95),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Your Speaking Status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (isActive)
              const Text('You are live now. Mic and camera are enabled.')
            else if (isQueued)
              Text('Waiting in queue - position ${myQueueIndex + 1}')
            else
              const Text('Listen mode - mic/camera are muted'),
            const SizedBox(height: 8),
            Text('Active student: ${_nameForPeerId(_activeStudentId)}'),
            if (_queue.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('Next: ${_queue.first.name}'),
            ],
            if (!isActive) ...<Widget>[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: isQueued
                    ? OutlinedButton.icon(
                        onPressed: _leaveQueue,
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text('Leave Queue'),
                      )
                    : FilledButton.icon(
                        onPressed: _joinQueue,
                        icon: const Icon(Icons.queue),
                        label: const Text('Join Queue'),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _glassCard({required Widget child}) {
    return Card(
      color: Colors.white.withOpacity(0.92),
      child: child,
    );
  }

  Widget _buildConnectionCard() {
    return _glassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedRole,
              decoration: const InputDecoration(labelText: 'Role'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'teacher', child: Text('Teacher')),
                DropdownMenuItem(value: 'student', child: Text('Student')),
              ],
              onChanged: _isConnected
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedRole = value;
                        _studentPipSwapped = false;
                        _teacherPipSwapped = false;
                        _nameController.text =
                            value == 'teacher' ? 'Teacher' : 'Student';
                      });
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              enabled: !_isConnected,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
            const SizedBox(height: 12),
            Text(
              'Server: $_serverUrl',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Socket path: $_socketPath',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Network: $_networkType',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'ICE/NAT: $_iceMethod',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                ElevatedButton(
                  onPressed: _isBusy ? null : _toggleConnection,
                  child: Text(_isConnected ? 'Disconnect' : 'Connect'),
                ),
                const SizedBox(width: 12),
                Text('Status: $_status'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamsLayout() {
    if (_selectedRole == 'student' && _isConnected) {
      return _buildStudentPictureInPictureLayout();
    }
    if (_selectedRole == 'teacher' && _isConnected) {
      return _buildTeacherPictureInPictureLayout();
    }

    final streams = _buildStreamSpecs();

    return Column(
      children: streams
          .map((stream) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildVideoCard(
                  title: stream.title,
                  renderer: stream.renderer,
                  isLocal: stream.isLocal,
                  preferContain: stream.preferContain,
                  preferPortraitFallback: stream.preferPortraitFallback,
                ),
              ))
          .toList(),
    );
  }

  Widget _buildStudentPictureInPictureLayout() {
    final isMyTurn =
        _activeStudentId != null && _activeStudentId == _client.peerId;
    final activeStudentName = _nameForPeerId(_activeStudentId);

    final teacherStream = _StreamCardSpec(
      title: 'Teacher',
      renderer: _teacherRenderer,
      preferContain: true,
      preferPortraitFallback: true,
      featured: true,
    );

    final secondStream = isMyTurn
        ? _StreamCardSpec(
            title: 'You (Live)',
            renderer: _localRenderer,
            isLocal: true,
            preferContain: true,
            preferPortraitFallback: true,
          )
        : _StreamCardSpec(
            title: _activeStudentId == null
                ? 'No active student'
                : 'Turn: $activeStudentName',
            renderer: _activeStudentRenderer,
            preferContain: true,
            preferPortraitFallback: true,
          );

    _StreamCardSpec mainStream = teacherStream;
    _StreamCardSpec insetStream = secondStream;
    String mainEmptyLabel = 'Teacher stream unavailable';
    String insetEmptyLabel =
        isMyTurn ? 'Your camera is off' : 'Student stream unavailable';

    if (_studentPipSwapped) {
      mainStream = secondStream;
      insetStream = teacherStream;
      mainEmptyLabel = insetEmptyLabel;
      insetEmptyLabel = 'Teacher stream unavailable';
    }

    return _glassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _buildPictureInPictureStage(
          mainStream: mainStream,
          insetStream: insetStream,
          mainEmptyLabel: mainEmptyLabel,
          insetEmptyLabel: insetEmptyLabel,
          onSwap: _toggleStudentPipSwap,
        ),
      ),
    );
  }

  Widget _buildTeacherPictureInPictureLayout() {
    final activeStudentName = _nameForPeerId(_activeStudentId);

    final teacherStream = _StreamCardSpec(
      title: 'You (Teacher)',
      renderer: _localRenderer,
      isLocal: true,
      preferContain: true,
      preferPortraitFallback: true,
      featured: true,
    );

    final studentStream = _StreamCardSpec(
      title: _activeStudentId == null
          ? 'No active student'
          : 'Turn: $activeStudentName',
      renderer: _activeStudentRenderer,
      preferContain: true,
      preferPortraitFallback: true,
    );

    _StreamCardSpec mainStream = teacherStream;
    _StreamCardSpec insetStream = studentStream;
    String mainEmptyLabel = 'Your camera is off';
    String insetEmptyLabel = _activeStudentId == null
        ? 'No active student yet'
        : 'Student stream unavailable';

    if (_teacherPipSwapped) {
      mainStream = studentStream;
      insetStream = teacherStream;
      mainEmptyLabel = insetEmptyLabel;
      insetEmptyLabel = 'Your camera is off';
    }

    return _glassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _buildPictureInPictureStage(
          mainStream: mainStream,
          insetStream: insetStream,
          mainEmptyLabel: mainEmptyLabel,
          insetEmptyLabel: insetEmptyLabel,
          onSwap: _toggleTeacherPipSwap,
        ),
      ),
    );
  }

  Widget _buildPictureInPictureStage({
    required _StreamCardSpec mainStream,
    required _StreamCardSpec insetStream,
    required String mainEmptyLabel,
    required String insetEmptyLabel,
    required VoidCallback onSwap,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mainQuarterTurns = _normalizedQuarterTurnsWithOffset(
          renderer: mainStream.renderer,
          isLocal: mainStream.isLocal,
          preferPortraitFallback: mainStream.preferPortraitFallback,
        );
        final mainAspectRatio = _clampAspectRatio(
          _resolveDisplayAspectRatio(
            renderer: mainStream.renderer,
            quarterTurns: mainQuarterTurns,
            preferPortraitFallback: mainStream.preferPortraitFallback,
          ),
        );
        final mainHeight =
            _resolveVideoHeight(constraints.maxWidth, mainAspectRatio);

        final insetQuarterTurns = _normalizedQuarterTurnsWithOffset(
          renderer: insetStream.renderer,
          isLocal: insetStream.isLocal,
          preferPortraitFallback: insetStream.preferPortraitFallback,
        );
        final insetAspectRatio = _clampAspectRatio(
          _resolveDisplayAspectRatio(
            renderer: insetStream.renderer,
            quarterTurns: insetQuarterTurns,
            preferPortraitFallback: insetStream.preferPortraitFallback,
          ),
        );

        double insetWidth = constraints.maxWidth * 0.34;
        if (insetWidth < 112) insetWidth = 112;
        if (insetWidth > 168) insetWidth = 168;

        final maxInsetWidth = constraints.maxWidth - 24;
        if (maxInsetWidth.isFinite && insetWidth > maxInsetWidth) {
          insetWidth = maxInsetWidth;
        }
        if (insetWidth < 72) insetWidth = 72;

        double insetHeight = insetWidth / insetAspectRatio;
        final maxInsetHeight = mainHeight * 0.45;
        if (insetHeight > maxInsetHeight) {
          insetHeight = maxInsetHeight;
        }

        return GestureDetector(
          onTap: onSwap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: double.infinity,
            height: mainHeight,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: _buildPipVideoSurface(
                    renderer: mainStream.renderer,
                    isLocal: mainStream.isLocal,
                    preferContain: mainStream.preferContain,
                    quarterTurns: mainQuarterTurns,
                    emptyLabel: mainEmptyLabel,
                    borderRadius: 14,
                    viewKey: 'pip-main-${mainStream.title}',
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: _buildPipBadge(mainStream.title),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: _buildPipHintBadge('Tap to swap'),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: SizedBox(
                    width: insetWidth,
                    height: insetHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                        color: Colors.black.withOpacity(0.55),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Text(
                                insetStream.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _buildPipVideoSurface(
                                renderer: insetStream.renderer,
                                isLocal: insetStream.isLocal,
                                preferContain: insetStream.preferContain,
                                quarterTurns: insetQuarterTurns,
                                emptyLabel: insetEmptyLabel,
                                borderRadius: 9,
                                viewKey: 'pip-inset-${insetStream.title}',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPipBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.48),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPipHintBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPipVideoSurface({
    required RTCVideoRenderer renderer,
    required bool isLocal,
    required bool preferContain,
    required int quarterTurns,
    required String emptyLabel,
    required double borderRadius,
    required String viewKey,
  }) {
    final hasStream = renderer.srcObject != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ColoredBox(
        color: Colors.black,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: hasStream
              ? _buildRotatedVideoView(
                  key: ValueKey<String>(viewKey),
                  renderer: renderer,
                  mirror: isLocal,
                  preferContain: preferContain,
                  quarterTurns: quarterTurns,
                )
              : Center(
                  key: ValueKey<String>('empty-$viewKey'),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      emptyLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  int _normalizedQuarterTurnsWithOffset({
    required RTCVideoRenderer renderer,
    required bool isLocal,
    required bool preferPortraitFallback,
  }) {
    return _normalizeQuarterTurns(
      _resolveQuarterTurns(
            renderer,
            isLocal: isLocal,
            preferPortraitFallback: preferPortraitFallback,
          ) +
          _globalQuarterTurnOffset,
    );
  }

  List<_StreamCardSpec> _buildStreamSpecs() {
    if (_selectedRole == 'student') {
      return <_StreamCardSpec>[
        _StreamCardSpec(
          title: 'Teacher Stream',
          renderer: _teacherRenderer,
          preferContain: true,
          preferPortraitFallback: true,
          featured: true,
        ),
        _StreamCardSpec(
          title: 'Your Camera (only when approved)',
          renderer: _localRenderer,
          isLocal: true,
          preferContain: true,
          preferPortraitFallback: true,
        ),
      ];
    }

    return <_StreamCardSpec>[
      _StreamCardSpec(
        title: 'Your Local Preview',
        renderer: _localRenderer,
        isLocal: true,
        preferContain: true,
        preferPortraitFallback: true,
        featured: true,
      ),
      _StreamCardSpec(
        title: 'Active Student Stream',
        renderer: _activeStudentRenderer,
        preferContain: true,
        preferPortraitFallback: true,
      ),
    ];
  }

  Widget _buildVideoCard({
    required String title,
    required RTCVideoRenderer renderer,
    bool isLocal = false,
    bool preferContain = false,
    bool preferPortraitFallback = false,
  }) {
    final hasStream = renderer.srcObject != null;
    final quarterTurns = _normalizedQuarterTurnsWithOffset(
      renderer: renderer,
      isLocal: isLocal,
      preferPortraitFallback: preferPortraitFallback,
    );
    final aspectRatio = _clampAspectRatio(
      _resolveDisplayAspectRatio(
        renderer: renderer,
        quarterTurns: quarterTurns,
        preferPortraitFallback: preferPortraitFallback,
      ),
    );
    final videoMeta = _videoMetaLabel(
      renderer,
      quarterTurns: quarterTurns,
      preferPortraitFallback: preferPortraitFallback,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final targetHeight =
            _resolveVideoHeight(constraints.maxWidth, aspectRatio);

        return Card(
          color: Colors.white.withOpacity(0.94),
          elevation: 2,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  videoMeta,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: targetHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ColoredBox(
                      color: Colors.black,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        child: hasStream
                            ? _buildRotatedVideoView(
                                key: ValueKey<String>('video-$title'),
                                renderer: renderer,
                                mirror: isLocal,
                                preferContain: preferContain,
                                quarterTurns: quarterTurns,
                              )
                            : const Center(
                                key: ValueKey<String>('empty-video'),
                                child: Text(
                                  'No stream',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRotatedVideoView({
    Key? key,
    required RTCVideoRenderer renderer,
    required bool mirror,
    required bool preferContain,
    required int quarterTurns,
  }) {
    Widget view = RTCVideoView(
      key: key,
      renderer,
      mirror: mirror,
      objectFit: preferContain
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );

    if (quarterTurns != 0) {
      view = RotatedBox(
        quarterTurns: quarterTurns,
        child: view,
      );
    }

    return view;
  }

  double _resolveVideoHeight(double width, double aspectRatio) {
    const minHeight = 220.0;
    const maxHeight = 640.0;

    final naturalHeight = width / aspectRatio;
    if (naturalHeight < minHeight) return minHeight;
    if (naturalHeight > maxHeight) return maxHeight;
    return naturalHeight;
  }

  double _clampAspectRatio(double ratio) {
    const minRatio = 9 / 16;
    const maxRatio = 16 / 9;
    if (ratio < minRatio) return minRatio;
    if (ratio > maxRatio) return maxRatio;
    return ratio;
  }

  String _videoMetaLabel(
    RTCVideoRenderer renderer, {
    required int quarterTurns,
    required bool preferPortraitFallback,
  }) {
    final width = renderer.videoWidth;
    final height = renderer.videoHeight;

    if (width <= 0 || height <= 0) {
      return 'Waiting for video frames';
    }

    final displayAspectRatio = _resolveDisplayAspectRatio(
      renderer: renderer,
      quarterTurns: quarterTurns,
      preferPortraitFallback: preferPortraitFallback,
    );
    final orientation = displayAspectRatio < 1 ? 'Portrait' : 'Landscape';

    return '$width x $height - $orientation';
  }

  double _resolveBaseAspectRatio(
    RTCVideoRenderer renderer, {
    required bool preferPortraitFallback,
  }) {
    final width = renderer.videoWidth.toDouble();
    final height = renderer.videoHeight.toDouble();

    if (width > 0 && height > 0) {
      final ratio = width / height;
      if (ratio.isFinite && ratio > 0) {
        return ratio;
      }
    }

    return preferPortraitFallback ? (9 / 16) : (16 / 9);
  }

  double _resolveDisplayAspectRatio({
    required RTCVideoRenderer renderer,
    required int quarterTurns,
    required bool preferPortraitFallback,
  }) {
    final baseRatio = _resolveBaseAspectRatio(
      renderer,
      preferPortraitFallback: preferPortraitFallback,
    );

    if (quarterTurns.isOdd) {
      return 1 / baseRatio;
    }

    return baseRatio;
  }

  int _resolveQuarterTurns(
    RTCVideoRenderer renderer, {
    required bool isLocal,
    required bool preferPortraitFallback,
  }) {
    final normalizedRotation =
        _normalizeRotationDegrees(renderer.value.rotation);
    if (normalizedRotation % 90 == 0 && normalizedRotation != 0) {
      final turnsFromMetadata = (normalizedRotation / 90).round();

      if (isLocal) {
        return _normalizeQuarterTurns(turnsFromMetadata);
      }

      return _normalizeQuarterTurns(-turnsFromMetadata);
    }

    final baseRatio = _resolveBaseAspectRatio(
      renderer,
      preferPortraitFallback: preferPortraitFallback,
    );
    return baseRatio > 1 ? 1 : 0;
  }

  int _normalizeRotationDegrees(int value) {
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  int _normalizeQuarterTurns(int value) {
    final normalized = value % 4;
    return normalized < 0 ? normalized + 4 : normalized;
  }
}
