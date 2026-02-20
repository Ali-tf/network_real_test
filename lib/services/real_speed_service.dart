import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

// ─── Data Model (unchanged — compatible with your UI) ─────
class RealSpeedResult {
  final double downloadSpeedMbps;
  final double uploadSpeedMbps;
  final bool isDone;
  final String? error;
  final String status;

  RealSpeedResult({
    required this.downloadSpeedMbps,
    this.uploadSpeedMbps = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
  });
}

// ─── Internal: One data-point in the sliding window ───────
// Superseded by SmoothSpeedMeter. Left blank.

// ─── Service ──────────────────────────────────────────────
class RealSpeedHttpService {
  final TestLifecycle _lifecycle = TestLifecycle();
  final DebugLogger _logger = DebugLogger();

  // ── Endpoints ──
  static const _downloadUrl =
      'https://github.com/desktop/desktop/releases/download/release-3.3.13/GitHubDesktopSetup-x64.exe';
  static const _uploadUrl = 'https://speed.cloudflare.com/__up';

  // ── Tunables ──
  static const _testDurationSec = 15; // max seconds per phase
  static const _uiTickMs = 250; // gauge refresh (4 Hz)
  static const _ulChunkBytes = 512 * 1024; // 512 KB upload chunk
  static const _dlWorkerCount = 16;
  static const _ulWorkerCount = 16;
  static const _connectTimeout = Duration(seconds: 10);

  // ═══════════ PUBLIC API ══════════════════════════════════

  void cancel() {
    _lifecycle.cancel();
    _logger.log('[RealSpeed] Cancelled by user.');
  }

  /// Emits live [RealSpeedResult] updates.  The stream closes
  /// automatically when both phases finish (or on error).
  Stream<RealSpeedResult> measureSpeed() {
    _lifecycle.reset();
    final ctrl = StreamController<RealSpeedResult>();
    _run(ctrl);
    return ctrl.stream;
  }

  // ═══════════ ORCHESTRATOR ════════════════════════════════

  Future<void> _run(StreamController<RealSpeedResult> ctrl) async {
    double dlMbps = 0.0;
    double ulMbps = 0.0;

    try {
      // ── Phase 1 ──
      dlMbps = await _download(ctrl);
      if (_lifecycle.isUserCancelled) return;

      // Brief pause so the gauge visually resets
      await Future.delayed(const Duration(milliseconds: 500));

      // ── Phase 2 ──
      ulMbps = await _upload(ctrl, dlMbps);
      if (_lifecycle.isUserCancelled) return;

      // ── Done ──
      if (!ctrl.isClosed) {
        ctrl.add(
          RealSpeedResult(
            downloadSpeedMbps: dlMbps,
            uploadSpeedMbps: ulMbps,
            isDone: true,
            status: 'Done',
          ),
        );
      }
    } catch (e, st) {
      _logger.log('[RealSpeed] Fatal: $e\n$st');
      if (!ctrl.isClosed) {
        ctrl.add(
          RealSpeedResult(
            downloadSpeedMbps: dlMbps,
            uploadSpeedMbps: ulMbps,
            error: e.toString(),
            status: 'Error',
          ),
        );
      }
    } finally {
      if (!ctrl.isClosed) await ctrl.close();
    }
  }

  // ═══════════ DOWNLOAD ════════════════════════════════════
  //  Uses the `http` package — streaming response already
  //  provides natural backpressure (chunks arrive at wire speed).
  // ════════════════════════════════════════════════════════

  Future<double> _download(StreamController<RealSpeedResult> ctrl) async {
    ctrl.add(RealSpeedResult(downloadSpeedMbps: 0, status: 'Downloading…'));

    final httpClient = io.HttpClient()..maxConnectionsPerHost = 64;
    _lifecycle.registerClient(httpClient);

    final meter = SmoothSpeedMeter(totalDurationSeconds: _testDurationSec);
    meter.start();
    _lifecycle.beginPhase();

    // ❶ KILL TIMER — tears down the TCP socket at exactly 15 s.
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      _lifecycle.timeoutPhase();
    });
    _lifecycle.registerTimer(kill);

    // ❷ UI TICKER — records a sample and emits a smoothed speed.
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || _lifecycle.shouldStop) return;
      ctrl.add(
        RealSpeedResult(
          downloadSpeedMbps: meter.tick(),
          status: 'Downloading…',
        ),
      );
    });
    _lifecycle.registerTimer(ui);

    // ❸ WORKER LOOP - Spawn 16 parallel requests running continuously
    for (int w = 0; w < _dlWorkerCount; w++) {
      _lifecycle.launchWorker(() async {
        while (!_lifecycle.shouldStop) {
          try {
            final request = await httpClient
                .getUrl(Uri.parse(_downloadUrl))
                .timeout(_connectTimeout);
            final response = await request.close();

            if (response.statusCode != 200 &&
                response.statusCode != 302 &&
                response.statusCode != 206) {
              await Future.delayed(const Duration(milliseconds: 500));
              continue; // Retry
            }

            final completer = Completer<void>();
            // Continuously read the stream
            response.listen(
              (chunk) {
                if (_lifecycle.shouldStop) {
                  if (!completer.isCompleted) completer.complete();
                  return;
                }
                meter.addBytes(chunk.length);
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
            if (!_lifecycle.shouldStop) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
        }
      });
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    final mbps = meter.finish();
    _logger.log('[DL] Finished at ${mbps.toStringAsFixed(2)} Mbps');
    return mbps;
  }

  // ═══════════ UPLOAD ══════════════════════════════════════
  //  Uses dart:io HttpClient so we can call request.flush(),
  //  which blocks until the OS TCP buffer accepts the data.
  //  This is REAL backpressure — no more in-memory buffering.
  // ════════════════════════════════════════════════════════

  Future<double> _upload(
    StreamController<RealSpeedResult> ctrl,
    double dlMbps,
  ) async {
    ctrl.add(
      RealSpeedResult(
        downloadSpeedMbps: dlMbps,
        uploadSpeedMbps: 0,
        status: 'Connecting…',
      ),
    );

    // ── Build a non-compressible 512 KB chunk ──
    // LCG-style fill so ISP transparent compression can't cheat.
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    final meter = SmoothSpeedMeter(totalDurationSeconds: _testDurationSec);
    meter.start();
    _lifecycle.beginPhase();

    // ❶ KILL TIMER — violently closes ALL sockets on the client.
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      _logger.log('[UL] Kill timer → force-closing HttpClient.');
      _lifecycle.timeoutPhase();
    });
    _lifecycle.registerTimer(kill);

    // ❷ UI TICKER — emits smoothed speed.
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || _lifecycle.shouldStop) return;
      ctrl.add(
        RealSpeedResult(
          downloadSpeedMbps: dlMbps,
          uploadSpeedMbps: meter.tick(),
          status: 'Uploading…',
        ),
      );
    });
    _lifecycle.registerTimer(ui);

    // Create a fresh HttpClient for the upload phase and register it with the lifecycle.
    final httpClient = io.HttpClient();
    _lifecycle.registerClient(httpClient);

    // ❸ WORKER LOOP - Spawn parallel POST requests
    for (int w = 0; w < _ulWorkerCount; w++) {
      _lifecycle.launchWorker(() async {
        io.HttpClientRequest? request;
        try {
          // Open connection (DNS + TCP + TLS handshake happens here).
          request = await httpClient
              .postUrl(Uri.parse(_uploadUrl))
              .timeout(_connectTimeout);
          request.headers.contentType = io.ContentType.binary;
          request.headers.chunkedTransferEncoding = true;

          while (!_lifecycle.shouldStop) {
            request.add(chunk);
            await request.flush(); // ← BLOCKS at network speed
            meter.addBytes(chunk.length); // ← counted AFTER confirmation
          }
        } catch (e) {
          if (!_lifecycle.shouldStop) {
            _logger.log('[UL] W$w write error: $e');
          }
        } finally {
          try {
            if (request != null) {
              final res = await request.close();
              await res.drain();
            }
          } catch (_) {}
        }
      });
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    final mbps = meter.finish();
    _logger.log('[UL] Finished at ${mbps.toStringAsFixed(2)} Mbps');
    return mbps;
  }
}
