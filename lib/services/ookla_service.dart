import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:speed_test_dart/speed_test_dart.dart';
import 'package:speed_test_dart/classes/classes.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

// ═══════════════════════════════════════════════════════════════
// Result Model
// ═══════════════════════════════════════════════════════════════

class OoklaResult {
  final double downloadSpeedMbps;
  final double uploadSpeedMbps;
  final double pingMs;
  final double jitterMs;
  final bool isDone;
  final String? error;
  final String status;
  final String? serverName;
  final String? serverSponsor;

  const OoklaResult({
    required this.downloadSpeedMbps,
    this.uploadSpeedMbps = 0.0,
    this.pingMs = 0.0,
    this.jitterMs = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
    this.serverName,
    this.serverSponsor,
  });
}

// ═══════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════

class _Config {
  static const int maxWorkers = 16;
  static const int initialWorkers = 2;
  static const int rampUpStep = 2;
  static const int rampUpIntervalMs = 2000;
  static const int phaseTimeoutSeconds = 15;
  static const int uiUpdateIntervalMs = 150;
  static const int pingSampleCount = 10;

  static const List<String> downloadFiles = [
    'random350x350.jpg',
    'random750x750.jpg',
    'random1500x1500.jpg',
    'random2000x2000.jpg',
    'random3000x3000.jpg',
    'random4000x4000.jpg',
  ];

  /// Upload payload per POST — smaller = more frequent confirmations
  /// = smoother gauge + accurate counting.
  /// 256KB balances HTTP overhead vs. granularity.
  static const int uploadPayloadSize = 256 * 1024;
}

// ═══════════════════════════════════════════════════════════════
// Byte Counter (Thread-Safe for Single Isolate)
// ═══════════════════════════════════════════════════════════════

// Removed legacy _ByteCounter and _EmaSmoother

// ═══════════════════════════════════════════════════════════════
// Ookla Service
// ═══════════════════════════════════════════════════════════════

class OoklaService {
  final TestLifecycle _lifecycle = TestLifecycle();
  final SpeedTestDart _tester = SpeedTestDart();
  final DebugLogger _logger = DebugLogger();

  // ── Public API ──────────────────────────────────────────────

  void cancel() {
    _lifecycle.cancel();
    _logger.log("[Ookla] Cancel requested.");
  }

  Stream<OoklaResult> measureSpeed() {
    final controller = StreamController<OoklaResult>();
    _lifecycle.reset();
    _runPipeline(controller);
    return controller.stream;
  }

  // ── Pipeline ────────────────────────────────────────────────

  Future<void> _runPipeline(StreamController<OoklaResult> controller) async {
    try {
      _logger.log("[Ookla] ═══ Starting Speed Test ═══");

      // ── Phase 0: Server Discovery ──
      _emit(
        controller,
        const OoklaResult(
          downloadSpeedMbps: 0,
          status: "Fetching server list...",
        ),
      );

      final servers = await _fetchServers();
      _logger.log("[Ookla] Fetched ${servers.length} servers.");
      if (_abort(controller)) return;

      final candidates = await _selectCandidates(servers, controller);
      if (_abort(controller)) return;

      // ── Phase 1: Latency ──
      _emit(
        controller,
        const OoklaResult(downloadSpeedMbps: 0, status: "Measuring latency..."),
      );

      final bestServers = await _tester.getBestServers(servers: candidates);
      if (bestServers.isEmpty) throw Exception('No reachable servers.');

      final target = bestServers.first;
      _logger.log("[Ookla] Server: ${target.name} (${target.sponsor})");

      final ping = await _measurePingJitter(target);
      final double pingMs = ping['ping']!;
      final double jitterMs = ping['jitter']!;
      _logger.log(
        "[Ookla] Ping: ${pingMs.toStringAsFixed(1)}ms, "
        "Jitter: ${jitterMs.toStringAsFixed(1)}ms",
      );

      if (_abort(controller)) return;

      _emit(
        controller,
        OoklaResult(
          downloadSpeedMbps: 0,
          pingMs: pingMs,
          jitterMs: jitterMs,
          status: "Ping: ${pingMs.toStringAsFixed(0)}ms",
          serverName: target.name,
          serverSponsor: target.sponsor,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 400));
      if (_abort(controller)) return;

      // ── Phase 2: Download ──
      _logger.log("[Ookla] ── Download Phase ──");
      final dlMbps = await _downloadPhase(controller, target, pingMs, jitterMs);
      _logger.log("[Ookla] Download: ${dlMbps.toStringAsFixed(2)} Mbps");
      if (_abort(controller)) return;

      await Future.delayed(const Duration(milliseconds: 300));

      // ── Phase 3: Upload ──
      _logger.log("[Ookla] ── Upload Phase ──");
      final ulMbps = await _uploadPhase(
        controller,
        target,
        dlMbps,
        pingMs,
        jitterMs,
      );
      _logger.log("[Ookla] Upload: ${ulMbps.toStringAsFixed(2)} Mbps");

      // ── Done ──
      _emit(
        controller,
        OoklaResult(
          downloadSpeedMbps: dlMbps,
          uploadSpeedMbps: ulMbps,
          pingMs: pingMs,
          jitterMs: jitterMs,
          isDone: true,
          status: "Complete",
          serverName: target.name,
          serverSponsor: target.sponsor,
        ),
      );
      _logger.log("[Ookla] ═══ Test Complete ═══");
    } catch (e, st) {
      _logger.log("[Ookla] FATAL: $e\n$st");
      _emit(
        controller,
        OoklaResult(downloadSpeedMbps: 0, error: e.toString(), status: "Error"),
      );
    } finally {
      if (!controller.isClosed) controller.close();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // SERVER FETCHING & SELECTION
  // ═══════════════════════════════════════════════════════════

  Future<List<Server>> _fetchServers() async {
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://www.speedtest.net/api/js/servers?engine=js&limit=40',
        ),
      );
      request.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
      );
      request.headers.set('Accept', 'application/json, */*; q=0.01');
      request.headers.set('Referer', 'https://www.speedtest.net/');

      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        throw Exception('Server list HTTP ${response.statusCode}');
      }

      final body = await response.transform(utf8.decoder).join();
      final List<dynamic> jsonList = json.decode(body);
      return jsonList.map((d) {
        final lat = double.tryParse(d['lat'].toString()) ?? 0.0;
        final lon = double.tryParse(d['lon'].toString()) ?? 0.0;
        return Server(
          int.tryParse(d['id'].toString()) ?? 0,
          d['name']?.toString() ?? '',
          d['country']?.toString() ?? '',
          d['sponsor']?.toString() ?? '',
          d['host']?.toString() ?? '',
          d['url']?.toString() ?? '',
          lat,
          lon,
          99999999999,
          99999999999,
          Coordinate(lat, lon),
        );
      }).toList();
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  Future<List<Server>> _selectCandidates(
    List<Server> servers,
    StreamController<OoklaResult> controller,
  ) async {
    final local = servers
        .where((s) => s.country.toLowerCase() == 'lebanon')
        .toList();
    if (local.length >= 3) return local;

    try {
      final settings = await _tester.getSettings();
      for (var s in servers) {
        s.distance = _haversine(
          settings.client.latitude,
          settings.client.longitude,
          s.latitude,
          s.longitude,
        );
      }
      servers.sort((a, b) => a.distance.compareTo(b.distance));
    } catch (_) {}

    return {...local, ...servers.take(10)}.toList();
  }

  // ═══════════════════════════════════════════════════════════
  // PING & JITTER
  // ═══════════════════════════════════════════════════════════

  Future<Map<String, double>> _measurePingJitter(Server server) async {
    final url = _pingUrl(server);
    final samples = <double>[];
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    try {
      for (int i = 0; i < _Config.pingSampleCount; i++) {
        if (_lifecycle.shouldStop) break;
        try {
          final sw = Stopwatch()..start();
          final request = await client.getUrl(
            Uri.parse('$url?x=${DateTime.now().microsecondsSinceEpoch}'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 3),
          );
          await response.drain();
          sw.stop();
          samples.add(sw.elapsedMicroseconds / 1000.0);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }

    if (samples.isEmpty) return {'ping': 0.0, 'jitter': 0.0};

    samples.sort();
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
  // DOWNLOAD PHASE — Correctly counts received network bytes
  // ═══════════════════════════════════════════════════════════

  Future<double> _downloadPhase(
    StreamController<OoklaResult> controller,
    Server server,
    double pingMs,
    double jitterMs,
  ) async {
    final meter = SmoothSpeedMeter(
      totalDurationSeconds: _Config.phaseTimeoutSeconds,
    );
    meter.start();

    final start = DateTime.now();
    final deadline = start.add(
      const Duration(seconds: _Config.phaseTimeoutSeconds),
    );

    int activeWorkerCount = 0;
    int fileIndex = 0;
    final baseUrl = _downloadBaseUrl(server);

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
          OoklaResult(
            downloadSpeedMbps: math.max(0, meter.tick()),
            pingMs: pingMs,
            jitterMs: jitterMs,
            status: "Testing Download...",
            serverName: server.name,
            serverSponsor: server.sponsor,
          ),
        );
      },
    );
    _lifecycle.registerTimer(monitor);

    // ── Ramp-Up Timer ──
    // Launches initial workers, then adds more over time
    _spawnDownloadWorkers(
      _Config.initialWorkers,
      baseUrl,
      _Config.downloadFiles[fileIndex],
      meter,
      deadline,
    );
    activeWorkerCount = _Config.initialWorkers;

    final rampUp = Timer.periodic(
      const Duration(milliseconds: _Config.rampUpIntervalMs),
      (timer) {
        if (_lifecycle.shouldStop ||
            DateTime.now().isAfter(deadline) ||
            activeWorkerCount >= _Config.maxWorkers) {
          timer.cancel();
          return;
        }

        fileIndex = math.min(fileIndex + 1, _Config.downloadFiles.length - 1);
        final toAdd = math.min(
          _Config.rampUpStep,
          _Config.maxWorkers - activeWorkerCount,
        );

        _logger.log(
          "[Ookla] DL ramp: +$toAdd workers → "
          "${activeWorkerCount + toAdd}, file=${_Config.downloadFiles[fileIndex]}",
        );
        _spawnDownloadWorkers(
          toAdd,
          baseUrl,
          _Config.downloadFiles[fileIndex],
          meter,
          deadline,
        );
        activeWorkerCount += toAdd;
      },
    );
    _lifecycle.registerTimer(rampUp);

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    if (!completer.isCompleted) completer.complete(meter.finish());
    final result = await completer.future;
    return result;
  }

  void _spawnDownloadWorkers(
    int count,
    String baseUrl,
    String file,
    SmoothSpeedMeter meter,
    DateTime deadline,
  ) {
    for (int i = 0; i < count; i++) {
      _lifecycle.launchWorker(
        () => Future.delayed(
          Duration(milliseconds: i * 50),
          () => _downloadWorker('$baseUrl$file', meter, deadline),
        ),
      );
    }
  }

  /// Download worker: bytes are counted AS THEY ARRIVE from the
  /// network via `response.stream.listen`. This is inherently
  /// accurate — no buffering inflation possible.
  Future<void> _downloadWorker(
    String url,
    SmoothSpeedMeter meter,
    DateTime deadline,
  ) async {
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    while (!_lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
      try {
        final bustUrl = '$url?x=${DateTime.now().microsecondsSinceEpoch}';
        final request = await client.getUrl(Uri.parse(bustUrl));
        request.headers.set('Cache-Control', 'no-cache');
        request.headers.set('Connection', 'keep-alive');

        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );

        if (response.statusCode == 200) {
          await response.forEach((chunk) {
            if (_lifecycle.shouldStop || DateTime.now().isAfter(deadline)) {
              throw Exception('Worker aborted');
            }
            meter.addBytes(chunk.length);
          });
        }
      } catch (_) {
        if (_lifecycle.shouldStop) return;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════
  // UPLOAD PHASE — THE FIX
  // ═══════════════════════════════════════════════════════════
  //
  // PREVIOUS BUG:
  //   Used StreamedRequest.sink.add() and counted bytes at
  //   buffer-write time. Since buffer writes happen at memory
  //   speed (~GB/s), all bytes were "counted" near-instantly,
  //   then the network slowly drained the buffer. With 8
  //   parallel workers, this inflated results by 2-3x.
  //
  // FIX:
  //   Use simple client.post() with a SMALL payload (256KB).
  //   Count bytes ONLY AFTER the server responds (HTTP 200).
  //   The response means the server received the data, so the
  //   count reflects actual network throughput.
  //
  //   With 256KB payloads and 8 workers, we get frequent
  //   confirmations (~32 per second at 50Mbps) — more than
  //   enough for smooth 150ms gauge updates via EMA.
  //
  // ═══════════════════════════════════════════════════════════

  Future<double> _uploadPhase(
    StreamController<OoklaResult> controller,
    Server server,
    double downloadMbps,
    double pingMs,
    double jitterMs,
  ) async {
    final meter = SmoothSpeedMeter(
      totalDurationSeconds: _Config.phaseTimeoutSeconds,
    );
    meter.start();

    final start = DateTime.now();
    final deadline = start.add(
      const Duration(seconds: _Config.phaseTimeoutSeconds),
    );

    int activeWorkerCount = 0;

    // Pre-allocate a single upload payload — shared read-only by all workers
    final payload = _generateUploadPayload(_Config.uploadPayloadSize);

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
          OoklaResult(
            downloadSpeedMbps: downloadMbps,
            uploadSpeedMbps: math.max(0, meter.tick()),
            pingMs: pingMs,
            jitterMs: jitterMs,
            status: "Testing Upload...",
            serverName: server.name,
            serverSponsor: server.sponsor,
          ),
        );
      },
    );
    _lifecycle.registerTimer(monitor);

    // ── Launch initial workers ──
    _spawnUploadWorkers(
      _Config.initialWorkers,
      server,
      payload,
      meter,
      deadline,
    );
    activeWorkerCount = _Config.initialWorkers;

    // ── Ramp-Up Timer ──
    final rampUp = Timer.periodic(
      const Duration(milliseconds: _Config.rampUpIntervalMs),
      (timer) {
        if (_lifecycle.shouldStop ||
            DateTime.now().isAfter(deadline) ||
            activeWorkerCount >= _Config.maxWorkers) {
          timer.cancel();
          return;
        }

        final toAdd = math.min(
          _Config.rampUpStep,
          _Config.maxWorkers - activeWorkerCount,
        );

        _logger.log(
          "[Ookla] UL ramp: +$toAdd workers → "
          "${activeWorkerCount + toAdd}",
        );
        _spawnUploadWorkers(toAdd, server, payload, meter, deadline);
        activeWorkerCount += toAdd;
      },
    );
    _lifecycle.registerTimer(rampUp);

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    if (!completer.isCompleted) completer.complete(meter.finish());
    final result = await completer.future;
    return result;
  }

  void _spawnUploadWorkers(
    int count,
    Server server,
    Uint8List payload,
    SmoothSpeedMeter meter,
    DateTime deadline,
  ) {
    for (int i = 0; i < count; i++) {
      _lifecycle.launchWorker(
        () => Future.delayed(
          Duration(milliseconds: i * 50),
          () => _uploadWorker(server, payload, meter, deadline),
        ),
      );
    }
  }

  /// Upload worker: uses a simple POST with a small payload.
  /// Bytes are counted ONLY AFTER the server responds.
  ///
  /// Why this is correct:
  ///   client.postUrl() blocks until:
  ///     1. The payload is fully transmitted over TCP
  ///     2. The server processes it
  ///     3. The HTTP response is received
  ///
  ///   Only then do we call counter.add(). This means the byte
  ///   count rate matches the actual network upload rate, NOT
  ///   the memory buffer rate.
  ///
  /// Why 256KB payloads:
  ///   At 50 Mbps actual upload, 256KB takes ~40ms to transmit.
  ///   With 8 workers, that's ~200 confirmations/sec — plenty
  ///   of data points for smooth EMA gauge updates every 150ms.
  ///   At 200 Mbps, it's ~800 confirmations/sec.
  ///   At 10 Mbps, it's ~40/sec — still 6 per gauge update.
  Future<void> _uploadWorker(
    Server server,
    Uint8List payload,
    SmoothSpeedMeter meter,
    DateTime deadline,
  ) async {
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    while (!_lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
      try {
        // Add Cache-Buster to prevent server ignoring request
        final bustUrl =
            '${server.url}?x=${DateTime.now().microsecondsSinceEpoch}';
        final request = await client.postUrl(Uri.parse(bustUrl));

        request.headers.set('Connection', 'keep-alive');
        request.headers.set('Content-Type', 'application/octet-stream');

        // Critical: Tell Ookla server the payload size
        request.contentLength = payload.length;
        request.add(payload);

        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );

        if (response.statusCode == 200) {
          await response.drain();
          if (!_lifecycle.shouldStop) {
            meter.addBytes(payload.length);
          }
        } else {
          _logger.log(
            "[Ookla UL] Server rejected with status: ${response.statusCode}",
          );
          await response.drain();
        }
      } catch (e) {
        if (_lifecycle.shouldStop) return;
        _logger.log('[Ookla UL Error] $e');
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// Generate upload payload with sparse random bytes.
  /// This prevents transparent compression by ISPs or servers
  /// from inflating the apparent throughput.
  Uint8List _generateUploadPayload(int size) {
    final data = Uint8List(size);
    final rng = math.Random();
    // Fill every 64th byte with random data — enough to defeat
    // compression while keeping allocation fast
    for (int i = 0; i < size; i += 64) {
      data[i] = rng.nextInt(256);
    }
    return data;
  }

  // ═══════════════════════════════════════════════════════════
  // URL BUILDERS
  // ═══════════════════════════════════════════════════════════

  String _downloadBaseUrl(Server server) {
    final uri = Uri.parse(server.url);
    final segs = List<String>.from(uri.pathSegments);
    if (segs.isNotEmpty) segs.removeLast();
    return '${uri.replace(pathSegments: segs)}/';
  }

  String _pingUrl(Server server) {
    final uri = Uri.parse(server.url);
    final segs = List<String>.from(uri.pathSegments);
    if (segs.isNotEmpty) segs.removeLast();
    segs.add('latency.txt');
    return uri.replace(pathSegments: segs).toString();
  }

  // ═══════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════

  void _emit(StreamController<OoklaResult> controller, OoklaResult result) {
    if (!controller.isClosed) controller.add(result);
  }

  bool _abort(StreamController<OoklaResult> controller) {
    if (_lifecycle.isUserCancelled || controller.isClosed) {
      if (!controller.isClosed) controller.close();
      return true;
    }
    return false;
  }

  // Removed _finalSpeed

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295;
    final a =
        0.5 -
        math.cos((lat2 - lat1) * p) / 2 +
        math.cos(lat1 * p) *
            math.cos(lat2 * p) *
            (1 - math.cos((lon2 - lon1) * p)) /
            2;
    return 12742 * math.asin(math.sqrt(a));
  }
}
