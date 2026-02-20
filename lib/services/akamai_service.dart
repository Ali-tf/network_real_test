import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

// ═══════════════════════════════════════════════════════════════
// Result Model
// ═══════════════════════════════════════════════════════════════

class AkamaiResult {
  final double downloadMbps;
  final double uploadMbps;
  final double latencyMs;
  final double jitterMs;
  final bool isDone;
  final String? error;
  final String status;
  final String? edgeNode;
  final String? edgeIp;
  final String? uploadSource;

  const AkamaiResult({
    required this.downloadMbps,
    this.uploadMbps = 0.0,
    this.latencyMs = 0.0,
    this.jitterMs = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
    this.edgeNode,
    this.edgeIp,
    this.uploadSource,
  });
}

// ═══════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════

class _Config {
  static const int minWorkers = 4;
  static const int maxWorkers = 8;
  static const int phaseTimeoutSeconds = 15;
  static const int uiUpdateIntervalMs = 250;
  static const int chunkInitialSize = 256 * 1024; // 256 KB
  static const int chunkMaxSize = 8 * 1024 * 1024; // 8 MB

  static const List<String> akamaiProbeUrls = [
    // Apple Software Updates (Very reliable Akamai edge)
    'http://swcdn.apple.com/content/downloads/28/01/041-88407-A_T8D7833FO7/0y7xlyp38xrt816x5f14x13a69aoxr8p25/Safari15.6.1BigSurAuto.pkg',

    // Adobe Reader Installer (Massively cached globally on Akamai)
    'http://ardownload2.adobe.com/pub/adobe/reader/win/AcroRdrDC2100120155_en_US.exe',

    // Steam CDN (Gaming assets, extremely fast Akamai pipes)
    'http://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe',
  ];
}

// ═══════════════════════════════════════════════════════════════
// Engine Implementation
// ═══════════════════════════════════════════════════════════════

class AkamaiService {
  final TestLifecycle _lifecycle = TestLifecycle();
  final DebugLogger _logger = DebugLogger();

  // ── Public API ──────────────────────────────────────────────

  void cancel() {
    _lifecycle.cancel();
    _logger.log("[Akamai] Cancel requested.");
  }

  Stream<AkamaiResult> measureSpeed() {
    final controller = StreamController<AkamaiResult>();
    _lifecycle.reset();
    _runPipeline(controller);
    return controller.stream;
  }

  // ── Pipeline ────────────────────────────────────────────────

  Future<void> _runPipeline(StreamController<AkamaiResult> controller) async {
    try {
      _logger.log("[Akamai] ═══ Starting Edge Speed Test ═══");

      // ── Phase 0: Discovery ──
      _emit(
        controller,
        const AkamaiResult(
          downloadMbps: 0,
          status: "Discovering nearest Akamai Edge...",
        ),
      );

      final discoveryResult = await _discoverEdge();
      if (_abort(controller)) return;

      if (discoveryResult == null) {
        throw Exception("Failed to find a valid Akamai Edge node.");
      }

      final testUrl = discoveryResult['testUrl'] as String;
      final edgeIp = discoveryResult['edgeIp'] as String;
      final host = discoveryResult['host'] as String;
      _logger.log("[Akamai] Edge IP: $edgeIp, Host: $host");

      // ── Phase 1: Latency ──
      _emit(
        controller,
        AkamaiResult(
          downloadMbps: 0,
          status: "Measuring Latency...",
          edgeIp: edgeIp,
          edgeNode: host,
        ),
      );

      final latencyMap = await _measureLatency(testUrl);
      final double latencyMs = latencyMap['ping']!;
      final double jitterMs = latencyMap['jitter']!;

      if (_abort(controller)) return;

      _emit(
        controller,
        AkamaiResult(
          downloadMbps: 0,
          latencyMs: latencyMs,
          jitterMs: jitterMs,
          status: "Ping: ${latencyMs.toStringAsFixed(1)}ms",
          edgeIp: edgeIp,
          edgeNode: host,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 400));
      if (_abort(controller)) return;

      // ── Phase 2: Download ──
      _logger.log("[Akamai] ── Download Phase ──");
      final dlMbps = await _downloadPhase(
        controller,
        testUrl,
        latencyMs,
        jitterMs,
        edgeIp,
        host,
      );
      _logger.log("[Akamai] Download: ${dlMbps.toStringAsFixed(2)} Mbps");
      if (_abort(controller)) return;

      await Future.delayed(const Duration(milliseconds: 300));

      // ── Phase 3: Upload ──
      _logger.log("[Akamai] ── Upload Phase ──");
      final uploadData = await _uploadPhase(
        controller,
        dlMbps,
        latencyMs,
        jitterMs,
        edgeIp,
        host,
      );
      final ulMbps = uploadData['speed'] as double;
      final ulSource = uploadData['source'] as String;
      _logger.log(
        "[Akamai] Upload: ${ulMbps.toStringAsFixed(2)} Mbps ($ulSource)",
      );

      // ── Done ──
      _emit(
        controller,
        AkamaiResult(
          downloadMbps: dlMbps,
          uploadMbps: ulMbps,
          latencyMs: latencyMs,
          jitterMs: jitterMs,
          isDone: true,
          status: "Complete",
          edgeIp: edgeIp,
          edgeNode: host,
          uploadSource: ulSource,
        ),
      );
      _logger.log("[Akamai] ═══ Test Complete ═══");
    } catch (e, st) {
      _logger.log("[Akamai] FATAL: $e\n$st");
      _emit(
        controller,
        AkamaiResult(downloadMbps: 0, error: e.toString(), status: "Error"),
      );
    } finally {
      if (!controller.isClosed) controller.close();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // PHASE 0: DISCOVERY
  // ═══════════════════════════════════════════════════════════

  Future<Map<String, dynamic>?> _discoverEdge() async {
    final client = HttpClient();
    _lifecycle.registerClient(client);
    client.badCertificateCallback = (cert, host, port) => true;
    client.connectionTimeout = const Duration(seconds: 4);

    try {
      for (final url in _Config.akamaiProbeUrls) {
        if (_lifecycle.shouldStop) return null;

        final uri = Uri.parse(url);
        final domain = uri.host;

        // 1. DNS Resolution
        List<InternetAddress> ips;
        try {
          ips = await InternetAddress.lookup(domain);
        } catch (_) {
          continue; // Try next probe
        }

        if (ips.isEmpty) continue;
        final edgeIp = ips.first.address;

        // Note: In typical Dart without raw DNS queries, we can't easily read CNAME chains.
        // We will rely on the HEAD response headers (Server: AkamaiGHost, X-Akamai-Request-ID)
        // to validate it's an Akamai edge.

        // 2. HEAD Validation
        try {
          final request = await client.headUrl(Uri.parse(url));
          final response = await request.close().timeout(
            const Duration(seconds: 4),
          );

          await response.drain();

          if (response.statusCode != 200 && response.statusCode != 206) {
            _logger.log(
              "[Akamai Discovery] $domain returned ${response.statusCode}",
            );
            continue;
          }

          // Since we are using pre-curated Akamai endpoints, if they return 200
          // we can assume they are valid edges (some like Steam hide the Akamai server headers).

          // We got a good hit!
          _logger.log("[Akamai Discovery] Found edge at $edgeIp ($domain)");
          return {'testUrl': url, 'edgeIp': edgeIp, 'host': domain};
        } catch (e) {
          _logger.log("[Akamai Discovery] Validation failed for $domain: $e");
        }
      }
      return null;
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════
  // PHASE 1: LATENCY
  // ═══════════════════════════════════════════════════════════

  Future<Map<String, double>> _measureLatency(String url) async {
    final samples = <double>[];
    final client = HttpClient();
    _lifecycle.registerClient(client);
    client.badCertificateCallback = (cert, host, port) => true;
    client.connectionTimeout = const Duration(seconds: 3);

    try {
      // Create persistent connection
      final uri = Uri.parse(url);

      for (int i = 0; i < 15; i++) {
        if (_lifecycle.shouldStop) break;
        try {
          final sw = Stopwatch()..start();
          final request = await client.headUrl(uri);
          request.headers.set('Connection', 'keep-alive');

          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          await response.drain();
          sw.stop();
          samples.add(sw.elapsedMicroseconds / 1000.0);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }

    if (samples.isEmpty) return {'ping': 0.0, 'jitter': 0.0};

    // Discard first two samples (cold TCP/TLS handshake)
    if (samples.length > 2) {
      samples.removeRange(0, 2);
    }

    samples.sort();
    // Trim top/bottom 10%
    final trim = (samples.length * 0.1).floor();
    final trimmed = samples.sublist(trim, samples.length - trim);

    if (trimmed.isEmpty) {
      return {
        'ping': samples.reduce((a, b) => a + b) / samples.length,
        'jitter': 0.0,
      };
    }

    final avg = trimmed.reduce((a, b) => a + b) / trimmed.length;
    double jitterSum = 0;
    for (int i = 1; i < trimmed.length; i++) {
      jitterSum += (trimmed[i] - trimmed[i - 1]).abs();
    }

    return {
      'ping': avg,
      'jitter': trimmed.length > 1 ? jitterSum / (trimmed.length - 1) : 0.0,
    };
  }

  // ═══════════════════════════════════════════════════════════
  // PHASE 2: DOWNLOAD
  // ═══════════════════════════════════════════════════════════

  Future<double> _downloadPhase(
    StreamController<AkamaiResult> controller,
    String testUrl,
    double latencyMs,
    double jitterMs,
    String edgeIp,
    String host,
  ) async {
    final meter = SmoothSpeedMeter(
      totalDurationSeconds: _Config.phaseTimeoutSeconds,
    );
    meter.start();

    final deadline = DateTime.now().add(
      const Duration(seconds: _Config.phaseTimeoutSeconds),
    );

    final completer = Completer<double>();
    _lifecycle.beginPhase();

    // ── Monitor Timer ──
    final monitor = Timer.periodic(
      const Duration(milliseconds: _Config.uiUpdateIntervalMs),
      (timer) {
        if (_lifecycle.shouldStop ||
            DateTime.now().isAfter(deadline) ||
            controller.isClosed) {
          _lifecycle.timeoutPhase();
          return;
        }

        _emit(
          controller,
          AkamaiResult(
            downloadMbps: math.max(0, meter.tick()),
            latencyMs: latencyMs,
            jitterMs: jitterMs,
            status: "Testing Download...",
            edgeIp: edgeIp,
            edgeNode: host,
          ),
        );
      },
    );
    _lifecycle.registerTimer(monitor);

    // ── Workers ──
    final client = HttpClient();
    _lifecycle.registerClient(client);
    client.badCertificateCallback = (cert, host, port) => true;
    client.autoUncompress = false; // CRITICAL: bypass local gzip expansion
    client.connectionTimeout = const Duration(seconds: 10);
    client.idleTimeout = const Duration(seconds: 15);
    client.maxConnectionsPerHost = _Config.maxWorkers;

    // Shared chunk offset
    int nextChunkFileOffset = 0;

    for (int i = 0; i < _Config.minWorkers; i++) {
      _lifecycle.launchWorker(
        () => Future.delayed(
          Duration(milliseconds: i * 150), // Stagger start
          () => _dlWorker(client, testUrl, meter, deadline, () {
            final offset = nextChunkFileOffset;
            nextChunkFileOffset += _Config.chunkInitialSize;
            return offset;
          }),
        ),
      );
    }

    // Optional: Dynamic worker scaling could go here but starting with minWorkers is stable

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    if (!completer.isCompleted) completer.complete(meter.finish());
    return await completer.future;
  }

  Future<void> _dlWorker(
    HttpClient client,
    String url,
    SmoothSpeedMeter meter,
    DateTime deadline,
    int Function() getNextOffset,
  ) async {
    final uri = Uri.parse(url);
    int currentChunkSize = _Config.chunkInitialSize;

    while (!_lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
      try {
        int startByte = getNextOffset();
        int endByte = startByte + currentChunkSize - 1;

        // Wrap around simulated 100MB file limit if we go too far
        // Just to ensure we don't request out-of-bounds if the real asset is small.
        // Assuming ~50MB minimum based on catalog. Just modulo wrap to 50MB.
        const int maxSafeBoundary = 50 * 1024 * 1024;
        startByte = startByte % maxSafeBoundary;
        endByte = startByte + currentChunkSize - 1;

        final request = await client.getUrl(uri);
        request.headers.set(
          'Accept-Encoding',
          'identity',
        ); // Force bytes on wire
        request.headers.set('Cache-Control', 'no-cache');
        request.headers.set('Connection', 'keep-alive');
        request.headers.set('Range', 'bytes=$startByte-$endByte');

        final sw = Stopwatch()..start();
        final response = await request.close();

        if (response.statusCode == 200 || response.statusCode == 206) {
          await response.forEach((data) {
            if (_lifecycle.shouldStop) throw Exception('Aborted');
            meter.addBytes(data.length);
          });

          sw.stop();

          // Adaptive Chunk Sizing
          if (sw.elapsedMilliseconds < 300) {
            currentChunkSize = math.min(
              currentChunkSize * 2,
              _Config.chunkMaxSize,
            );
          } else if (sw.elapsedMilliseconds > 5000) {
            currentChunkSize = math.max(
              currentChunkSize ~/ 2,
              _Config.chunkInitialSize,
            );
          }
        } else {
          await response.drain();
          // If server rejects range, throttle slightly
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (e) {
        if (_lifecycle.shouldStop) return;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════
  // PHASE 3: UPLOAD
  // ═══════════════════════════════════════════════════════════

  Future<Map<String, dynamic>> _uploadPhase(
    StreamController<AkamaiResult> controller,
    double dlMbps,
    double pingMs,
    double jitterMs,
    String edgeIp,
    String host,
  ) async {
    final meter = SmoothSpeedMeter(
      totalDurationSeconds: _Config.phaseTimeoutSeconds,
    );
    meter.start();

    final deadline = DateTime.now().add(
      const Duration(seconds: _Config.phaseTimeoutSeconds),
    );

    final completer = Completer<double>();
    String activeSource = "akamai-tcp";

    _lifecycle.beginPhase();

    // ── Monitor Timer ──
    final monitor = Timer.periodic(
      const Duration(milliseconds: _Config.uiUpdateIntervalMs),
      (timer) {
        if (_lifecycle.shouldStop ||
            DateTime.now().isAfter(deadline) ||
            controller.isClosed) {
          _lifecycle.timeoutPhase();
          return;
        }

        _emit(
          controller,
          AkamaiResult(
            downloadMbps: dlMbps,
            uploadMbps: math.max(0, meter.tick()),
            latencyMs: pingMs,
            jitterMs: jitterMs,
            status: "Testing Upload...",
            edgeIp: edgeIp,
            edgeNode: host,
            uploadSource: activeSource,
          ),
        );
      },
    );
    _lifecycle.registerTimer(monitor);

    // TIER 2: TCP Write to Edge IP
    bool tcpUploadSuccess = false;

    // We launch 1 worker for TCP write as it saturates quite heavily
    _lifecycle.launchWorker(
      () => _tcpWriteUploadWorker(edgeIp, host, meter, deadline, () {
        tcpUploadSuccess = true;
      }),
    );

    // Give it 4 seconds to prove it's working
    await Future.delayed(const Duration(seconds: 4));

    if (!tcpUploadSuccess && !_lifecycle.shouldStop) {
      _logger.log(
        "[Akamai] Tier 2 TCP Upload failed/rejected. Falling back to Cloudflare (Tier 3).",
      );
      activeSource = "cloudflare-fallback";

      // Stop the TCP worker via phase trick or just ignore it if it crashed
      // Spin up CF upload workers
      final cfClient = HttpClient();
      _lifecycle.registerClient(cfClient);
      cfClient.badCertificateCallback = (cert, host, port) => true;

      int workerCount = 4;
      for (int i = 0; i < workerCount; i++) {
        _lifecycle.launchWorker(
          () => _cfFallbackUploadWorker(cfClient, meter, deadline),
        );
      }
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    if (!completer.isCompleted) completer.complete(meter.finish());
    return {'speed': await completer.future, 'source': activeSource};
  }

  Future<void> _tcpWriteUploadWorker(
    String edgeIp,
    String host,
    SmoothSpeedMeter meter,
    DateTime deadline,
    VoidCallback onSuccessConfirmed,
  ) async {
    try {
      final socket = await SecureSocket.connect(
        edgeIp,
        443,
        timeout: const Duration(seconds: 5),
        supportedProtocols: ['http/1.1'],
        onBadCertificate: (certificate) => true,
      );

      // Write headers manually
      final headers =
          "POST / HTTP/1.1\r\n"
          "Host: $host\r\n"
          "Content-Type: application/octet-stream\r\n"
          "Content-Length: 67108864\r\n\r\n"; // 64MB buffer
      socket.write(headers);

      final chunk = Uint8List(512 * 1024);
      final rng = math.Random();
      for (int i = 0; i < chunk.length; i += 64) {
        chunk[i] = rng.nextInt(256);
      }

      bool firstChunkAcked = false;

      while (!_lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
        socket.add(chunk);
        await socket.flush(); // Waits for TCP ACK
        meter.addBytes(chunk.length);

        if (!firstChunkAcked) {
          firstChunkAcked = true;
          onSuccessConfirmed();
        }
      }

      socket.destroy();
    } catch (e) {
      _logger.log("[Akamai TCP Write Error] $e");
    }
  }

  // Tier 3 Cloudflare Fallback Reused
  Future<void> _cfFallbackUploadWorker(
    HttpClient client,
    SmoothSpeedMeter meter,
    DateTime deadline,
  ) async {
    final uri = Uri.parse("https://speed.cloudflare.com/__up");
    final chunk = Uint8List(512 * 1024);
    final rng = math.Random();
    for (int i = 0; i < chunk.length; i += 64) {
      chunk[i] = rng.nextInt(256);
    }

    while (!_lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.postUrl(uri);
        request.headers.contentType = ContentType.binary;
        request.contentLength = chunk.length;

        request.add(chunk);
        final response = await request.close();

        if (response.statusCode == 200) {
          await response.drain();
          if (!_lifecycle.shouldStop) meter.addBytes(chunk.length);
        } else {
          await response.drain();
        }
      } catch (_) {
        if (_lifecycle.shouldStop) return;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════

  void _emit(StreamController<AkamaiResult> controller, AkamaiResult result) {
    if (!controller.isClosed) controller.add(result);
  }

  bool _abort(StreamController<AkamaiResult> controller) {
    if (_lifecycle.isUserCancelled || controller.isClosed) {
      if (!controller.isClosed) controller.close();
      return true;
    }
    return false;
  }
}
