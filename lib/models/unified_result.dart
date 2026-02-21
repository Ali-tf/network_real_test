// Unified result model for all speed test engines.
//
// Replaces the 7 separate result classes (CloudflareResult, FastResult,
// OoklaResult, etc.) with a single type that the UI can consume
// without knowing which engine produced it.

class UnifiedResult {
  /// Current download speed in Mbps (live during test, final when done).
  final double downloadMbps;

  /// Current upload speed in Mbps (live during test, final when done).
  final double uploadMbps;

  /// Latency in milliseconds (only engines that measure it).
  final double? pingMs;

  /// Jitter in milliseconds (only engines that measure it).
  final double? jitterMs;

  /// True when the test has completed successfully.
  final bool isDone;

  /// Non-null if the test encountered an error.
  final String? error;

  /// Human-readable status string for the UI (e.g. "Downloading...", "Complete").
  final String status;

  /// Engine-specific metadata.
  ///
  /// Each engine can put whatever it needs here without polluting
  /// the core model. Examples:
  ///   - Ookla: `{'serverName': '...', 'serverSponsor': '...'}`
  ///   - Akamai: `{'edgeNode': '...', 'edgeIp': '...', 'uploadSource': '...'}`
  ///   - Facebook: `{'cdnEdge': '...', 'assetUsed': '...'}`
  ///   - Google GGC: `{'cacheType': '...', 'nodeLocationId': '...', 'uploadSource': '...'}`
  final Map<String, dynamic> engineMetadata;

  const UnifiedResult({
    required this.downloadMbps,
    this.uploadMbps = 0.0,
    this.pingMs,
    this.jitterMs,
    this.isDone = false,
    this.error,
    this.status = '',
    this.engineMetadata = const {},
  });

  /// Convenience: true if [error] is non-null.
  bool get hasError => error != null;

  /// Create a copy with updated fields (useful for Orchestrator updates).
  UnifiedResult copyWith({
    double? downloadMbps,
    double? uploadMbps,
    double? pingMs,
    double? jitterMs,
    bool? isDone,
    String? error,
    String? status,
    Map<String, dynamic>? engineMetadata,
  }) {
    return UnifiedResult(
      downloadMbps: downloadMbps ?? this.downloadMbps,
      uploadMbps: uploadMbps ?? this.uploadMbps,
      pingMs: pingMs ?? this.pingMs,
      jitterMs: jitterMs ?? this.jitterMs,
      isDone: isDone ?? this.isDone,
      error: error ?? this.error,
      status: status ?? this.status,
      engineMetadata: engineMetadata ?? this.engineMetadata,
    );
  }
}
