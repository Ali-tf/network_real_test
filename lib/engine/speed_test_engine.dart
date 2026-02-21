import 'package:network_speed_test/utils/test_lifecycle.dart';

/// Abstract interface that every speed test engine must implement.
///
/// The engine is a "dumb worker" — it knows HOW to talk to its CDN/server,
/// but it does NOT manage:
///   - The SmoothSpeedMeter (the Orchestrator owns it)
///   - Phase transitions (the Orchestrator decides when to start/stop)
///   - Kill timers or UI timers (the Orchestrator manages those)
///   - The StreamController or result emission
///
/// The engine just calls `onBytes(n)` as data flows, and the Orchestrator
/// handles everything else.
abstract class SpeedTestEngine {
  /// Human-readable name for logging and UI display.
  /// Example: "Cloudflare", "Fast.com", "Ookla"
  String get engineName;

  /// Whether this engine supports a discovery/server-selection phase.
  ///
  /// If false, [discover] will not be called.
  bool get hasDiscovery => false;

  /// Whether this engine supports latency measurement.
  ///
  /// If false, [measureLatency] will not be called.
  bool get hasLatencyTest => false;

  /// Whether this engine supports upload testing.
  ///
  /// If false, [runUpload] will not be called.
  bool get hasUpload => true;

  /// Number of seconds for each test phase (download/upload).
  /// The Orchestrator uses this to configure the kill timer and meter.
  int get phaseDurationSeconds => 15;

  /// Optional: Discover servers, endpoints, or CDN nodes.
  ///
  /// Called before download/upload phases. Returns engine-specific metadata
  /// that will be included in every [UnifiedResult.engineMetadata].
  ///
  /// The [lifecycle] is provided so the engine can register any HttpClients
  /// or Sockets it creates, and check [lifecycle.shouldStop] for cancellation.
  ///
  /// Returns null if discovery fails (the Orchestrator will throw).
  Future<Map<String, dynamic>?> discover(TestLifecycle lifecycle) async {
    return {};
  }

  /// Optional: Measure ping and jitter to the test target.
  ///
  /// Returns a map with keys 'ping' and 'jitter' (both in ms).
  /// Called after [discover] and before download.
  Future<Map<String, double>> measureLatency(TestLifecycle lifecycle) async {
    return {'ping': 0.0, 'jitter': 0.0};
  }

  /// Core: Run the download test.
  ///
  /// The engine should:
  ///   1. Create HttpClient(s) and register them with [lifecycle]
  ///   2. Launch parallel workers that download data
  ///   3. Call [onBytes(n)] every time a chunk arrives from the network
  ///   4. Check [lifecycle.shouldStop] in worker loops to exit cleanly
  ///   5. Return when all workers have finished
  ///
  /// The engine does NOT:
  ///   - Create or manage a SmoothSpeedMeter
  ///   - Set up kill timers or UI timers
  ///   - Emit results to a StreamController
  ///
  /// [metadata] is the result from [discover], passed through for engines
  /// that need discovery data to construct download URLs.
  Future<void> runDownload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  );

  /// Core: Run the upload test.
  ///
  /// Same contract as [runDownload] but for upload.
  /// Call [onBytes(n)] AFTER bytes are confirmed flushed to the network
  /// (i.e., after `request.flush()` succeeds), never at buffer-write time.
  Future<void> runUpload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  );
}
