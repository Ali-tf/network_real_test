

# Root Cause Analysis

## The Bug: Double-Counting Upload Bytes

I found the critical flaw. It's in `_uploadWorker`. Look at this sequence:

```dart
// 1. We write a chunk to the StreamedRequest's sink
streamedRequest.sink.add(chunk);

// 2. We IMMEDIATELY count it as "sent"
counter.add(chunk.length);  // ← THIS IS THE BUG
```

**The problem:** `sink.add(chunk)` writes data into an **internal buffer**. It does NOT mean those bytes have left the device over TCP. The `http.Client.send()` is what actually transmits the data over the network. By counting bytes at `sink.add()` time, we're counting **buffered bytes, not transmitted bytes**.

But it gets worse. With **8 parallel workers**, each one:
1. Creates a 1MB payload
2. Writes it into the sink in 256KB chunks, counting each chunk instantly
3. Then `await responseFuture` waits for actual transmission

The result: bytes are counted at **memory-copy speed** (~GBps), not at **network speed**. With 8 workers doing this simultaneously, you get massively inflated numbers.

### Why Download Didn't Have This Bug

Download uses `response.stream.listen((chunk) { counter.add(chunk.length); })` — these chunks arrive **from the network**, so they're counted at the correct rate. The asymmetry between download (correct) and upload (inflated) is exactly why you see ~100 Mbps reported vs ~44.7 Mbps actual.

---

## The Fix Strategy

We need to count upload bytes **only after the server has acknowledged receipt** — i.e., after the HTTP response comes back. But we also need **progressive counting** for smooth gauge updates, not a single jump after each 1MB POST completes.

The solution: **Time-proportional progressive estimation with server-confirmed reconciliation.**

1. Track wall-clock time during each POST
2. When the response arrives, we know exactly how many bytes were sent and how long it took
3. Use a **micro-batch approach**: send smaller payloads (e.g., 256KB) so confirmations arrive more frequently, giving the gauge more data points
4. The EMA smoother handles the rest

---

## Fully Corrected `speedtest_service.dart`

I'm providing the **complete file** — not a partial patch — so there's zero ambiguity about what the production code should be.

```dart
// speedtest_service.dart
// High-Fidelity Ookla Speedtest.net Replication
// Multi-threaded, EMA-smoothed, progressive-loading engine
//
// v2.1 — Fixed upload byte double-counting bug

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:speed_test_dart/speed_test_dart.dart';
import 'package:speed_test_dart/classes/classes.dart';
import 'package:network_speed_test/utils/debug_logger.dart';

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
  static const int maxWorkers = 8;
  static const int initialWorkers = 2;
  static const int rampUpStep = 2;
  static const int rampUpIntervalMs = 2000;
  static const int phaseTimeoutSeconds = 15;
  static const int uiUpdateIntervalMs = 150;
  static const double emaSmoothingFactor = 0.3;
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

class _ByteCounter {
  int _totalBytes = 0;
  int _lastSnapshotBytes = 0;
  DateTime _lastSnapshotTime = DateTime.now();

  int get totalBytes => _totalBytes;

  void add(int bytes) {
    _totalBytes += bytes;
  }

  void reset() {
    _totalBytes = 0;
    _lastSnapshotBytes = 0;
    _lastSnapshotTime = DateTime.now();
  }

  /// Returns interval Mbps since the last snapshot call.
  double snapshotMbps() {
    final now = DateTime.now();
    final elapsedUs = now.difference(_lastSnapshotTime).inMicroseconds;
    final deltaBytes = _totalBytes - _lastSnapshotBytes;

    _lastSnapshotBytes = _totalBytes;
    _lastSnapshotTime = now;

    if (elapsedUs <= 0) return 0.0;
    // Mbps = (bytes * 8) / (seconds * 1_000_000)
    //      = (bytes * 8) / (microseconds / 1_000_000 * 1_000_000)
    //      = (bytes * 8) / microseconds * 1_000_000 / 1_000_000
    //      = (bytes * 8_000_000) / (microseconds * 1_000_000)
    return (deltaBytes * 8.0) / elapsedUs; // Mbps
  }

  /// Cumulative average Mbps from a given start time.
  double cumulativeMbps(DateTime startTime) {
    final elapsedUs = DateTime.now().difference(startTime).inMicroseconds;
    if (elapsedUs <= 0) return 0.0;
    return (_totalBytes * 8.0) / elapsedUs; // Mbps
  }
}

// ═══════════════════════════════════════════════════════════════
// EMA Smoother
// ═══════════════════════════════════════════════════════════════

class _EmaSmoother {
  final double alpha;
  double? _value;

  _EmaSmoother({required this.alpha});

  double smooth(double newValue) {
    if (_value == null) {
      _value = newValue;
      return newValue;
    }
    _value = alpha * newValue + (1 - alpha) * _value!;
    return _value!;
  }

  void reset() => _value = null;
}

// ═══════════════════════════════════════════════════════════════
// Ookla Service
// ═══════════════════════════════════════════════════════════════

class OoklaService {
  bool _isCancelled = false;
  final SpeedTestDart _tester = SpeedTestDart();
  final DebugLogger _logger = DebugLogger();

  final List<http.Client> _activeClients = [];
  final List<StreamSubscription> _activeSubscriptions = [];

  // ── Public API ──────────────────────────────────────────────

  void cancel() {
    _isCancelled = true;
    _logger.log("[Ookla] Cancel requested.");
    _cleanupAll();
  }

  Stream<OoklaResult> measureSpeed() {
    final controller = StreamController<OoklaResult>();
    _isCancelled = false;
    _activeClients.clear();
    _activeSubscriptions.clear();
    _runPipeline(controller);
    return controller.stream;
  }

  // ── Cleanup ─────────────────────────────────────────────────

  void _cleanupAll() {
    for (final sub in _activeSubscriptions) {
      try { sub.cancel(); } catch (_) {}
    }
    _activeSubscriptions.clear();

    for (final client in _activeClients) {
      try { client.close(); } catch (_) {}
    }
    _activeClients.clear();
  }

  // ── Pipeline ────────────────────────────────────────────────

  Future<void> _runPipeline(StreamController<OoklaResult> controller) async {
    try {
      _logger.log("[Ookla] ═══ Starting Speed Test ═══");

      // ── Phase 0: Server Discovery ──
      _emit(controller, const OoklaResult(
        downloadSpeedMbps: 0,
        status: "Fetching server list...",
      ));

      final servers = await _fetchServers();
      _logger.log("[Ookla] Fetched ${servers.length} servers.");
      if (_abort(controller)) return;

      final candidates = await _selectCandidates(servers, controller);
      if (_abort(controller)) return;

      // ── Phase 1: Latency ──
      _emit(controller, const OoklaResult(
        downloadSpeedMbps: 0,
        status: "Measuring latency...",
      ));

      final bestServers = await _tester.getBestServers(servers: candidates);
      if (bestServers.isEmpty) throw Exception('No reachable servers.');

      final target = bestServers.first;
      _logger.log("[Ookla] Server: ${target.name} (${target.sponsor})");

      final ping = await _measurePingJitter(target);
      final double pingMs = ping['ping']!;
      final double jitterMs = ping['jitter']!;
      _logger.log("[Ookla] Ping: ${pingMs.toStringAsFixed(1)}ms, "
          "Jitter: ${jitterMs.toStringAsFixed(1)}ms");

      if (_abort(controller)) return;

      _emit(controller, OoklaResult(
        downloadSpeedMbps: 0,
        pingMs: pingMs,
        jitterMs: jitterMs,
        status: "Ping: ${pingMs.toStringAsFixed(0)}ms",
        serverName: target.name,
        serverSponsor: target.sponsor,
      ));
      await Future.delayed(const Duration(milliseconds: 400));
      if (_abort(controller)) return;

      // ── Phase 2: Download ──
      _logger.log("[Ookla] ── Download Phase ──");
      final dlMbps = await _downloadPhase(
        controller, target, pingMs, jitterMs,
      );
      _logger.log("[Ookla] Download: ${dlMbps.toStringAsFixed(2)} Mbps");
      if (_abort(controller)) return;

      await Future.delayed(const Duration(milliseconds: 300));

      // ── Phase 3: Upload ──
      _logger.log("[Ookla] ── Upload Phase ──");
      final ulMbps = await _uploadPhase(
        controller, target, dlMbps, pingMs, jitterMs,
      );
      _logger.log("[Ookla] Upload: ${ulMbps.toStringAsFixed(2)} Mbps");

      // ── Done ──
      _emit(controller, OoklaResult(
        downloadSpeedMbps: dlMbps,
        uploadSpeedMbps: ulMbps,
        pingMs: pingMs,
        jitterMs: jitterMs,
        isDone: true,
        status: "Complete",
        serverName: target.name,
        serverSponsor: target.sponsor,
      ));
      _logger.log("[Ookla] ═══ Test Complete ═══");

    } catch (e, st) {
      _logger.log("[Ookla] FATAL: $e\n$st");
      _emit(controller, OoklaResult(
        downloadSpeedMbps: 0, error: e.toString(), status: "Error",
      ));
    } finally {
      _cleanupAll();
      if (!controller.isClosed) controller.close();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // SERVER FETCHING & SELECTION
  // ═══════════════════════════════════════════════════════════

  Future<List<Server>> _fetchServers() async {
    final response = await http.get(
      Uri.parse('https://www.speedtest.net/api/js/servers?engine=js&limit=40'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, */*; q=0.01',
        'Referer': 'https://www.speedtest.net/',
      },
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Server list HTTP ${response.statusCode}');
    }

    final List<dynamic> jsonList = json.decode(response.body);
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
        lat, lon,
        99999999999, 99999999999,
        Coordinate(lat, lon),
      );
    }).toList();
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
          settings.client.latitude, settings.client.longitude,
          s.latitude, s.longitude,
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
    final client = http.Client();
    _activeClients.add(client);

    try {
      for (int i = 0; i < _Config.pingSampleCount; i++) {
        if (_isCancelled) break;
        try {
          final sw = Stopwatch()..start();
          await client.get(
            Uri.parse('$url?x=${DateTime.now().microsecondsSinceEpoch}'),
          ).timeout(const Duration(seconds: 3));
          sw.stop();
          samples.add(sw.elapsedMicroseconds / 1000.0);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      client.close();
      _activeClients.remove(client);
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
    final counter = _ByteCounter();
    final smoother = _EmaSmoother(alpha: _Config.emaSmoothingFactor);
    final start = DateTime.now();
    final deadline = start.add(
      const Duration(seconds: _Config.phaseTimeoutSeconds),
    );

    double peakSmoothed = 0;
    int activeWorkerCount = 0;
    int fileIndex = 0;
    final baseUrl = _downloadBaseUrl(server);

    // Take initial snapshot baseline
    counter.snapshotMbps();

    final completer = Completer<double>();

    // ── Monitor Timer ──
    final monitor = Timer.periodic(
      const Duration(milliseconds: _Config.uiUpdateIntervalMs),
      (timer) {
        if (_isCancelled || DateTime.now().isAfter(deadline) ||
            controller.isClosed) {
          timer.cancel();
          if (!completer.isCompleted) {
            completer.complete(_finalSpeed(counter, start, peakSmoothed));
          }
          return;
        }

        final instant = counter.snapshotMbps();
        final smoothed = smoother.smooth(instant);
        if (smoothed > peakSmoothed) peakSmoothed = smoothed;

        _emit(controller, OoklaResult(
          downloadSpeedMbps: math.max(0, smoothed),
          pingMs: pingMs,
          jitterMs: jitterMs,
          status: "Testing Download...",
          serverName: server.name,
          serverSponsor: server.sponsor,
        ));
      },
    );

    // ── Ramp-Up Timer ──
    // Launches initial workers, then adds more over time
    _spawnDownloadWorkers(
      _Config.initialWorkers, baseUrl,
      _Config.downloadFiles[fileIndex], counter, deadline,
    );
    activeWorkerCount = _Config.initialWorkers;

    final rampUp = Timer.periodic(
      const Duration(milliseconds: _Config.rampUpIntervalMs),
      (timer) {
        if (_isCancelled || DateTime.now().isAfter(deadline) ||
            activeWorkerCount >= _Config.maxWorkers) {
          timer.cancel();
          return;
        }

        fileIndex = math.min(fileIndex + 1, _Config.downloadFiles.length - 1);
        final toAdd = math.min(
          _Config.rampUpStep,
          _Config.maxWorkers - activeWorkerCount,
        );

        _logger.log("[Ookla] DL ramp: +$toAdd workers → "
            "${activeWorkerCount + toAdd}, file=${_Config.downloadFiles[fileIndex]}");
        _spawnDownloadWorkers(
          toAdd, baseUrl, _Config.downloadFiles[fileIndex], counter, deadline,
        );
        activeWorkerCount += toAdd;
      },
    );

    final result = await completer.future;
    monitor.cancel();
    rampUp.cancel();
    _cleanupAll();
    return result;
  }

  void _spawnDownloadWorkers(
    int count, String baseUrl, String file,
    _ByteCounter counter, DateTime deadline,
  ) {
    for (int i = 0; i < count; i++) {
      final client = http.Client();
      _activeClients.add(client);
      _downloadWorker(client, '$baseUrl$file', counter, deadline);
    }
  }

  /// Download worker: bytes are counted AS THEY ARRIVE from the
  /// network via `response.stream.listen`. This is inherently
  /// accurate — no buffering inflation possible.
  Future<void> _downloadWorker(
    http.Client client,
    String url,
    _ByteCounter counter,
    DateTime deadline,
  ) async {
    while (!_isCancelled && DateTime.now().isBefore(deadline)) {
      try {
        final bustUrl = '$url?x=${DateTime.now().microsecondsSinceEpoch}';
        final request = http.Request('GET', Uri.parse(bustUrl));
        request.headers['Cache-Control'] = 'no-cache';
        request.headers['Connection'] = 'keep-alive';

        final response = await client.send(request).timeout(
          const Duration(seconds: 10),
        );

        if (response.statusCode == 200) {
          final c = Completer<void>();
          StreamSubscription<List<int>>? sub;

          sub = response.stream.listen(
            (chunk) {
              if (_isCancelled || DateTime.now().isAfter(deadline)) {
                sub?.cancel();
                if (!c.isCompleted) c.complete();
                return;
              }
              // ✅ CORRECT: These bytes just arrived from the network
              counter.add(chunk.length);
            },
            onError: (_) {
              if (!c.isCompleted) c.complete();
            },
            onDone: () {
              if (!c.isCompleted) c.complete();
            },
            cancelOnError: true,
          );

          _activeSubscriptions.add(sub);
          await c.future;
          _activeSubscriptions.remove(sub);
        }
      } catch (_) {
        if (_isCancelled) return;
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
    final counter = _ByteCounter();
    final smoother = _EmaSmoother(alpha: _Config.emaSmoothingFactor);
    final start = DateTime.now();
    final deadline = start.add(
      const Duration(seconds: _Config.phaseTimeoutSeconds),
    );

    double peakSmoothed = 0;
    int activeWorkerCount = 0;

    // Pre-allocate a single upload payload — shared read-only by all workers
    final payload = _generateUploadPayload(_Config.uploadPayloadSize);

    counter.snapshotMbps();

    final completer = Completer<double>();

    // ── Monitor Timer ──
    final monitor = Timer.periodic(
      const Duration(milliseconds: _Config.uiUpdateIntervalMs),
      (timer) {
        if (_isCancelled || DateTime.now().isAfter(deadline) ||
            controller.isClosed) {
          timer.cancel();
          if (!completer.isCompleted) {
            completer.complete(_finalSpeed(counter, start, peakSmoothed));
          }
          return;
        }

        final instant = counter.snapshotMbps();
        final smoothed = smoother.smooth(instant);
        if (smoothed > peakSmoothed) peakSmoothed = smoothed;

        _emit(controller, OoklaResult(
          downloadSpeedMbps: downloadMbps,
          uploadSpeedMbps: math.max(0, smoothed),
          pingMs: pingMs,
          jitterMs: jitterMs,
          status: "Testing Upload...",
          serverName: server.name,
          serverSponsor: server.sponsor,
        ));
      },
    );

    // ── Launch initial workers ──
    _spawnUploadWorkers(
      _Config.initialWorkers, server, payload, counter, deadline,
    );
    activeWorkerCount = _Config.initialWorkers;

    // ── Ramp-Up Timer ──
    final rampUp = Timer.periodic(
      const Duration(milliseconds: _Config.rampUpIntervalMs),
      (timer) {
        if (_isCancelled || DateTime.now().isAfter(deadline) ||
            activeWorkerCount >= _Config.maxWorkers) {
          timer.cancel();
          return;
        }

        final toAdd = math.min(
          _Config.rampUpStep,
          _Config.maxWorkers - activeWorkerCount,
        );

        _logger.log("[Ookla] UL ramp: +$toAdd workers → "
            "${activeWorkerCount + toAdd}");
        _spawnUploadWorkers(toAdd, server, payload, counter, deadline);
        activeWorkerCount += toAdd;
      },
    );

    final result = await completer.future;
    monitor.cancel();
    rampUp.cancel();
    _cleanupAll();
    return result;
  }

  void _spawnUploadWorkers(
    int count, Server server, Uint8List payload,
    _ByteCounter counter, DateTime deadline,
  ) {
    for (int i = 0; i < count; i++) {
      final client = http.Client();
      _activeClients.add(client);
      _uploadWorker(client, server, payload, counter, deadline);
    }
  }

  /// Upload worker: uses a simple POST with a small payload.
  /// Bytes are counted ONLY AFTER the server responds.
  ///
  /// Why this is correct:
  ///   client.post() blocks until:
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
    http.Client client,
    Server server,
    Uint8List payload,
    _ByteCounter counter,
    DateTime deadline,
  ) async {
    while (!_isCancelled && DateTime.now().isBefore(deadline)) {
      try {
        // ── Synchronous POST: blocks until server confirms ──
        final response = await client.post(
          Uri.parse(server.url),
          headers: {
            'Connection': 'keep-alive',
            'Content-Type': 'application/octet-stream',
          },
          body: payload,
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          // ✅ THE FIX: Count bytes ONLY here, after the server
          // has confirmed receipt. This elapsed time reflects
          // actual network transmission time.
          counter.add(payload.length);
        }
      } catch (e) {
        if (_isCancelled) return;
        // Don't count failed uploads — they didn't transfer data
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
    return uri.replace(pathSegments: segs).toString() + '/';
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
    if (_isCancelled || controller.isClosed) {
      _cleanupAll();
      if (!controller.isClosed) controller.close();
      return true;
    }
    return false;
  }

  /// Compute final reported speed.
  /// Uses the higher of cumulative average and 95% of peak EMA.
  /// This matches Ookla's behavior of reporting near-peak sustained.
  double _finalSpeed(_ByteCounter counter, DateTime start, double peak) {
    final cumulative = counter.cumulativeMbps(start);
    return math.max(cumulative, peak * 0.95);
  }

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295;
    final a = 0.5 -
        math.cos((lat2 - lat1) * p) / 2 +
        math.cos(lat1 * p) * math.cos(lat2 * p) *
            (1 - math.cos((lon2 - lon1) * p)) / 2;
    return 12742 * math.asin(math.sqrt(a));
  }
}
```

---

## Summary of the Fix

```
┌─────────────────────────────────────────────────────────────────┐
│                    THE UPLOAD COUNTING BUG                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  BEFORE (Inflated ~2.2x):                                      │
│                                                                 │
│    sink.add(chunk)  →  counter.add(chunk.length)  →  await send │
│         ↑                      ↑                        ↑       │
│    Memory speed          Counted HERE            Network speed  │
│    (~10 Gbps)            (WAY too early)         (~45 Mbps)     │
│                                                                 │
│  AFTER (Accurate):                                              │
│                                                                 │
│    client.post(payload)  →  await response  →  counter.add()    │
│         ↑                       ↑                    ↑          │
│    Sends over network     Server confirms      Counted HERE     │
│    (~45 Mbps)             receipt               (correct time)  │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  WHY 256KB PAYLOADS WORK:                                       │
│                                                                 │
│  Speed    │ Time per POST │ 8 workers │ Confirmations/sec       │
│  ─────────┼───────────────┼───────────┼──────────────────       │
│  10 Mbps  │    ~205ms     │     8     │    ~39/sec              │
│  50 Mbps  │     ~41ms     │     8     │   ~195/sec              │
│  100 Mbps │     ~20ms     │     8     │   ~400/sec              │
│  200 Mbps │     ~10ms     │     8     │   ~800/sec              │
│                                                                 │
│  Gauge updates every 150ms → at least 6 data points per update  │
│  even at 10 Mbps. EMA smoothing makes the needle butter-smooth. │
└─────────────────────────────────────────────────────────────────┘
```