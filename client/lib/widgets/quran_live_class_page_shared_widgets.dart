part of '../quran_live_class_page.dart';

extension _QuranLiveClassPageSharedWidgets on _QuranLiveClassPageState {
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

  PeerSummary? _myPeerSummary() {
    final myId = _client.peerId;
    if (myId == null || myId.isEmpty) {
      return null;
    }
    for (final peer in _peers) {
      if (peer.id == myId) {
        return peer;
      }
    }
    return null;
  }

  bool _hasPendingReentryRequestForMe() {
    final myId = _client.peerId;
    if (myId == null || myId.isEmpty) {
      return false;
    }
    for (final entry in _reentryRequests) {
      if (entry.id == myId) {
        return true;
      }
    }
    return false;
  }

  Widget _glassCard({required Widget child}) {
    return Card(
      color: Colors.white.withOpacity(0.92),
      child: child,
    );
  }
}
