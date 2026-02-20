import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

class CloudflareResult {
  final double downloadSpeedMbps;
  final double uploadSpeedMbps;
  final bool isDone;
  final String? error;
  final String status;

  CloudflareResult({
    required this.downloadSpeedMbps,
    this.uploadSpeedMbps = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
  });
}

class CloudflareService {
  final TestLifecycle _lifecycle = TestLifecycle();
  final DebugLogger _logger = DebugLogger();

  // Cloudflare Endpoints
  static const String _downloadUrl =
      "https://speed.cloudflare.com/__down?bytes=25000000"; // 25MB
  static const String _uploadUrl = "https://speed.cloudflare.com/__up";

  void cancel() {
    _lifecycle.cancel();
    _logger.log("[Cloudflare] Cancelled.");
  }

  Stream<CloudflareResult> measureSpeed() {
    final controller = StreamController<CloudflareResult>();
    _lifecycle.reset();

    _startTest(controller);

    return controller.stream;
  }

  Future<void> _startTest(StreamController<CloudflareResult> controller) async {
    try {
      _logger.log("[Cloudflare] Starting test...");
      controller.add(
        CloudflareResult(downloadSpeedMbps: 0, status: "Connecting..."),
      );

      // --- PHASE 1: DOWNLOAD ---
      _logger.log("[Cloudflare] Starting Download phase (15s limit)...");
      controller.add(
        CloudflareResult(downloadSpeedMbps: 0, status: "Preparing download..."),
      );

      _lifecycle.beginPhase();
      final dlMeter = SmoothSpeedMeter(totalDurationSeconds: 15);
      dlMeter.start();

      // Start 16 parallel workers for download
      for (int i = 0; i < 16; i++) {
        _lifecycle.launchWorker(
          () => _downloadWorker((bytes) {
            dlMeter.addBytes(bytes);
          }),
        );
      }

      final finalDownloadMbps = await _monitorPhase(
        controller,
        dlMeter,
        (mbps) => CloudflareResult(
          downloadSpeedMbps: mbps,
          status: "Testing Download...",
        ),
      );

      await _lifecycle.awaitAllWorkers();

      if (_lifecycle.isUserCancelled) {
        controller.close();
        return;
      }

      _logger.log(
        "[Cloudflare] Download result: ${finalDownloadMbps.toStringAsFixed(2)} Mbps",
      );

      // --- PHASE 2: UPLOAD ---
      _logger.log("[Cloudflare] Starting Upload phase (15s limit)...");
      controller.add(
        CloudflareResult(
          downloadSpeedMbps: finalDownloadMbps,
          uploadSpeedMbps: 0,
          status: "Preparing upload...",
        ),
      );

      _lifecycle.beginPhase();
      final ulMeter = SmoothSpeedMeter(totalDurationSeconds: 15);
      ulMeter.start();

      // Start 16 parallel workers for upload requires chunked data for interruptibility
      for (int i = 0; i < 16; i++) {
        _lifecycle.launchWorker(
          () => _uploadWorker((bytes) {
            ulMeter.addBytes(bytes);
          }),
        );
      }

      final finalUploadMbps = await _monitorPhase(
        controller,
        ulMeter,
        (mbps) => CloudflareResult(
          downloadSpeedMbps: finalDownloadMbps,
          uploadSpeedMbps: mbps,
          isDone: false,
          status: "Testing Upload...",
        ),
      );

      await _lifecycle.awaitAllWorkers();

      if (_lifecycle.isUserCancelled) {
        controller.close();
        return;
      }

      _logger.log(
        "[Cloudflare] Upload result: ${finalUploadMbps.toStringAsFixed(2)} Mbps",
      );

      // Done
      if (!controller.isClosed) {
        controller.add(
          CloudflareResult(
            downloadSpeedMbps: finalDownloadMbps,
            uploadSpeedMbps: finalUploadMbps,
            isDone: true,
            status: "Complete",
          ),
        );
        _logger.log("[Cloudflare] Test Complete.");
        controller.close();
      }
    } catch (e) {
      final errorMsg = "[Cloudflare] Error: $e";
      _logger.log(errorMsg);
      if (!controller.isClosed) {
        controller.add(
          CloudflareResult(
            downloadSpeedMbps: 0,
            error: e.toString(),
            status: "Failed",
          ),
        );
        controller.close();
      }
    }
  }

  Future<double> _monitorPhase(
    StreamController<CloudflareResult> controller,
    SmoothSpeedMeter meter,
    CloudflareResult Function(double mbps) createResult,
  ) async {
    final killTimer = Timer(const Duration(seconds: 15), () {
      _logger.log('[Cloudflare] Phase timeout (15s).');
      _lifecycle.timeoutPhase();
    });
    _lifecycle.registerTimer(killTimer);

    final uiTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (controller.isClosed || _lifecycle.shouldStop) {
        timer.cancel();
        return;
      }
      controller.add(createResult(meter.tick()));
    });
    _lifecycle.registerTimer(uiTimer);

    await _lifecycle.awaitPhaseComplete();

    return meter.finish();
  }

  Future<void> _downloadWorker(Function(int) onBytes) async {
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    try {
      while (!_lifecycle.shouldStop) {
        final request = await client.getUrl(Uri.parse(_downloadUrl));
        final response = await request.close();

        if (response.statusCode == 200) {
          final completer = Completer<void>();
          response.listen(
            (chunk) {
              if (_lifecycle.shouldStop) {
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
      // Ignore network errors or socket closures gracefully
    }
  }

  Future<void> _uploadWorker(Function(int) onBytes) async {
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    // Chunk size: 512 KB
    final chunk = Uint8List(512 * 1024);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF; // Incompressible dummy data
    }

    try {
      while (!_lifecycle.shouldStop) {
        final request = await client.postUrl(Uri.parse(_uploadUrl));

        // Disable automatic header chunking to avoid protocol confusion
        // if the server doesn't like generic chunked POST uploads,
        // but we don't know the exact length upfront if we just loop write.
        // Actually, many CDNs reject un-lengthed POSTs. So we declare 1MB,
        // and send 1MB.
        request.contentLength = chunk.length * 2; // Declare 1 MB

        try {
          request.add(chunk); // 512 KB
          await request.flush();
          if (_lifecycle.shouldStop) break;
          onBytes(chunk.length);

          request.add(chunk); // 512 KB
          await request.flush();
          if (_lifecycle.shouldStop) break;
          onBytes(chunk.length);

          final response = await request.close();
          // Consume the response body to recycle the connection
          await response.drain();
        } catch (_) {
          break;
        }
      }
    } catch (_) {
      // Ignore network errors
    }
  }
}
