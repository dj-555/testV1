import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class SignalingClient {
  io.Socket? _socket;

  final StreamController<void> _connectController =
      StreamController<void>.broadcast();
  final StreamController<String> _disconnectController =
      StreamController<String>.broadcast();
  final StreamController<int> _reconnectController =
      StreamController<int>.broadcast();

  Stream<void> get onConnectStream => _connectController.stream;

  Stream<String> get onDisconnectStream => _disconnectController.stream;

  Stream<int> get onReconnectStream => _reconnectController.stream;

  bool get isConnected => _socket?.connected ?? false;

  String? get socketId => _socket?.id;

  Future<void> connect(String serverUrl) async {
    await disconnect();

    final completer = Completer<void>();

    debugPrint('[signal] connect -> $serverUrl');

    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableForceNew()
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(2147483647)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint('[signal] connected socketId=${_socket?.id}');
      _connectController.add(null);
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    _socket!.onDisconnect((reason) {
      final reasonText = reason?.toString() ?? 'unknown';
      debugPrint('[signal] disconnected reason=$reasonText');
      _disconnectController.add(reasonText);
    });

    _socket!.onConnectError((error) {
      debugPrint('[signal] connect_error $error');
      if (!completer.isCompleted) {
        completer.completeError(Exception('Socket connect error: $error'));
      }
    });

    _socket!.onError((error) {
      debugPrint('[signal] error $error');
    });

    _socket!.onReconnect((attempt) {
      final parsedAttempt = int.tryParse(attempt.toString()) ?? 0;
      debugPrint('[signal] reconnect success attempt=$parsedAttempt');
      _reconnectController.add(parsedAttempt);
    });

    _socket!.onReconnectAttempt((attempt) {
      debugPrint('[signal] reconnect_attempt=$attempt');
    });

    _socket!.onReconnectError((error) {
      debugPrint('[signal] reconnect_error=$error');
    });

    _socket!.onReconnectFailed((_) {
      debugPrint('[signal] reconnect_failed');
    });

    _socket!.connect();

    await completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw Exception('Socket connect timeout'),
    );
  }

  void on(String event, void Function(dynamic data) handler) {
    _socket?.on(event, handler);
  }

  void off(String event) {
    _socket?.off(event);
  }

  Future<Map<String, dynamic>> request(String event,
      [Map<String, dynamic>? payload]) async {
    if (_socket == null || !(_socket?.connected ?? false)) {
      throw Exception('Socket is not connected');
    }

    final completer = Completer<Map<String, dynamic>>();

    debugPrint('[signal] emitWithAck -> $event payload=${payload ?? {}}');

    _socket!.emitWithAck(
      event,
      payload ?? <String, dynamic>{},
      ack: (dynamic rawAck) {
        if (completer.isCompleted) {
          return;
        }

        final ack = _normalizeAck(rawAck);
        final ok = ack['ok'] == true;

        if (!ok) {
          completer.completeError(
              Exception(ack['error']?.toString() ?? 'Unknown server error'));
          return;
        }

        final data = ack['data'];
        if (data is Map) {
          completer.complete(Map<String, dynamic>.from(data));
          return;
        }

        completer.complete(<String, dynamic>{});
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw Exception('Ack timeout for event "$event"'),
    );
  }

  Map<String, dynamic> _normalizeAck(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
    }

    return {
      'ok': false,
      'error': 'Invalid ack format: $raw',
    };
  }

  Future<void> disconnect() async {
    final socket = _socket;
    if (socket == null) return;

    debugPrint('[signal] disconnecting');

    socket.clearListeners();
    socket.disconnect();
    socket.dispose();
    _socket = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _connectController.close();
    await _disconnectController.close();
    await _reconnectController.close();
  }
}
