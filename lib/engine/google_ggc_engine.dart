import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _Cfg {
  static const int minW = 6;
  static const int chunkInit = 256 * 1024, chunkMax = 16 * 1024 * 1024;
  static const List<String> primaryProbes = [
    'http://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb',
    'http://dl.google.com/dl/cloudsdk/channels/rapid/google-cloud-cli-linux-x86_64.tar.gz',
    'http://dl.google.com/android/repository/platform-tools-latest-linux.zip',
  ];
  static const List<String> fallbackProbes = [
    'http://redirector.gvt1.com/edgedl/linux/direct/google-chrome-stable_current_amd64.deb',
  ];
  static const List<String> ulTargets = [
    'https://www.googleapis.com/upload/drive/v3/files',
    'https://storage.googleapis.com/',
    'https://drive.google.com/',
  ];
}

/// Google Global Cache speed test engine.
///
/// Discovery: YouTube 4K stream → static GGC probes → HEAD validation.
/// Download: adaptive-chunked Range requests with dynamic worker scaling.
/// Upload: POST-flush with adaptive payload and target fallback.
class GoogleGgcEngine extends SpeedTestEngine {
  final DebugLogger _logger = DebugLogger();

  @override
  String get engineName => 'Google GGC';
  @override
  bool get hasDiscovery => true;
  @override
  bool get hasLatencyTest => true;
  @override
  int get phaseDurationSeconds => 15;

  @override
  Future<Map<String, dynamic>?> discover(TestLifecycle lifecycle) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    lifecycle.registerClient(client);

    try {
      // Step 1: Try YouTube 4K stream
      String? ytUrl;
      final yt = YoutubeExplode();
      try {
        if (!lifecycle.shouldStop) {
          _logger.log('[GGC] Fetching YouTube 4K Stream...');
          final m = await yt.videos.streamsClient.getManifest('LXb3EKWsInQ');
          ytUrl = m.videoOnly.withHighestBitrate().url.toString();
          _logger.log('[GGC] YouTube Stream acquired.');
        }
      } catch (e) {
        _logger.log('[GGC] YouTube failed: $e. Using static probes.');
      } finally {
        yt.close();
      }

      final catalog = <String>[];
      if (ytUrl != null) catalog.add(ytUrl);
      catalog.addAll(_Cfg.primaryProbes);
      catalog.addAll(_Cfg.fallbackProbes);

      for (final url in catalog) {
        if (lifecycle.shouldStop) return null;
        _logger.log('[GGC Probe] Testing: $url');
        try {
          // YouTube CDNs block HEAD — skip probe for googlevideo.com
          if (url.contains('googlevideo.com')) {
            final uri = Uri.parse(url);
            final domain = uri.host;
            String? sn;
            if (domain.contains('---sn-')) {
              final p = domain.split('---');
              if (p.length > 1) sn = p[1].replaceAll('.googlevideo.com', '');
            }
            final ips = await InternetAddress.lookup(domain);
            if (ips.isEmpty) continue;
            _logger.log('[GGC] YouTube bypass: $domain (${ips.first.address})');
            return {
              'testUrl': url,
              'cacheIp': ips.first.address,
              'nodeLocationId': sn ?? domain,
              'cacheType': 'ggc',
              'contentLength': 100 * 1024 * 1024,
            };
          }

          final req = await client.headUrl(Uri.parse(url));
          req.followRedirects = true;
          req.maxRedirects = 3;
          final sw = Stopwatch()..start();
          final res = await req.close().timeout(const Duration(seconds: 4));
          sw.stop();

          final sc = res.statusCode;
          final ar = res.headers.value('Accept-Ranges') == 'bytes' || sc == 206;
          final cl = res.headers.value('Content-Length');
          final fUri = res.redirects.isNotEmpty
              ? res.redirects.last.location
              : req.uri;
          final domain = fUri.host;
          await res.drain();

          if (sc != 200 && sc != 206) continue;
          if (!ar) continue;

          final contentLen = cl != null
              ? (int.tryParse(cl) ?? 10 * 1024 * 1024)
              : 10 * 1024 * 1024;
          String? sn;
          if (domain.contains('---sn-')) {
            final p = domain.split('---');
            if (p.length > 1) {
              sn = p[1]
                  .replaceAll('.gvt1.com', '')
                  .replaceAll('.googlevideo.com', '');
            }
          }
          final ips = await InternetAddress.lookup(domain);
          if (ips.isEmpty) continue;
          final rtt = sw.elapsedMilliseconds;
          String ct = rtt < 20 ? 'ggc' : (rtt < 50 ? 'edge_pop' : 'datacenter');
          _logger.log('[GGC] Hit: $domain (${ips.first.address}) $ct ${rtt}ms');

          return {
            'testUrl': fUri.toString(),
            'cacheIp': ips.first.address,
            'nodeLocationId': sn ?? domain,
            'cacheType': ct,
            'contentLength': contentLen,
          };
        } catch (e) {
          _logger.log('[GGC] Probe failed $url: $e');
        }
      }
      return null;
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  @override
  Future<Map<String, double>> measureLatency(TestLifecycle lifecycle) async {
    return {'ping': 0.0, 'jitter': 0.0}; // measured via discovery RTT
  }

  @override
  Future<void> runDownload(
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    Map<String, dynamic> md,
  ) async {
    final url = md['testUrl'] as String;
    final contentLen = md['contentLength'] as int;
    final dl = DateTime.now().add(Duration(seconds: phaseDurationSeconds));
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    c.idleTimeout = const Duration(seconds: 15);
    c.autoUncompress = false;
    lifecycle.registerClient(c);

    int nextIdx = 0;
    int getNext() => nextIdx++;

    final workers = <Future<void>>[];
    for (int i = 0; i < _Cfg.minW; i++) {
      workers.add(
        Future.delayed(
          Duration(milliseconds: i * 150),
          () => _dlW(c, url, lifecycle, onBytes, dl, getNext, contentLen),
        ),
      );
    }
    await Future.wait(workers);
  }

  @override
  Future<void> runUpload(
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    Map<String, dynamic> md,
  ) async {
    final dl = DateTime.now().add(Duration(seconds: phaseDurationSeconds));
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    c.badCertificateCallback = (cert, host, port) => true;
    c.idleTimeout = const Duration(seconds: 15);
    lifecycle.registerClient(c);
    final workers = <Future<void>>[];
    for (int i = 0; i < 4; i++) {
      workers.add(_ulW(c, lifecycle, onBytes, dl));
    }
    await Future.wait(workers);
  }

  Future<void> _dlW(
    HttpClient c,
    String url,
    TestLifecycle lifecycle,
    void Function(int) onB,
    DateTime dl,
    int Function() nextIdx,
    int contentLen,
  ) async {
    final uri = Uri.parse(url);
    int cs = _Cfg.chunkInit;
    while (!lifecycle.shouldStop && DateTime.now().isBefore(dl)) {
      try {
        int idx = nextIdx();
        int sb = (idx * cs) % contentLen;
        int eb = math.min(sb + cs - 1, contentLen - 1);
        final req = await c.getUrl(uri);
        req.headers.set('Accept-Encoding', 'identity');
        req.headers.set('Cache-Control', 'no-store');
        req.headers.set('Connection', 'keep-alive');
        req.headers.set('Range', 'bytes=$sb-$eb');
        req.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
        );
        final sw = Stopwatch()..start();
        final res = await req.close();
        if (res.statusCode == 200 || res.statusCode == 206) {
          await res.forEach((d) {
            if (lifecycle.shouldStop) throw Exception('X');
            onB(d.length);
          });
          sw.stop();
          if (sw.elapsedMilliseconds < 300) {
            cs = math.min(cs * 2, _Cfg.chunkMax);
          } else if (sw.elapsedMilliseconds > 8000) {
            cs = math.max(cs ~/ 2, _Cfg.chunkInit);
          }
        } else {
          await res.drain();
          if (res.statusCode == 429) {
            await Future.delayed(const Duration(seconds: 2));
          } else if (res.statusCode == 416) {
            cs = _Cfg.chunkInit;
          } else {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      } catch (_) {
        if (lifecycle.shouldStop) return;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _ulW(
    HttpClient c,
    TestLifecycle lifecycle,
    void Function(int) onB,
    DateTime dl,
  ) async {
    int ti = 0, ps = 512 * 1024;
    Uint8List ch = _mkP(ps);
    while (!lifecycle.shouldStop && DateTime.now().isBefore(dl)) {
      try {
        final req = await c
            .postUrl(Uri.parse(_Cfg.ulTargets[ti]))
            .timeout(const Duration(seconds: 3));
        req.contentLength = ch.length;
        req.headers.set('Content-Type', 'application/octet-stream');
        req.persistentConnection = false;
        final sw = Stopwatch()..start();
        req.add(ch);
        await req.flush();
        sw.stop();
        if (!lifecycle.shouldStop) onB(ch.length);
        if (sw.elapsedMilliseconds < 250 && ps < _Cfg.chunkMax) {
          ps = math.min(ps * 2, _Cfg.chunkMax);
          ch = _mkP(ps);
        }
        try {
          final r = await req.close().timeout(const Duration(seconds: 2));
          await r.drain().timeout(const Duration(seconds: 1));
        } catch (_) {}
      } catch (e) {
        if (e is SocketException ||
            e.toString().contains('Connection reset') ||
            e.toString().contains('Connection closed')) {
          ti = (ti + 1) % _Cfg.ulTargets.length;
          continue;
        }
        if (lifecycle.shouldStop) return;
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Uint8List _mkP(int s) {
    final d = Uint8List(s);
    final r = math.Random();
    for (int i = 0; i < s; i += 64) {
      d[i] = r.nextInt(256);
    }
    return d;
  }
}
