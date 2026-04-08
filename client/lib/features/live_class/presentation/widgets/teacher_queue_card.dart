import 'package:flutter/material.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/glass_card.dart';
import 'package:quran_live_class_client/webrtc_client.dart';

class TeacherQueueCard extends StatelessWidget {
  final String activeStudentName;
  final String nextStudentName;
  final List<QueueEntry> queue;
  final String approveLabel;
  final bool canApprove;
  final bool canEndTurn;
  final VoidCallback onApproveNext;
  final VoidCallback onEndTurn;

  const TeacherQueueCard({
    super.key,
    required this.activeStudentName,
    required this.nextStudentName,
    required this.queue,
    required this.approveLabel,
    required this.canApprove,
    required this.canEndTurn,
    required this.onApproveNext,
    required this.onEndTurn,
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
              'Queue Control',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Active: $activeStudentName'),
            Text('Next in queue: $nextStudentName'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canApprove ? onApproveNext : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(approveLabel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canEndTurn ? onEndTurn : null,
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
            if (queue.isEmpty)
              const Text('No students waiting')
            else
              Column(
                children: queue.asMap().entries.map((entry) {
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
