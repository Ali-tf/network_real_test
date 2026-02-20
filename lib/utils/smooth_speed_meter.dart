import 'dart:math' as math;
import 'dart:typed_data';

/// A universal, Fast.com-style smooth speed meter.
///
/// Three-layer architecture:
///   Layer 1 — Accumulator : monotonic byte counter (ground truth)
///   Layer 2 — Estimator   : 3 s sliding window via ring buffer (jitter removal)
///   Layer 3 — Display EMA : adaptive exponential smoothing (visual inertia)
///
/// Usage (identical for every test — FNA, Real, Cloudflare, Ookla):
///   1. final meter = SmoothSpeedMeter(totalDurationSeconds: 15);
///   2. meter.start();
///   3. In every socket callback  → meter.addBytes(chunk.length);
///   4. In UI timer (every 200ms) → final mbps = meter.tick();
///   5. When phase ends            → final result = meter.finish();
class SmoothSpeedMeter {
  /// Expected duration of this test phase. Controls alpha decay curve.
  final int totalDurationSeconds;

  // ═══ Layer 1: Accumulator ═════════════════════════════════
  // Monotonic Stopwatch — immune to NTP wall-clock jumps.
  final Stopwatch _sw = Stopwatch();
  int _totalBytes = 0;
  bool _hasData = false;
  int _firstDataUs = 0; // Stopwatch µs when first byte arrived

  // ═══ Layer 2: Ring Buffer ═════════════════════════════════
  // Power-of-2 size → branchless modulo via bitmask.
  // 64 slots × 200 ms = 12.8 s of history. Window reads 15 slots (3 s).
  // Two parallel Int64Lists: zero allocation, zero GC, cache-contiguous.
  static const int _ringSize = 64;
  static const int _ringMask = _ringSize - 1; // 0x3F — replaces % operator
  static const int _windowTicks = 15; // 3 s ÷ 0.2 s per tick
  final Int64List _ringUs = Int64List(_ringSize);
  final Int64List _ringBytes = Int64List(_ringSize);
  int _head = 0;

  // ═══ Layer 3: Display EMA ═════════════════════════════════
  double _displayMbps = 0.0;

  // ═══ Tuning Constants ═════════════════════════════════════
  static const double _riseAlpha = 0.15; // Needle rises at this rate
  static const double _fallAlpha = 0.08; // Needle falls slower (feels natural)
  static const double _coldAlpha = 0.30; // Fast ramp during first 3 s
  static const double _decayFactor =
      0.7; // Alpha shrinks by up to 70% at test end

  SmoothSpeedMeter({required this.totalDurationSeconds});

  // ═══ Public Getters ═══════════════════════════════════════

  /// Last computed smoothed value. Safe to read from animation frames
  /// without triggering a recalculation.
  double get displayMbps => _displayMbps;

  /// True mathematical average from first byte to now.
  /// Use this for the final result card — never use displayMbps for that.
  double get overallMbps {
    if (!_hasData || _totalBytes <= 0) return 0.0;
    final elapsed = _sw.elapsedMicroseconds - _firstDataUs;
    return elapsed > 0 ? (_totalBytes * 8.0) / elapsed : 0.0;
  }

  /// Total bytes accumulated so far (useful for logging).
  int get totalBytes => _totalBytes;

  // ═══ Lifecycle ════════════════════════════════════════════

  /// Call once before the test phase begins. Resets everything.
  void start() {
    _totalBytes = 0;
    _hasData = false;
    _firstDataUs = 0;
    _displayMbps = 0.0;
    _head = 0;
    _ringUs.fillRange(0, _ringSize, 0);
    _ringBytes.fillRange(0, _ringSize, 0);
    _sw.reset();
    _sw.start();
  }

  /// Called by socket/stream callbacks as bytes arrive (download)
  /// or are confirmed flushed (upload). This is the ONLY data input.
  void addBytes(int n) {
    _totalBytes += n;
    if (!_hasData) {
      _hasData = true;
      _firstDataUs = _sw.elapsedMicroseconds;
    }
  }

  /// Called by the UI timer every ~200 ms.
  /// Returns the smoothed speed in Mbps for the gauge/needle.
  double tick() {
    if (!_hasData) return 0.0;

    final nowUs = _sw.elapsedMicroseconds;
    final head = _head;

    // ── Step 1: Record current sample into ring ──
    _ringUs[head & _ringMask] = nowUs;
    _ringBytes[head & _ringMask] = _totalBytes;

    // ── Step 2: Compute windowed throughput ──
    // Use as much history as available, up to 15 ticks (3 seconds).
    final lookback = math.min(head, _windowTicks);
    double rawMbps = 0.0;

    if (lookback > 0) {
      final tailIdx = (head - lookback) & _ringMask;
      final dBytes = _totalBytes - _ringBytes[tailIdx];
      final dUs = nowUs - _ringUs[tailIdx];
      // 1 byte/µs = 8 Mbit/s, so (bytes × 8) / µs = Mbps
      if (dUs > 0) rawMbps = (dBytes * 8.0) / dUs;
    }

    _head = head + 1;

    // ── Step 3: Compute adaptive alpha ──
    // Progress is measured from FIRST DATA, not from start().
    // This excludes connection setup time from the decay curve.
    final dataElapsedSec = (nowUs - _firstDataUs) / 1000000.0;
    final progress = math.min(1.0, dataElapsedSec / totalDurationSeconds);
    final decay = 1.0 - progress * _decayFactor;

    // Steady-state alpha: directional bias × progress decay
    final steadyAlpha =
        (rawMbps >= _displayMbps ? _riseAlpha : _fallAlpha) * decay;

    double alpha;
    if (lookback < _windowTicks) {
      // Cold start: linear blend from _coldAlpha → steadyAlpha
      // as the window fills. Eliminates the hard discontinuity
      // that would occur with a sudden switch at tick 15.
      final warmth = lookback / _windowTicks; // 0.0 → 1.0 over 3 s
      alpha = _coldAlpha + warmth * (steadyAlpha - _coldAlpha);
    } else {
      alpha = steadyAlpha;
    }

    // ── Step 4: Apply EMA ──
    _displayMbps += alpha * (rawMbps - _displayMbps);

    // Floor: sub-0.01 values during brief TCP stalls look like errors.
    // Clamp to zero so the needle parks cleanly instead of flickering.
    if (_displayMbps < 0.01) _displayMbps = 0.0;

    return _displayMbps;
  }

  /// Stops the clock and returns the true overall average.
  /// After this call, [overallMbps] and [displayMbps] remain readable.
  double finish() {
    _sw.stop();
    return overallMbps;
  }
}
