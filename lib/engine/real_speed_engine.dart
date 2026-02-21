import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

/// Real Speed engine — simple HTTP GET download + Cloudflare POST upload.
///
/// Downloads from GitHub (large binary), uploads to Cloudflare __up.
/// No discovery, no latency measurement.
class RealSpeedEngine extends SpeedTestEngine {
  static const String _downloadUrl =
      'https://github.com/desktop/desktop/releases/download/release-3.3.13/GitHubDesktopSetup-x64.exe';
  static const String _uploadUrl = 'https://speed.cloudflare.com/__up';

  static const int _dlWorkerCount = 16;
  static const int _ulWorkerCount = 16;
  static const int _ulChunkBytes = 512 * 1024;
  static const Duration _connectTimeout = Duration(seconds: 10);

  @override
  String get engineName => 'Real Speed';

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

    final workers = <Future<void>>[];
    for (int w = 0; w < _dlWorkerCount; w++) {
      workers.add(() async {
        while (!lifecycle.shouldStop) {
          try {
            final request = await client
                .getUrl(Uri.parse(_downloadUrl))
                .timeout(_connectTimeout);
            final response = await request.close();

            if (response.statusCode != 200 &&
                response.statusCode != 302 &&
                response.statusCode != 206) {
              await Future.delayed(const Duration(milliseconds: 500));
              continue;
            }

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
          } catch (e) {
            if (!lifecycle.shouldStop) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
        }
      }());
    }
    await Future.wait(workers);
  }

  @override
  Future<void> runUpload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    // Build incompressible payload (shared read-only by all workers)
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    final client = io.HttpClient();
    lifecycle.registerClient(client);

    final workers = <Future<void>>[];
    for (int w = 0; w < _ulWorkerCount; w++) {
      workers.add(() async {
        io.HttpClientRequest? request;
        try {
          request = await client
              .postUrl(Uri.parse(_uploadUrl))
              .timeout(_connectTimeout);
          request.headers.contentType = io.ContentType.binary;
          request.headers.chunkedTransferEncoding = true;

          while (!lifecycle.shouldStop) {
            request.add(chunk);
            await request.flush();
            onBytes(chunk.length);
          }
        } catch (_) {
        } finally {
          try {
            if (request != null) {
              final res = await request.close();
              await res.drain();
            }
          } catch (_) {}
        }
      }());
    }
    await Future.wait(workers);
  }
}
