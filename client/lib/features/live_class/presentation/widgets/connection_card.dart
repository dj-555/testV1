import 'package:flutter/material.dart';
import 'package:quran_live_class_client/features/live_class/presentation/widgets/glass_card.dart';

class ConnectionCard extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController serverController;
  final String selectedRole;
  final bool isConnected;
  final bool isBusy;
  final String status;
  final ValueChanged<String?> onRoleChanged;
  final VoidCallback onToggleConnection;

  const ConnectionCard({
    super.key,
    required this.nameController,
    required this.serverController,
    required this.selectedRole,
    required this.isConnected,
    required this.isBusy,
    required this.status,
    required this.onRoleChanged,
    required this.onToggleConnection,
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
              'Connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedRole,
              decoration: const InputDecoration(labelText: 'Role'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'teacher', child: Text('Teacher')),
                DropdownMenuItem(value: 'student', child: Text('Student')),
              ],
              onChanged: isConnected ? null : onRoleChanged,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              enabled: !isConnected,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: serverController,
              enabled: !isConnected,
              decoration: const InputDecoration(labelText: 'Server URL'),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                ElevatedButton(
                  onPressed: isBusy ? null : onToggleConnection,
                  child: Text(isConnected ? 'Disconnect' : 'Connect'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Status: $status',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
