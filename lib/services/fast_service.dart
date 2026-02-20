import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

// ─── Data Model (unchanged — compatible with your UI) ──────────
class FastResult {
  final double downloadSpeedMbps;
  final double uploadSpeedMbps;
  final bool isDone;
  final String? error;
  final String status;

  FastResult({
    required this.downloadSpeedMbps,
    this.uploadSpeedMbps = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
  });
}

// ─── Service ───────────────────────────────────────────────────
class FastService {
  // Fast.com public JS-client token
  static const String _token = 'YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm';

  // ── Tunables ──
  static const int _testDurationSec = 15;
  static const int _uiTickMs = 250; // 4 Hz gauge refresh
  static const int _maxStreams = 5; // parallel connections
  static const int _ulChunkBytes = 512 * 1024; // 512 KB upload chunk
  static const Duration _connectTimeout = Duration(seconds: 10);

  final TestLifecycle _lifecycle = TestLifecycle();
  final DebugLogger _logger = DebugLogger();

  // ═══════════ PUBLIC API ══════════════════════════════════════

  void cancel() {
    _lifecycle.cancel();
    _logger.log('[Fast] Cancelled by user.');
  }

  /// Emits live [FastResult] updates. Stream closes automatically
  /// when both phases finish, or on fatal error.
  Stream<FastResult> measureSpeed() {
    _lifecycle.reset();
    final ctrl = StreamController<FastResult>();
    _run(ctrl);
    return ctrl.stream;
  }

  // ═══════════ FAST.COM API ════════════════════════════════════

  /// Fetch OCA (Open Connect Appliance) target URLs from Fast.com API v2.
  Future<List<String>> _fetchTargets() async {
    final client = http.Client();
    try {
      final uri = Uri.parse(
        'https://api.fast.com/netflix/speedtest/v2'
        '?https=true&token=$_token&urlCount=$_maxStreams',
      );
      final resp = await client.get(uri).timeout(_connectTimeout);
      if (resp.statusCode != 200) {
        throw Exception('Fast.com API HTTP ${resp.statusCode}');
      }
      final json = jsonDecode(resp.body);
      final targets = json['targets'] as List;
      return targets.map<String>((t) => t['url'].toString()).toList();
    } finally {
      client.close();
    }
  }

  /// Convert Netflix OCA download URL → upload URL.
  ///
  /// Download: .../speedtest/range/0-26214400?c=...&e=...&t=...
  /// Upload:   .../speedtest/upload?c=...&e=...&t=...
  ///
  /// Uri.replace(path:) preserves scheme, host, port, query, fragment.
  String _toUploadUrl(String downloadUrl) {
    final uri = Uri.parse(downloadUrl);
    return uri.replace(path: '/speedtest/upload').toString();
  }

  /// Lightweight latency probe: GET 1 byte with Range header.
  /// Returns recommended stream count (reduced for high-latency links).
  Future<int> _probeLatency(String url) async {
    final probe = io.HttpClient();
    _lifecycle.registerClient(probe);

    try {
      final sw = Stopwatch()..start();
      final req = await probe
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      req.headers.set('Range', 'bytes=0-0'); // 1 byte — minimal transfer
      final resp = await req.close().timeout(const Duration(seconds: 3));
      await resp.drain<void>();
      sw.stop();

      final ms = sw.elapsedMilliseconds;
      if (ms > 500) {
        _logger.log('[Fast] High latency (${ms}ms) → 2 streams.');
        return 2;
      }
      _logger.log('[Fast] Latency OK (${ms}ms) → $_maxStreams streams.');
      return _maxStreams;
    } catch (e) {
      _logger.log('[Fast] Latency probe failed: $e');
      return _maxStreams; // default on failure
    }
  }

  // ═══════════ ORCHESTRATOR ════════════════════════════════════

  Future<void> _run(StreamController<FastResult> ctrl) async {
    double dlMbps = 0.0;
    double ulMbps = 0.0;

    try {
      // ── Step 1: Fetch Netflix OCA targets ──
      ctrl.add(
        FastResult(downloadSpeedMbps: 0, status: 'Fetching Netflix targets…'),
      );
      final urls = await _fetchTargets();
      if (urls.isEmpty) throw Exception('No Fast.com targets found');
      _logger.log('[Fast] ${urls.length} OCA targets acquired.');
      if (_lifecycle.isUserCancelled) return;

      // ── Step 2: Latency-based stream count ──
      ctrl.add(FastResult(downloadSpeedMbps: 0, status: 'Checking latency…'));
      final streams = await _probeLatency(urls.first);
      if (_lifecycle.isUserCancelled) return;

      // ── Step 3: Download ──
      dlMbps = await _downloadPhase(ctrl, urls, streams);
      if (_lifecycle.isUserCancelled) return;

      // Brief pause so gauge visually resets between phases
      await Future.delayed(const Duration(milliseconds: 500));

      // ── Step 4: Upload ──
      ulMbps = await _uploadPhase(ctrl, urls, streams, dlMbps);
      if (_lifecycle.isUserCancelled) return;

      // ── Done ──
      if (!ctrl.isClosed) {
        ctrl.add(
          FastResult(
            downloadSpeedMbps: dlMbps,
            uploadSpeedMbps: ulMbps,
            isDone: true,
            status: 'Complete',
          ),
        );
      }
      _logger.log(
        '[Fast] Complete. '
        'DL: ${dlMbps.toStringAsFixed(2)} Mbps, '
        'UL: ${ulMbps.toStringAsFixed(2)} Mbps',
      );
    } catch (e, st) {
      _logger.log('[Fast] Fatal: $e\n$st');
      if (!ctrl.isClosed) {
        ctrl.add(
          FastResult(
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

  // ═══════════ DOWNLOAD PHASE ══════════════════════════════════
  //
  //  N parallel workers each loop: GET 25 MB → count chunks → repeat.
  //  dart:io HttpClient reuses TCP connections (keep-alive by default).
  //  Kill timer calls close(force:true) → all sockets die instantly →
  //  workers' await-for throws → loops exit → Future.wait resolves.
  //
  // ════════════════════════════════════════════════════════════════

  Future<double> _downloadPhase(
    StreamController<FastResult> ctrl,
    List<String> urls,
    int streams,
  ) async {
    ctrl.add(FastResult(downloadSpeedMbps: 0, status: 'Starting download…'));

    final meter = SmoothSpeedMeter(totalDurationSeconds: _testDurationSec);
    meter.start();
    _lifecycle.beginPhase();

    // ❶ KILL TIMER
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      _logger.log('[Fast DL] Kill timer → force-closing all sockets.');
      _lifecycle.timeoutPhase();
    });
    _lifecycle.registerTimer(kill);

    // ❷ UI TICKER
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || _lifecycle.shouldStop) return;
      ctrl.add(
        FastResult(downloadSpeedMbps: meter.tick(), status: 'Downloading…'),
      );
    });
    _lifecycle.registerTimer(ui);

    final client = io.HttpClient();
    client.connectionTimeout = _connectTimeout;
    _lifecycle.registerClient(client);

    // ❸ WORKERS — all launched and awaited via lifecycle
    final n = min(streams, urls.length);
    for (int i = 0; i < n; i++) {
      _lifecycle.launchWorker(
        () => _dlWorker(client, urls[i], (bytes) {
          meter.addBytes(bytes);
        }),
      );
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    final mbps = meter.finish();
    _logger.log('[Fast DL] finished at ${mbps.toStringAsFixed(2)} Mbps');
    return mbps;
  }

  /// Single download worker: loops GET requests until [shouldStop].
  /// Each request downloads the OCA test payload (~25 MB).
  /// Keep-alive reuses the TCP+TLS connection across iterations.
  Future<void> _dlWorker(
    io.HttpClient client,
    String url,
    void Function(int) onBytes,
  ) async {
    final uri = Uri.parse(url);
    while (!_lifecycle.shouldStop) {
      try {
        final request = await client.getUrl(uri);
        final response = await request.close();

        // await-for provides natural backpressure: chunks arrive
        // at network speed, not memory speed.
        await for (final chunk in response) {
          if (_lifecycle.shouldStop) break;
          onBytes(chunk.length);
        }
      } catch (e) {
        // SocketException is EXPECTED when kill timer fires.
        if (!_lifecycle.shouldStop) {
          _logger.log('[Fast DL Worker] $e');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }

  // ═══════════ UPLOAD PHASE ════════════════════════════════════
  //
  //  N parallel workers each: POST with chunked encoding → write
  //  512 KB chunks → flush() blocks at network speed → count bytes
  //  AFTER flush succeeds.  Kill timer force-closes all sockets.
  //
  //  Upload URL: download URL with path replaced to /speedtest/upload.
  //  Query parameters (token, expiry) are preserved.
  //
  // ════════════════════════════════════════════════════════════════

  Future<double> _uploadPhase(
    StreamController<FastResult> ctrl,
    List<String> urls,
    int streams,
    double dlMbps,
  ) async {
    ctrl.add(
      FastResult(
        downloadSpeedMbps: dlMbps,
        uploadSpeedMbps: 0,
        status: 'Starting upload…',
      ),
    );

    // ── Build a non-compressible 512 KB chunk ──
    // LCG-style fill so ISP transparent compression can't cheat.
    // Allocated ONCE, shared by all workers (read-only) → zero GC pressure.
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    final meter = SmoothSpeedMeter(totalDurationSeconds: _testDurationSec);
    meter.start();
    _lifecycle.beginPhase();

    // ❶ KILL TIMER
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      _logger.log('[Fast UL] Kill timer → force-closing all sockets.');
      _lifecycle.timeoutPhase();
    });
    _lifecycle.registerTimer(kill);

    // ❷ UI TICKER
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || _lifecycle.shouldStop) return;
      ctrl.add(
        FastResult(
          downloadSpeedMbps: dlMbps,
          uploadSpeedMbps: meter.tick(),
          status: 'Uploading…',
        ),
      );
    });
    _lifecycle.registerTimer(ui);

    // ❸ WORKERS
    final uploadUrls = urls.map(_toUploadUrl).toList();
    _logger.log('[Fast UL] Upload URLs: ${uploadUrls.take(2)}...');

    final client = io.HttpClient();
    client.connectionTimeout = _connectTimeout;
    _lifecycle.registerClient(client);

    final n = min(streams, uploadUrls.length);
    for (int i = 0; i < n; i++) {
      _lifecycle.launchWorker(
        () => _ulWorker(client, uploadUrls[i], chunk, (bytes) {
          meter.addBytes(bytes);
        }),
      );
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    final mbps = meter.finish();
    _logger.log('[Fast UL] finished at ${mbps.toStringAsFixed(2)} Mbps');
    return mbps;
  }

  /// Single upload worker: loops POST requests until [shouldStop].
  ///
  /// Each POST uses chunked transfer encoding. Inside each request:
  ///   request.add(chunk)   → queues 512 KB in dart's IOSink buffer
  ///   request.flush()      → Future completes ONLY when OS TCP send
  ///                          buffer accepts the data.  When the buffer
  ///                          is full (network is the bottleneck),
  ///                          flush() BLOCKS.  This is real backpressure.
  ///   onBytes(chunk.length) → counted AFTER flush succeeds.
  ///
  /// When the kill timer fires and destroys the socket, flush() throws
  /// a SocketException → inner loop breaks → outer loop checks
  /// shouldStop() → exits → Future.wait resolves.
  Future<void> _ulWorker(
    io.HttpClient client,
    String url,
    Uint8List chunk,
    void Function(int) onBytes,
  ) async {
    final uri = Uri.parse(url);

    while (!_lifecycle.shouldStop) {
      try {
        final request = await client.postUrl(uri);
        request.headers.contentType = io.ContentType.binary;
        request.headers.chunkedTransferEncoding = true;

        // Inner loop: write chunks with backpressure
        while (!_lifecycle.shouldStop) {
          request.add(chunk);
          await request.flush(); // ← BLOCKS at network speed
          onBytes(chunk.length); // ← counted AFTER confirmation
        }

        // Graceful close (best-effort)
        try {
          final res = await request.close();
          await res.drain();
        } catch (_) {}
      } catch (e) {
        // SocketException is EXPECTED when kill timer fires.
        if (!_lifecycle.shouldStop) {
          _logger.log('[Fast UL Worker] $e');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }
}
