import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  final TextEditingController _serverController =
      TextEditingController(text: 'http://192.168.1.194:3000');
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

  List<PeerSummary> _peers = <PeerSummary>[];
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

    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await Future.wait(<Future<void>>[
      _localRenderer.initialize(),
      _teacherRenderer.initialize(),
      _activeStudentRenderer.initialize(),
    ]);

    if (!mounted) return;
    setState(() {
      _renderersReady = true;
    });
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

  Future<void> _approveTurn(String studentId) async {
    try {
      await _client.approveTurn(studentId);
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
    final students = _peers.where((peer) => peer.role == 'student').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quran Live Class'),
      ),
      body: _renderersReady
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildConnectionCard(),
                  const SizedBox(height: 16),
                  if (_selectedRole == 'teacher' && _isConnected)
                    _buildTeacherTurnCard(students),
                  if (_selectedRole == 'teacher' && _isConnected)
                    const SizedBox(height: 16),
                  _buildVideoCard(
                    title: 'Local Preview (Teacher or Approved Student)',
                    renderer: _localRenderer,
                  ),
                  const SizedBox(height: 12),
                  _buildVideoCard(
                    title: 'Teacher Stream (Students always consume this)',
                    renderer: _teacherRenderer,
                  ),
                  const SizedBox(height: 12),
                  _buildVideoCard(
                    title: 'Active Student Stream (Optional for all)',
                    renderer: _activeStudentRenderer,
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildConnectionCard() {
    return Card(
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
            TextField(
              controller: _serverController,
              enabled: !_isConnected,
              decoration: const InputDecoration(labelText: 'Server URL'),
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

  Widget _buildTeacherTurnCard(List<PeerSummary> students) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Teacher Turn Control',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Active Student: ${_activeStudentId ?? 'None'}'),
            const SizedBox(height: 12),
            if (students.isEmpty)
              const Text('No students connected yet.')
            else
              Column(
                children: students.map((student) {
                  final isActive = student.id == _activeStudentId;
                  return ListTile(
                    dense: true,
                    title: Text(student.name),
                    subtitle: Text('id: ${student.id}'),
                    trailing: ElevatedButton(
                      onPressed:
                          isActive ? null : () => _approveTurn(student.id),
                      child: Text(isActive ? 'Active' : 'Approve'),
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _activeStudentId == null ? null : _endTurn,
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade400),
              child: const Text('End Active Turn'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCard(
      {required String title, required RTCVideoRenderer renderer}) {
    final hasStream = renderer.srcObject != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: hasStream
                    ? RTCVideoView(
                        renderer,
                        mirror: title.startsWith('Local'),
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : const Text(
                        'No stream',
                        style: TextStyle(color: Colors.white70),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
