import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class SignalingClient {
  io.Socket? _socket;
  static const Duration _singleConnectTimeout = Duration(seconds: 8);

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

  Future<void> connect(
    String serverUrl, {
    String socketPath = '/socket.io',
  }) async {
    await disconnect();

    final normalizedSocketPath = _normalizeSocketPath(socketPath);
    final connectionCandidates = _buildConnectionCandidates(serverUrl);
    final attemptErrors = <String>[];

    for (int i = 0; i < connectionCandidates.length; i++) {
      final candidateUrl = connectionCandidates[i];
      final attempt = i + 1;
      try {
        debugPrint(
            '[signal] connect attempt $attempt/${connectionCandidates.length} -> $candidateUrl path=$normalizedSocketPath');
        await _connectToSingleServer(
          candidateUrl,
          socketPath: normalizedSocketPath,
        );
        return;
      } catch (error, stackTrace) {
        final errorText = error.toString();
        attemptErrors.add('$candidateUrl => $errorText');
        debugPrint('[signal] connect attempt failed: $errorText');
        debugPrintStack(stackTrace: stackTrace);
        await disconnect();
      }
    }

    final attempted = connectionCandidates.join(', ');
    throw Exception(
      'Socket connect failed on all endpoints. '
      'Tried: $attempted. '
      'Details: ${attemptErrors.join(' | ')}',
    );
  }

  Future<void> _connectToSingleServer(
    String serverUrl, {
    required String socketPath,
  }) async {
    final completer = Completer<void>();

    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setPath(socketPath)
          .setTransports(<String>['websocket', 'polling'])
          .enableForceNew()
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(2147483647)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint(
          '[signal] connected socketId=${_socket?.id} via $serverUrl path=$socketPath');
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
      debugPrint('[signal] connect_error=$error server=$serverUrl');
      if (!completer.isCompleted) {
        completer.completeError(Exception(error.toString()));
      }
    });

    _socket!.onError((error) {
      debugPrint('[signal] error=$error server=$serverUrl');
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
      _singleConnectTimeout,
      onTimeout: () => throw Exception('Socket connect timeout for $serverUrl'),
    );
  }

  String _normalizeSocketPath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return '/socket.io';
    if (trimmed.startsWith('/')) return trimmed;
    return '/$trimmed';
  }

  List<String> _buildConnectionCandidates(String rawUrl) {
    final normalized = _normalizeSocketServerUrl(rawUrl);
    final base = Uri.parse(normalized);
    final candidates = <String>[];

    void addCandidate(Uri uri) {
      final value = uri.toString().split('#').first;
      if (!candidates.contains(value)) {
        candidates.add(value);
      }
    }

    addCandidate(base);

    if (base.scheme == 'https') {
      addCandidate(base.replace(scheme: 'http', port: 3000));
      if (base.port != 443) {
        addCandidate(base.replace(scheme: 'https', port: 443));
      }
    } else {
      addCandidate(base.replace(scheme: 'https', port: null));
      addCandidate(base.replace(scheme: 'https', port: 443));
      if (base.port != 3000) {
        addCandidate(base.replace(scheme: 'http', port: 3000));
      }
    }

    return candidates;
  }

  String _normalizeSocketServerUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw Exception('Server URL is required');
    }

    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+\-.]*://').hasMatch(trimmed);
    final candidate = hasScheme ? trimmed : 'https://$trimmed';

    Uri uri;
    try {
      uri = Uri.parse(candidate);
    } catch (_) {
      throw Exception('Invalid server URL: "$rawUrl"');
    }

    var scheme = uri.scheme.toLowerCase();
    if (scheme == 'ws') {
      scheme = 'http';
    } else if (scheme == 'wss') {
      scheme = 'https';
    }

    if (scheme != 'http' && scheme != 'https') {
      throw Exception(
        'Invalid URL scheme "$scheme". Use http://, https://, ws://, or wss://.',
      );
    }

    if (uri.host.isEmpty) {
      throw Exception('Invalid server URL: missing host');
    }

    return uri.replace(scheme: scheme).toString().split('#').first;
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
