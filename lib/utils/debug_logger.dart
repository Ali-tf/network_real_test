import 'package:flutter/foundation.dart';

class DebugLogger {
  // Singleton instance
  static final DebugLogger _instance = DebugLogger._internal();

  factory DebugLogger() {
    return _instance;
  }

  DebugLogger._internal();

  final List<String> _logs = [];
  final List<void Function(String)> _listeners = [];

  List<String> get logs => List.unmodifiable(_logs);

  void log(String message) {
    if (kDebugMode) {
      print("[DebugLogger] $message");
    }
    final timestamp = DateTime.now().toString().split('.').first;
    final formattedMessage = "$timestamp: $message";

    _logs.add(formattedMessage);

    // Notify listeners
    for (var listener in _listeners) {
      listener(formattedMessage);
    }
  }

  void clear() {
    _logs.clear();
    // Notify clear? Usually just UI rebuild.
  }

  void addListener(void Function(String) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(String) listener) {
    _listeners.remove(listener);
  }
}
