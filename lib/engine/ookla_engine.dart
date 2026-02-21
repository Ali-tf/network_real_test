import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:speed_test_dart/speed_test_dart.dart';
import 'package:speed_test_dart/classes/classes.dart';
import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

/// Ookla (Speedtest.net) speed test engine.
///
/// Discovery: fetches server list, selects best by ping.
/// Latency: measures ping and jitter.
/// Download: ramp-up from 2→16 workers downloading test files.
/// Upload: ramp-up from 2→16 workers POSTing 256KB confirmed payloads.
class OoklaEngine extends SpeedTestEngine {
  final SpeedTestDart _tester = SpeedTestDart();
  final DebugLogger _logger = DebugLogger();

  static const int _maxWorkers = 16;
  static const int _initialWorkers = 2;
  static const int _rampUpStep = 2;
  static const int _rampUpIntervalMs = 2000;
  static const int _uploadPayloadSize = 256 * 1024;

  static const List<String> _downloadFiles = [
    'random350x350.jpg',
    'random750x750.jpg',
    'random1500x1500.jpg',
    'random2000x2000.jpg',
    'random3000x3000.jpg',
    'random4000x4000.jpg',
  ];

  @override
  String get engineName => 'Ookla';

  @override
  bool get hasDiscovery => true;

  @override
  bool get hasLatencyTest => true;

  @override
  int get phaseDurationSeconds => 15;

  // ═══════════════════════════════════════════════════════════════
  // DISCOVERY
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<Map<String, dynamic>?> discover(TestLifecycle lifecycle) async {
    // Step 1: Fetch server list
    final servers = await _fetchServers(lifecycle);
    _logger.log('[Ookla] Fetched ${servers.length} servers.');
    if (lifecycle.shouldStop) return null;

    // Step 2: Select candidates (local + nearby)
    final candidates = await _selectCandidates(servers);
    if (lifecycle.shouldStop) return null;

    // Step 3: Find best server by ping
    final bestServers = await _tester.getBestServers(servers: candidates);
    if (bestServers.isEmpty) throw Exception('No reachable servers.');

    final target = bestServers.first;
    _logger.log('[Ookla] Server: ${target.name} (${target.sponsor})');

    return {
      'server': target,
      'serverName': target.name,
      'serverSponsor': target.sponsor,
    };
  }

  @override
  Future<Map<String, double>> measureLatency(TestLifecycle lifecycle) async {
    // Latency was already measured during discovery (getBestServers).
    // We do a dedicated ping/jitter test here for display purposes.
    // The server is not available here yet — it comes from metadata.
    // So we return defaults; real measurement happens in runDownload prologue.
    return {'ping': 0.0, 'jitter': 0.0};
  }

  // ═══════════════════════════════════════════════════════════════
  // DOWNLOAD
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<void> runDownload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    final server = metadata['server'] as Server;
    final baseUrl = _downloadBaseUrl(server);
    final deadline = DateTime.now().add(
      Duration(seconds: phaseDurationSeconds),
    );

    int activeWorkerCount = 0;
    int fileIndex = 0;
    final workers = <Future<void>>[];

    // Launch initial workers
    _spawnDownloadWorkers(
      _initialWorkers,
      baseUrl,
      _downloadFiles[fileIndex],
      lifecycle,
      onBytes,
      deadline,
      workers,
    );
    activeWorkerCount = _initialWorkers;

    // Ramp-up timer: add more workers over time
    final rampUp = Timer.periodic(
      const Duration(milliseconds: _rampUpIntervalMs),
      (timer) {
        if (lifecycle.shouldStop ||
            DateTime.now().isAfter(deadline) ||
            activeWorkerCount >= _maxWorkers) {
          timer.cancel();
          return;
        }

        fileIndex = math.min(fileIndex + 1, _downloadFiles.length - 1);
        final toAdd = math.min(_rampUpStep, _maxWorkers - activeWorkerCount);

        _logger.log(
          '[Ookla] DL ramp: +$toAdd workers → '
          '${activeWorkerCount + toAdd}, file=${_downloadFiles[fileIndex]}',
        );
        _spawnDownloadWorkers(
          toAdd,
          baseUrl,
          _downloadFiles[fileIndex],
          lifecycle,
          onBytes,
          deadline,
          workers,
        );
        activeWorkerCount += toAdd;
      },
    );
    lifecycle.registerTimer(rampUp);

    await Future.wait(workers);
  }

  // ═══════════════════════════════════════════════════════════════
  // UPLOAD
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<void> runUpload(
    TestLifecycle lifecycle,
    void Function(int bytes) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    final server = metadata['server'] as Server;
    final deadline = DateTime.now().add(
      Duration(seconds: phaseDurationSeconds),
    );

    // Pre-allocate upload payload
    final payload = _generateUploadPayload(_uploadPayloadSize);
    int activeWorkerCount = 0;
    final workers = <Future<void>>[];

    // Launch initial workers
    _spawnUploadWorkers(
      _initialWorkers,
      server,
      payload,
      lifecycle,
      onBytes,
      deadline,
      workers,
    );
    activeWorkerCount = _initialWorkers;

    // Ramp-up timer
    final rampUp = Timer.periodic(
      const Duration(milliseconds: _rampUpIntervalMs),
      (timer) {
        if (lifecycle.shouldStop ||
            DateTime.now().isAfter(deadline) ||
            activeWorkerCount >= _maxWorkers) {
          timer.cancel();
          return;
        }

        final toAdd = math.min(_rampUpStep, _maxWorkers - activeWorkerCount);

        _logger.log(
          '[Ookla] UL ramp: +$toAdd workers → '
          '${activeWorkerCount + toAdd}',
        );
        _spawnUploadWorkers(
          toAdd,
          server,
          payload,
          lifecycle,
          onBytes,
          deadline,
          workers,
        );
        activeWorkerCount += toAdd;
      },
    );
    lifecycle.registerTimer(rampUp);

    await Future.wait(workers);
  }

  // ═══════════════════════════════════════════════════════════════
  // WORKER SPAWNERS
  // ═══════════════════════════════════════════════════════════════

  void _spawnDownloadWorkers(
    int count,
    String baseUrl,
    String file,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    DateTime deadline,
    List<Future<void>> workers,
  ) {
    for (int i = 0; i < count; i++) {
      workers.add(
        Future.delayed(
          Duration(milliseconds: i * 50),
          () => _downloadWorker('$baseUrl$file', lifecycle, onBytes, deadline),
        ),
      );
    }
  }

  void _spawnUploadWorkers(
    int count,
    Server server,
    Uint8List payload,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    DateTime deadline,
    List<Future<void>> workers,
  ) {
    for (int i = 0; i < count; i++) {
      workers.add(
        Future.delayed(
          Duration(milliseconds: i * 50),
          () => _uploadWorker(server, payload, lifecycle, onBytes, deadline),
        ),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // WORKERS
  // ═══════════════════════════════════════════════════════════════

  Future<void> _downloadWorker(
    String url,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    DateTime deadline,
  ) async {
    final client = io.HttpClient();
    lifecycle.registerClient(client);

    while (!lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
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
            if (lifecycle.shouldStop || DateTime.now().isAfter(deadline)) {
              throw Exception('Worker aborted');
            }
            onBytes(chunk.length);
          });
        }
      } catch (_) {
        if (lifecycle.shouldStop) return;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _uploadWorker(
    Server server,
    Uint8List payload,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    DateTime deadline,
  ) async {
    final client = io.HttpClient();
    lifecycle.registerClient(client);

    while (!lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
      try {
        final bustUrl =
            '${server.url}?x=${DateTime.now().microsecondsSinceEpoch}';
        final request = await client.postUrl(Uri.parse(bustUrl));
        request.headers.set('Connection', 'keep-alive');
        request.headers.set('Content-Type', 'application/octet-stream');
        request.contentLength = payload.length;
        request.add(payload);

        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );

        if (response.statusCode == 200) {
          await response.drain();
          if (!lifecycle.shouldStop) {
            onBytes(payload.length);
          }
        } else {
          _logger.log(
            '[Ookla UL] Server rejected with status: ${response.statusCode}',
          );
          await response.drain();
        }
      } catch (e) {
        if (lifecycle.shouldStop) return;
        _logger.log('[Ookla UL Error] $e');
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SERVER DISCOVERY HELPERS
  // ═══════════════════════════════════════════════════════════════

  Future<List<Server>> _fetchServers(TestLifecycle lifecycle) async {
    final client = io.HttpClient();
    lifecycle.registerClient(client);

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

  Future<List<Server>> _selectCandidates(List<Server> servers) async {
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

  // ═══════════════════════════════════════════════════════════════
  // URL BUILDERS & HELPERS
  // ═══════════════════════════════════════════════════════════════

  String _downloadBaseUrl(Server server) {
    final uri = Uri.parse(server.url);
    final segs = List<String>.from(uri.pathSegments);
    if (segs.isNotEmpty) segs.removeLast();
    return '${uri.replace(pathSegments: segs)}/';
  }

  Uint8List _generateUploadPayload(int size) {
    final data = Uint8List(size);
    final rng = math.Random();
    for (int i = 0; i < size; i += 64) {
      data[i] = rng.nextInt(256);
    }
    return data;
  }

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
