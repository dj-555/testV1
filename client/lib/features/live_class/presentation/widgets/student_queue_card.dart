import 'package:flutter/material.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/glass_card.dart';

class StudentQueueCard extends StatelessWidget {
  final bool isActive;
  final bool isQueued;
  final int? queuePosition;
  final String activeStudentName;
  final String? nextStudentName;
  final VoidCallback onJoinQueue;
  final VoidCallback onLeaveQueue;

  const StudentQueueCard({
    super.key,
    required this.isActive,
    required this.isQueued,
    required this.queuePosition,
    required this.activeStudentName,
    required this.nextStudentName,
    required this.onJoinQueue,
    required this.onLeaveQueue,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
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
              Text(
                  'Teacher approval pending. Your position is ${queuePosition ?? 0}.')
            else
              const Text(
                'Listen mode only. Ask to talk when you want a turn.',
              ),
            const SizedBox(height: 8),
            Text('Active student: $activeStudentName'),
            if (nextStudentName != null) ...<Widget>[
              const SizedBox(height: 8),
              Text('Next request: $nextStudentName'),
            ],
            if (!isActive) ...<Widget>[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: isQueued
                    ? OutlinedButton.icon(
                        onPressed: onLeaveQueue,
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text('Cancel Request'),
                      )
                    : FilledButton.icon(
                        onPressed: onJoinQueue,
                        icon: const Icon(Icons.record_voice_over),
                        label: const Text('Ask To Talk'),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
