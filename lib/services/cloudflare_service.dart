import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:network_speed_test/utils/debug_logger.dart';

class CloudflareResult {
  final double downloadSpeedMbps;
  final double uploadSpeedMbps;
  final bool isDone;
  final String? error;
  final String status; // New status field

  CloudflareResult({
    required this.downloadSpeedMbps,
    this.uploadSpeedMbps = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
  });
}

class CloudflareService {
  bool _isCancelled = false;
  final DebugLogger _logger = DebugLogger();

  // Cloudflare Endpoints
  static const String _downloadUrl =
      "https://speed.cloudflare.com/__down?bytes=25000000"; // 25MB
  static const String _uploadUrl = "https://speed.cloudflare.com/__up";

  void cancel() {
    _isCancelled = true;
    _logger.log("[Cloudflare] Cancelled.");
  }

  Stream<CloudflareResult> measureSpeed() {
    final controller = StreamController<CloudflareResult>();
    _isCancelled = false;

    _startTest(controller);

    return controller.stream;
  }

  Future<void> _startTest(StreamController<CloudflareResult> controller) async {
    final client = http.Client();
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

      int totalBytesRead = 0;
      final downloadStartTime = DateTime.now();

      // Start 4 parallel workers for download
      for (int i = 0; i < 4; i++) {
        _downloadWorker(client, (bytes) {
          totalBytesRead += bytes;
        });
      }

      await _monitorPhase(
        controller,
        downloadStartTime,
        () => totalBytesRead,
        (mbps) => CloudflareResult(
          downloadSpeedMbps: mbps,
          status: "Testing Download...",
        ),
      );

      if (_isCancelled) {
        client.close();
        controller.close();
        return;
      }

      // Calculate final download speed
      final downloadElapsed = DateTime.now()
          .difference(downloadStartTime)
          .inMilliseconds;
      final double finalDownloadMbps =
          (totalBytesRead * 8 * 1000) / (downloadElapsed * 1000000);

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

      int totalBytesSent = 0;
      final uploadStartTime = DateTime.now();

      // Start 4 parallel workers for upload
      for (int i = 0; i < 4; i++) {
        _uploadWorker(client, (bytes) {
          totalBytesSent += bytes;
        });
      }

      await _monitorPhase(
        controller,
        uploadStartTime,
        () => totalBytesSent,
        (mbps) => CloudflareResult(
          downloadSpeedMbps: finalDownloadMbps,
          uploadSpeedMbps: mbps,
          isDone: false,
          status: "Testing Upload...",
        ),
      );

      client.close();

      if (_isCancelled) {
        controller.close();
        return;
      }

      final uploadElapsed = DateTime.now()
          .difference(uploadStartTime)
          .inMilliseconds;
      final double finalUploadMbps =
          (totalBytesSent * 8 * 1000) / (uploadElapsed * 1000000);

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
      client.close();
    }
  }

  Future<void> _monitorPhase(
    StreamController<CloudflareResult> controller,
    DateTime startTime,
    int Function() getBytes,
    CloudflareResult Function(double mbps) createResult,
  ) async {
    final completer = Completer<void>();

    Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (controller.isClosed || _isCancelled) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
        return;
      }

      final elapsed = DateTime.now().difference(startTime).inMilliseconds;

      if (elapsed > 15000) {
        // 15s Timeout
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
        return;
      }

      if (elapsed > 0) {
        final double mbps = (getBytes() * 8 * 1000) / (elapsed * 1000000);
        controller.add(createResult(mbps));
      }
    });

    await completer.future;
  }

  Future<void> _downloadWorker(
    http.Client client,
    Function(int) onBytes,
  ) async {
    final phaseEndTime = DateTime.now().add(const Duration(seconds: 15));

    while (!_isCancelled && DateTime.now().isBefore(phaseEndTime)) {
      try {
        final request = http.Request('GET', Uri.parse(_downloadUrl));
        final response = await client.send(request);

        if (response.statusCode == 200) {
          final completer = Completer<void>();
          StreamSubscription? subscription;

          subscription = response.stream.listen(
            (chunk) {
              if (_isCancelled || DateTime.now().isAfter(phaseEndTime)) {
                subscription?.cancel();
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
          );
          await completer.future;
        } else {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _uploadWorker(http.Client client, Function(int) onBytes) async {
    final phaseEndTime = DateTime.now().add(const Duration(seconds: 15));
    final payload = Uint8List(1024 * 1024); // 1MB dummy data

    while (!_isCancelled && DateTime.now().isBefore(phaseEndTime)) {
      try {
        final response = await client.post(
          Uri.parse(_uploadUrl),
          body: payload,
        );

        if (response.statusCode == 200) {
          onBytes(payload.length);
        } else {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}
