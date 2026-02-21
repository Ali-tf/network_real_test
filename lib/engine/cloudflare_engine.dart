import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

/// Cloudflare speed test engine.
///
/// Downloads from `speed.cloudflare.com/__down` (25 MB chunks).
/// Uploads to `speed.cloudflare.com/__up` (1 MB POST payloads).
///
/// This is a "dumb worker" — it handles network I/O only.
/// The [UniversalOrchestrator] owns the meter, timers, and phase lifecycle.
class CloudflareEngine extends SpeedTestEngine {
  // ── Endpoints ──
  static const String _downloadUrl =
      'https://speed.cloudflare.com/__down?bytes=25000000'; // 25 MB
  static const String _uploadUrl = 'https://speed.cloudflare.com/__up';

  // ── Tunables ──
  static const int _workerCount = 16;
  static const int _ulChunkBytes = 512 * 1024; // 512 KB

  @override
  String get engineName => 'Cloudflare';

  @override
  bool get hasDiscovery => false;

  @override
  bool get hasLatencyTest => false;

  @override
  int get phaseDurationSeconds => 15;

  @override
  Future<void> runDownload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    final client = io.HttpClient();
    lifecycle.registerClient(client);

    // Launch parallel download workers
    final workers = <Future<void>>[];
    for (int i = 0; i < _workerCount; i++) {
      workers.add(_downloadWorker(client, lifecycle, onBytes));
    }
    await Future.wait(workers);
  }

  @override
  Future<void> runUpload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    final client = io.HttpClient();
    lifecycle.registerClient(client);

    // Build incompressible payload (shared read-only by all workers)
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    // Launch parallel upload workers
    final workers = <Future<void>>[];
    for (int i = 0; i < _workerCount; i++) {
      workers.add(_uploadWorker(client, lifecycle, onBytes, chunk));
    }
    await Future.wait(workers);
  }

  // ═══════════════════════════════════════════════════════════════
  // WORKERS (pure network I/O — no meter, no timers, no results)
  // ═══════════════════════════════════════════════════════════════

  Future<void> _downloadWorker(
    io.HttpClient client,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
  ) async {
    try {
      while (!lifecycle.shouldStop) {
        final request = await client.getUrl(Uri.parse(_downloadUrl));
        final response = await request.close();

        if (response.statusCode == 200) {
          final completer = Completer<void>();
          response.listen(
            (chunk) {
              if (lifecycle.shouldStop) {
                if (!completer.isCompleted) completer.complete();
                return;
              }
              onBytes(chunk.length);
            },
            onError: (e) {
              if (!completer.isCompleted) completer.complete();
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          );
          await completer.future;
        } else {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (_) {
      // SocketException expected when kill timer fires
    }
  }

  Future<void> _uploadWorker(
    io.HttpClient client,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    Uint8List chunk,
  ) async {
    try {
      while (!lifecycle.shouldStop) {
        final request = await client.postUrl(Uri.parse(_uploadUrl));
        request.contentLength = chunk.length * 2; // Declare 1 MB

        try {
          request.add(chunk); // 512 KB
          await request.flush();
          if (lifecycle.shouldStop) break;
          onBytes(chunk.length);

          request.add(chunk); // 512 KB
          await request.flush();
          if (lifecycle.shouldStop) break;
          onBytes(chunk.length);

          final response = await request.close();
          await response.drain();
        } catch (_) {
          break;
        }
      }
    } catch (_) {
      // SocketException expected when kill timer fires
    }
  }
}
