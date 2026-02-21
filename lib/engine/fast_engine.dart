import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

/// Fast.com (Netflix OCA) speed test engine.
///
/// Discovery: fetches OCA target URLs from Fast.com API.
/// Latency: probes first OCA server with Range header to decide stream count.
/// Download: parallel GET requests to OCA endpoints.
/// Upload: parallel chunked POST with flush() backpressure.
class FastEngine extends SpeedTestEngine {
  static const String _token = 'YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm';
  static const int _maxStreams = 5;
  static const int _ulChunkBytes = 512 * 1024;
  static const Duration _connectTimeout = Duration(seconds: 10);

  final DebugLogger _logger = DebugLogger();

  @override
  String get engineName => 'Fast.com';

  @override
  bool get hasDiscovery => true;

  @override
  bool get hasLatencyTest => true;

  @override
  int get phaseDurationSeconds => 15;

  // ═══════════════════════════════════════════════════════════════
  // DISCOVERY — fetch Netflix OCA targets + probe latency
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<Map<String, dynamic>?> discover(TestLifecycle lifecycle) async {
    // Step 1: Fetch OCA targets from Fast.com API
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
      final urls = targets.map<String>((t) => t['url'].toString()).toList();

      if (urls.isEmpty) throw Exception('No Fast.com targets found');
      _logger.log('[Fast] ${urls.length} OCA targets acquired.');

      return {'urls': urls};
    } finally {
      client.close();
    }
  }

  @override
  Future<Map<String, double>> measureLatency(TestLifecycle lifecycle) async {
    // Probe not for ping display, but to decide stream count.
    // We return a minimal ping value; the real purpose is stream selection.
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
    final urls = metadata['urls'] as List<String>;

    // Probe latency to decide stream count
    final streams = await _probeLatency(urls.first, lifecycle);
    if (lifecycle.shouldStop) return;

    final client = io.HttpClient();
    client.connectionTimeout = _connectTimeout;
    lifecycle.registerClient(client);

    final n = streams < urls.length ? streams : urls.length;
    final workers = <Future<void>>[];
    for (int i = 0; i < n; i++) {
      workers.add(_dlWorker(client, urls[i], lifecycle, onBytes));
    }
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
    final urls = metadata['urls'] as List<String>;

    // Build incompressible payload
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    // Convert download URLs to upload URLs
    final uploadUrls = urls.map(_toUploadUrl).toList();
    _logger.log('[Fast UL] Upload URLs: ${uploadUrls.take(2)}...');

    final client = io.HttpClient();
    client.connectionTimeout = _connectTimeout;
    lifecycle.registerClient(client);

    final n = uploadUrls.length < _maxStreams ? uploadUrls.length : _maxStreams;
    final workers = <Future<void>>[];
    for (int i = 0; i < n; i++) {
      workers.add(_ulWorker(client, uploadUrls[i], chunk, lifecycle, onBytes));
    }
    await Future.wait(workers);
  }

  // ═══════════════════════════════════════════════════════════════
  // WORKERS
  // ═══════════════════════════════════════════════════════════════

  Future<void> _dlWorker(
    io.HttpClient client,
    String url,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
  ) async {
    final uri = Uri.parse(url);
    while (!lifecycle.shouldStop) {
      try {
        final request = await client.getUrl(uri);
        final response = await request.close();

        await for (final chunk in response) {
          if (lifecycle.shouldStop) break;
          onBytes(chunk.length);
        }
      } catch (e) {
        if (!lifecycle.shouldStop) {
          _logger.log('[Fast DL Worker] $e');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }

  Future<void> _ulWorker(
    io.HttpClient client,
    String url,
    Uint8List chunk,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
  ) async {
    final uri = Uri.parse(url);
    while (!lifecycle.shouldStop) {
      try {
        final request = await client.postUrl(uri);
        request.headers.contentType = io.ContentType.binary;
        request.headers.chunkedTransferEncoding = true;

        while (!lifecycle.shouldStop) {
          request.add(chunk);
          await request.flush(); // ← BLOCKS at network speed
          onBytes(chunk.length); // ← counted AFTER confirmation
        }

        try {
          final res = await request.close();
          await res.drain();
        } catch (_) {}
      } catch (e) {
        if (!lifecycle.shouldStop) {
          _logger.log('[Fast UL Worker] $e');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Convert Netflix OCA download URL → upload URL.
  String _toUploadUrl(String downloadUrl) {
    final uri = Uri.parse(downloadUrl);
    return uri.replace(path: '/speedtest/upload').toString();
  }

  /// Lightweight latency probe to decide optimal stream count.
  Future<int> _probeLatency(String url, TestLifecycle lifecycle) async {
    final probe = io.HttpClient();
    lifecycle.registerClient(probe);

    try {
      final sw = Stopwatch()..start();
      final req = await probe
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      req.headers.set('Range', 'bytes=0-0');
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
      return _maxStreams;
    }
  }
}
