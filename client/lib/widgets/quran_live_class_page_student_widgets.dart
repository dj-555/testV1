part of '../quran_live_class_page.dart';

extension _QuranLiveClassPageStudentWidgets on _QuranLiveClassPageState {
  Widget _buildStudentQueueCard() {
    final myQueueIndex = _myQueueIndex();
    final isActive =
        _activeStudentId != null && _activeStudentId == _client.peerId;
    final isQueued = myQueueIndex >= 0;
    final myPeer = _myPeerSummary();
    final canSelfJoinQueue = myPeer?.canSelfJoinQueue ?? true;
    final hasPendingReentryRequest = myPeer?.hasPendingReentryRequest == true ||
        _hasPendingReentryRequestForMe();

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
            else if (hasPendingReentryRequest)
              const Text(
                'Re-entry request sent. Waiting for teacher approval.',
              )
            else if (!canSelfJoinQueue)
              const Text(
                'You already used your direct queue entry. Request re-entry.',
              )
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
                    : canSelfJoinQueue
                        ? FilledButton.icon(
                            onPressed: _joinQueue,
                            icon: const Icon(Icons.queue),
                            label: const Text('Join Queue'),
                          )
                        : hasPendingReentryRequest
                            ? OutlinedButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.hourglass_top),
                                label: const Text('Re-entry Requested'),
                              )
                            : FilledButton.icon(
                                onPressed: _requestQueueReentry,
                                icon: const Icon(Icons.mark_email_unread),
                                label: const Text('Request Re-entry'),
                              ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
