part of '../quran_live_class_page.dart';

extension _QuranLiveClassPageConnectionWidgets on _QuranLiveClassPageState {
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
                      _applyRoleSelection(value);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              enabled: !_isConnected,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Server: $_serverUrl',
              style: TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Socket path: $_socketPath',
              style: TextStyle(
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
}
