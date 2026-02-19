import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:network_speed_test/utils/debug_logger.dart';

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

// ─── Internal: one data-point in the sliding window ───────
class _Sample {
  final int us; // elapsed µs from Stopwatch
  final int bytes; // cumulative bytes at that instant
  const _Sample(this.us, this.bytes);
}

// ─── Service ──────────────────────────────────────────────
class RealSpeedHttpService {
  bool _isCancelled = false;
  http.Client? _dlClient;
  io.HttpClient? _ulClient;

  final DebugLogger _logger = DebugLogger();

  // ── Endpoints ──
  static const _downloadUrl = 'http://proof.ovh.net/files/1Gb.dat';
  static const _uploadUrl = 'https://speed.cloudflare.com/__up';

  // ── Tunables ──
  static const _testDurationSec = 15; // max seconds per phase
  static const _uiTickMs = 250; // gauge refresh (4 Hz)
  static const _windowUs = 1000000; // 1-s sliding window (µs)
  static const _pruneUs = 2000000; // discard samples > 2 s old
  static const _ulChunkBytes = 512 * 1024; // 512 KB upload chunk
  static const _connectTimeout = Duration(seconds: 10);

  // ═══════════ PUBLIC API ══════════════════════════════════

  void cancel() {
    _isCancelled = true;
    _teardown();
    _logger.log('[RealSpeed] Cancelled by user.');
  }

  /// Emits live [RealSpeedResult] updates.  The stream closes
  /// automatically when both phases finish (or on error).
  Stream<RealSpeedResult> measureSpeed() {
    _isCancelled = false;
    final ctrl = StreamController<RealSpeedResult>();
    _run(ctrl);
    return ctrl.stream;
  }

  // ═══════════ HELPERS ═════════════════════════════════════

  /// Forcefully tear down every active connection.
  void _teardown() {
    _dlClient?.close();
    _dlClient = null;
    _ulClient?.close(force: true); // force: kills open sockets NOW
    _ulClient = null;
  }

  /// Convert cumulative [bytes] over [us] microseconds to Megabits/s.
  ///
  /// Derivation:
  ///   seconds = µs ÷ 10⁶
  ///   Mbps    = (bytes × 8) ÷ (10⁶ × seconds)
  ///           = (bytes × 8) ÷ µs
  ///
  /// Check: 1 000 000 B in 1 000 000 µs → 8.0 Mbps ✓
  static double _mbps(int bytes, int us) {
    if (us <= 0 || bytes <= 0) return 0.0;
    return (bytes * 8.0) / us;
  }

  /// Average speed over the most recent [_windowUs] microseconds.
  ///
  /// Walks the buffer backwards to find the latest sample that
  /// is ≥ 1 s before [nowUs], then computes ΔBytes / ΔTime.
  /// This is far more stable than an EMA because one slow or
  /// fast chunk cannot spike the result.
  double _windowedSpeed(List<_Sample> buf, int nowUs) {
    if (buf.length < 2) return 0.0;

    final cutoff = nowUs - _windowUs;

    // Anchor = latest sample AT or BEFORE cutoff.
    // Guarantees window ≥ 1 s once enough history exists.
    _Sample anchor = buf.first;
    for (int i = buf.length - 1; i >= 0; i--) {
      if (buf[i].us <= cutoff) {
        anchor = buf[i];
        break;
      }
    }

    final tip = buf.last;
    final dBytes = tip.bytes - anchor.bytes;
    final dUs = tip.us - anchor.us;
    return _mbps(dBytes, dUs);
  }

  /// Drop samples older than 2 × window to bound memory.
  void _pruneBuf(List<_Sample> buf, int nowUs) {
    final limit = nowUs - _pruneUs;
    while (buf.length > 2 && buf.first.us < limit) {
      buf.removeAt(0);
    }
  }

  // ═══════════ ORCHESTRATOR ════════════════════════════════

  Future<void> _run(StreamController<RealSpeedResult> ctrl) async {
    double dlMbps = 0.0;
    double ulMbps = 0.0;

    try {
      // ── Phase 1 ──
      dlMbps = await _download(ctrl);
      if (_isCancelled) return;

      // Brief pause so the gauge visually resets
      await Future.delayed(const Duration(milliseconds: 500));

      // ── Phase 2 ──
      ulMbps = await _upload(ctrl, dlMbps);
      if (_isCancelled) return;

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
      _teardown();
      if (!ctrl.isClosed) await ctrl.close();
    }
  }

  // ═══════════ DOWNLOAD ════════════════════════════════════
  //  Uses the `http` package — streaming response already
  //  provides natural backpressure (chunks arrive at wire speed).
  // ════════════════════════════════════════════════════════

  Future<double> _download(StreamController<RealSpeedResult> ctrl) async {
    ctrl.add(RealSpeedResult(downloadSpeedMbps: 0, status: 'Downloading…'));

    final client = http.Client();
    _dlClient = client;

    final req = http.Request('GET', Uri.parse(_downloadUrl));
    final resp = await client.send(req).timeout(_connectTimeout);

    if (resp.statusCode != 200) {
      throw Exception('DL failed: HTTP ${resp.statusCode}');
    }

    // ── Timing starts AFTER the connection + headers ──
    int totalBytes = 0;
    final sw = Stopwatch()..start();
    final buf = <_Sample>[const _Sample(0, 0)];
    final done = Completer<void>();
    StreamSubscription<List<int>>? sub;

    // ❶ KILL TIMER — tears down the TCP socket at exactly 15 s.
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      _logger.log('[DL] Kill timer → closing socket.');
      sub?.cancel();
      client.close(); // socket dies here
      if (!done.isCompleted) done.complete();
    });

    // ❷ UI TICKER — records a sample and emits a smoothed speed.
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || done.isCompleted) return;
      final now = sw.elapsedMicroseconds;
      buf.add(_Sample(now, totalBytes));
      _pruneBuf(buf, now);
      ctrl.add(
        RealSpeedResult(
          downloadSpeedMbps: _windowedSpeed(buf, now),
          status: 'Downloading…',
        ),
      );
    });

    // ❸ STREAM LISTENER — just accumulates bytes.
    sub = resp.stream.listen(
      (chunk) {
        if (_isCancelled || done.isCompleted) {
          sub?.cancel();
          if (!done.isCompleted) done.complete();
          return;
        }
        totalBytes += chunk.length;
      },
      onError: (e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } catch (_) {
      /* force-close may fire error */
    }

    sw.stop();
    kill.cancel();
    ui.cancel();
    _dlClient = null;

    final mbps = _mbps(totalBytes, sw.elapsedMicroseconds);
    _logger.log(
      '[DL] ${_fmtBytes(totalBytes)} in '
      '${(sw.elapsedMicroseconds / 1e6).toStringAsFixed(1)} s '
      '→ ${mbps.toStringAsFixed(2)} Mbps',
    );
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

    final httpClient = io.HttpClient();
    _ulClient = httpClient;

    // ── Build a non-compressible 512 KB chunk ──
    // LCG-style fill so ISP transparent compression can't cheat.
    // Allocated ONCE, reused every iteration → zero GC pressure.
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    // Open connection (DNS + TCP + TLS handshake happens here).
    final request = await httpClient
        .postUrl(Uri.parse(_uploadUrl))
        .timeout(_connectTimeout);
    request.headers.contentType = io.ContentType.binary;
    request.headers.chunkedTransferEncoding = true;

    // ── Timing starts AFTER the handshake ──
    int totalBytes = 0;
    final sw = Stopwatch()..start();
    final buf = <_Sample>[const _Sample(0, 0)];
    bool killed = false;

    // ❶ KILL TIMER — violently closes ALL sockets on the client.
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      killed = true;
      _logger.log('[UL] Kill timer → force-closing HttpClient.');
      httpClient.close(force: true); // every socket dies instantly
    });

    // ❷ UI TICKER — emits smoothed speed.
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || killed) return;
      final now = sw.elapsedMicroseconds;
      buf.add(_Sample(now, totalBytes));
      _pruneBuf(buf, now);
      ctrl.add(
        RealSpeedResult(
          downloadSpeedMbps: dlMbps,
          uploadSpeedMbps: _windowedSpeed(buf, now),
          status: 'Uploading…',
        ),
      );
    });

    // ❸ WRITE LOOP — the core fix.
    //
    //   request.add(chunk)   → queues data in dart's IOSink buffer
    //   request.flush()      → returns a Future that completes ONLY
    //                          when the OS TCP send buffer has accepted
    //                          the data.  When the buffer is full (i.e.
    //                          the network is the bottleneck), flush()
    //                          BLOCKS.  This is real backpressure.
    //
    //   totalBytes is incremented AFTER flush() succeeds, so we only
    //   count bytes the OS has actually accepted for transmission.
    try {
      while (!killed && !_isCancelled) {
        request.add(chunk);
        await request.flush(); // ← BLOCKS at network speed
        totalBytes += chunk.length; // ← counted AFTER confirmation

        final now = sw.elapsedMicroseconds;
        buf.add(_Sample(now, totalBytes));
        _pruneBuf(buf, now);
      }
    } catch (e) {
      // SocketException / HttpException is EXPECTED when the kill
      // timer fires and destroys the socket mid-flush.
      if (!killed && !_isCancelled) {
        _logger.log('[UL] Unexpected write error: $e');
      }
    }

    sw.stop();
    kill.cancel();
    ui.cancel();
    try {
      await request.close();
    } catch (_) {} // best-effort graceful close
    _ulClient = null;

    final mbps = _mbps(totalBytes, sw.elapsedMicroseconds);
    _logger.log(
      '[UL] ${_fmtBytes(totalBytes)} in '
      '${(sw.elapsedMicroseconds / 1e6).toStringAsFixed(1)} s '
      '→ ${mbps.toStringAsFixed(2)} Mbps',
    );
    return mbps;
  }

  // ── Formatting helper for logs ──
  static String _fmtBytes(int b) {
    if (b >= 1e9) return '${(b / 1e9).toStringAsFixed(2)} GB';
    if (b >= 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB';
    if (b >= 1e3) return '${(b / 1e3).toStringAsFixed(0)} KB';
    return '$b B';
  }
}
