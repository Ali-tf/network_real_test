import 'dart:async';

import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/models/unified_result.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

/// Central brain that decouples engine logic from phase management.
///
/// Responsibilities:
///   - Owns the [TestLifecycle] (cancel, timeout, socket registry)
///   - Owns the [SmoothSpeedMeter] (centralized — engines never touch it)
///   - Owns kill timers and UI timers
///   - Drives phase transitions: Discovery → Latency → Download → Upload
///   - Emits [UnifiedResult] to a single stream consumed by the UI
///
/// The engine is a "dumb worker" — it just calls `onBytes(n)`.
class UniversalOrchestrator {
  final DebugLogger _logger = DebugLogger();
  final TestLifecycle _lifecycle = TestLifecycle();

  /// True while a test is actively running.
  bool get isRunning => _isRunning;
  bool _isRunning = false;

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API
  // ═══════════════════════════════════════════════════════════════

  /// Start a speed test using the given [engine].
  ///
  /// Returns a stream of [UnifiedResult] events that the UI listens to.
  /// The stream closes automatically when the test finishes or is cancelled.
  Stream<UnifiedResult> start(SpeedTestEngine engine) {
    final controller = StreamController<UnifiedResult>();
    _lifecycle.reset();
    _isRunning = true;
    _run(engine, controller);
    return controller.stream;
  }

  /// Cancel the currently running test.
  ///
  /// Force-closes all registered sockets and clients instantly.
  void cancel() {
    _lifecycle.cancel();
    _isRunning = false;
    _logger.log('[Orchestrator] Cancel requested.');
  }

  // ═══════════════════════════════════════════════════════════════
  // PIPELINE
  // ═══════════════════════════════════════════════════════════════

  Future<void> _run(
    SpeedTestEngine engine,
    StreamController<UnifiedResult> ctrl,
  ) async {
    double dlMbps = 0.0;
    double ulMbps = 0.0;
    double? pingMs;
    double? jitterMs;
    Map<String, dynamic> metadata = {};

    try {
      _logger.log('[Orchestrator] ═══ Starting ${engine.engineName} ═══');

      // ── Phase 0: Discovery (optional) ──
      if (engine.hasDiscovery) {
        _emit(
          ctrl,
          UnifiedResult(
            downloadMbps: 0,
            status: 'Discovering ${engine.engineName} endpoints...',
          ),
        );

        metadata = await engine.discover(_lifecycle) ?? {};
        if (_lifecycle.isUserCancelled) return;

        if (metadata.isEmpty && engine.hasDiscovery) {
          throw Exception('${engine.engineName} discovery failed.');
        }

        _logger.log('[Orchestrator] Discovery complete: ${metadata.keys}');
      }

      // ── Phase 1: Latency (optional) ──
      if (engine.hasLatencyTest) {
        _emit(
          ctrl,
          UnifiedResult(
            downloadMbps: 0,
            status: 'Measuring latency...',
            engineMetadata: metadata,
          ),
        );

        final latency = await engine.measureLatency(_lifecycle);
        pingMs = latency['ping'];
        jitterMs = latency['jitter'];
        if (_lifecycle.isUserCancelled) return;

        _logger.log(
          '[Orchestrator] Ping: ${pingMs?.toStringAsFixed(1)}ms, '
          'Jitter: ${jitterMs?.toStringAsFixed(1)}ms',
        );

        _emit(
          ctrl,
          UnifiedResult(
            downloadMbps: 0,
            pingMs: pingMs,
            jitterMs: jitterMs,
            status: 'Ping: ${pingMs?.toStringAsFixed(0)}ms',
            engineMetadata: metadata,
          ),
        );

        await Future.delayed(const Duration(milliseconds: 400));
        if (_lifecycle.isUserCancelled) return;
      }

      // ── Phase 2: Download ──
      _logger.log('[Orchestrator] ── Download Phase ──');

      dlMbps = await _runPhase(
        engine: engine,
        ctrl: ctrl,
        metadata: metadata,
        isDownload: true,
        previousDl: 0,
        pingMs: pingMs,
        jitterMs: jitterMs,
      );

      if (_lifecycle.isUserCancelled) return;
      _logger.log('[Orchestrator] Download: ${dlMbps.toStringAsFixed(2)} Mbps');

      await Future.delayed(const Duration(milliseconds: 500));

      // ── Phase 3: Upload (optional) ──
      if (engine.hasUpload) {
        _logger.log('[Orchestrator] ── Upload Phase ──');

        ulMbps = await _runPhase(
          engine: engine,
          ctrl: ctrl,
          metadata: metadata,
          isDownload: false,
          previousDl: dlMbps,
          pingMs: pingMs,
          jitterMs: jitterMs,
        );

        if (_lifecycle.isUserCancelled) return;
        _logger.log('[Orchestrator] Upload: ${ulMbps.toStringAsFixed(2)} Mbps');
      }

      // ── Done ──
      _emit(
        ctrl,
        UnifiedResult(
          downloadMbps: dlMbps,
          uploadMbps: ulMbps,
          pingMs: pingMs,
          jitterMs: jitterMs,
          isDone: true,
          status: 'Complete',
          engineMetadata: metadata,
        ),
      );

      _logger.log('[Orchestrator] ═══ ${engine.engineName} Complete ═══');
    } catch (e, st) {
      _logger.log('[Orchestrator] FATAL: $e\n$st');
      _emit(
        ctrl,
        UnifiedResult(
          downloadMbps: dlMbps,
          uploadMbps: ulMbps,
          pingMs: pingMs,
          jitterMs: jitterMs,
          error: e.toString(),
          status: 'Error',
          engineMetadata: metadata,
        ),
      );
    } finally {
      _isRunning = false;
      if (!ctrl.isClosed) await ctrl.close();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PHASE RUNNER (shared between DL and UL)
  // ═══════════════════════════════════════════════════════════════

  Future<double> _runPhase({
    required SpeedTestEngine engine,
    required StreamController<UnifiedResult> ctrl,
    required Map<String, dynamic> metadata,
    required bool isDownload,
    required double previousDl,
    double? pingMs,
    double? jitterMs,
  }) async {
    final phaseLabel = isDownload ? 'Download' : 'Upload';

    _emit(
      ctrl,
      UnifiedResult(
        downloadMbps: isDownload ? 0 : previousDl,
        uploadMbps: 0,
        pingMs: pingMs,
        jitterMs: jitterMs,
        status: 'Starting $phaseLabel...',
        engineMetadata: metadata,
      ),
    );

    final meter = SmoothSpeedMeter(
      totalDurationSeconds: engine.phaseDurationSeconds,
    );
    meter.start();
    _lifecycle.beginPhase();

    // ❶ KILL TIMER — force-close all sockets at the deadline
    final killTimer = Timer(Duration(seconds: engine.phaseDurationSeconds), () {
      _logger.log('[Orchestrator] $phaseLabel kill timer → timeout.');
      _lifecycle.timeoutPhase();
    });
    _lifecycle.registerTimer(killTimer);

    // ❷ UI TICKER — emits smoothed speed every 200ms
    final uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (ctrl.isClosed || _lifecycle.shouldStop) return;
      _emit(
        ctrl,
        UnifiedResult(
          downloadMbps: isDownload ? meter.tick() : previousDl,
          uploadMbps: isDownload ? 0 : meter.tick(),
          pingMs: pingMs,
          jitterMs: jitterMs,
          status: 'Testing $phaseLabel...',
          engineMetadata: metadata,
        ),
      );
    });
    _lifecycle.registerTimer(uiTimer);

    // ❸ ENGINE WORK — the engine is a dumb worker that calls onBytes(n)
    _lifecycle.launchWorker(() async {
      if (isDownload) {
        await engine.runDownload(
          _lifecycle,
          (bytes) => meter.addBytes(bytes),
          metadata,
        );
      } else {
        await engine.runUpload(
          _lifecycle,
          (bytes) => meter.addBytes(bytes),
          metadata,
        );
      }
      // Signal phase complete when engine finishes naturally
      _lifecycle.completePhase();
    });

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    return meter.finish();
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════

  void _emit(StreamController<UnifiedResult> ctrl, UnifiedResult result) {
    if (!ctrl.isClosed) ctrl.add(result);
  }
}
