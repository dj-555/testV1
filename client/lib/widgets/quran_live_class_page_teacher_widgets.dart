part of '../quran_live_class_page.dart';

extension _QuranLiveClassPageTeacherWidgets on _QuranLiveClassPageState {
  Widget _buildTeacherQueueCard() {
    final nextInQueue = _queue.isNotEmpty ? _queue.first : null;
    final firstReentryRequest =
        _reentryRequests.isNotEmpty ? _reentryRequests.first : null;

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
            Text('Next in queue: ${nextInQueue?.name ?? 'No one waiting'}'),
            Text('Pending re-entry requests: ${_reentryRequests.length}'),
            if (firstReentryRequest != null)
              Text('First request: ${firstReentryRequest.name}'),
            const SizedBox(height: 12),
            if (_reentryRequests.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isConnected ? _approveNextReentryRequest : null,
                  icon: const Icon(Icons.how_to_reg_outlined),
                  label: const Text('Accept First Re-entry Request'),
                ),
              ),
            if (_reentryRequests.isNotEmpty && _queue.isNotEmpty)
              const SizedBox(height: 10),
            if (_queue.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isConnected ? _approveNextInQueue : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Approve First'),
                ),
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
}
