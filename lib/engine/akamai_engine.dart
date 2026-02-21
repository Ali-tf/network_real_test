import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

class _Cfg {
  static const int minW = 4, maxW = 8;
  static const int chunkInit = 256 * 1024, chunkMax = 8 * 1024 * 1024;
  static const List<String> probes = [
    'http://swcdn.apple.com/content/downloads/28/01/041-88407-A_T8D7833FO7/0y7xlyp38xrt816x5f14x13a69aoxr8p25/Safari15.6.1BigSurAuto.pkg',
    'http://ardownload2.adobe.com/pub/adobe/reader/win/AcroRdrDC2100120155_en_US.exe',
    'http://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe',
  ];
  static const List<String> ulTargets = [
    'https://api.tiktokv.com/',
    'https://www.tiktok.com/',
    'https://www.icloud.com/',
    'https://gateway.icloud.com/',
  ];
}

class AkamaiEngine extends SpeedTestEngine {
  final DebugLogger _logger = DebugLogger();

  @override
  String get engineName => 'Akamai';
  @override
  bool get hasDiscovery => true;
  @override
  bool get hasLatencyTest => true;
  @override
  int get phaseDurationSeconds => 15;

  @override
  Future<Map<String, dynamic>?> discover(TestLifecycle lifecycle) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    c.badCertificateCallback = (cert, host, port) => true;
    lifecycle.registerClient(c);
    try {
      for (final url in _Cfg.probes) {
        if (lifecycle.shouldStop) return null;
        final domain = Uri.parse(url).host;
        List<InternetAddress> ips;
        try {
          ips = await InternetAddress.lookup(domain);
        } catch (_) {
          continue;
        }
        if (ips.isEmpty) continue;
        final edgeIp = ips.first.address;
        try {
          final req = await c.headUrl(Uri.parse(url));
          final res = await req.close().timeout(const Duration(seconds: 4));
          await res.drain();
          if (res.statusCode != 200 && res.statusCode != 206) continue;
          _logger.log('[Akamai] Edge found: $edgeIp ($domain)');
          return {'testUrl': url, 'edgeIp': edgeIp, 'host': domain};
        } catch (e) {
          _logger.log('[Akamai] Probe failed $domain: $e');
        }
      }
      return null;
    } finally {
      try {
        c.close(force: true);
      } catch (_) {}
    }
  }

  @override
  Future<Map<String, double>> measureLatency(TestLifecycle lifecycle) async {
    return {'ping': 0.0, 'jitter': 0.0};
  }

  @override
  Future<void> runDownload(
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    final url = metadata['testUrl'] as String;
    final deadline = DateTime.now().add(
      Duration(seconds: phaseDurationSeconds),
    );
    final c = HttpClient()..autoUncompress = false;
    c.badCertificateCallback = (cert, host, port) => true;
    c.connectionTimeout = const Duration(seconds: 10);
    c.idleTimeout = const Duration(seconds: 15);
    c.maxConnectionsPerHost = _Cfg.maxW;
    lifecycle.registerClient(c);
    int off = 0;
    final workers = <Future<void>>[];
    for (int i = 0; i < _Cfg.minW; i++) {
      workers.add(
        Future.delayed(
          Duration(milliseconds: i * 150),
          () => _dlW(c, url, lifecycle, onBytes, deadline, () {
            final o = off;
            off += _Cfg.chunkInit;
            return o;
          }),
        ),
      );
    }
    await Future.wait(workers);
  }

  @override
  Future<void> runUpload(
    TestLifecycle lifecycle,
    void Function(int) onBytes,
    Map<String, dynamic> metadata,
  ) async {
    final deadline = DateTime.now().add(
      Duration(seconds: phaseDurationSeconds),
    );
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    c.badCertificateCallback = (cert, host, port) => true;
    c.idleTimeout = const Duration(seconds: 15);
    c.maxConnectionsPerHost = 4;
    lifecycle.registerClient(c);
    final workers = <Future<void>>[];
    for (int i = 0; i < 4; i++) {
      workers.add(_ulW(c, lifecycle, onBytes, deadline));
    }
    await Future.wait(workers);
  }

  Future<void> _dlW(
    HttpClient c,
    String url,
    TestLifecycle lifecycle,
    void Function(int) onB,
    DateTime deadline,
    int Function() nextOff,
  ) async {
    final uri = Uri.parse(url);
    int cs = _Cfg.chunkInit;
    while (!lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
      try {
        int sb = nextOff() % (50 * 1024 * 1024);
        int eb = sb + cs - 1;
        final req = await c.getUrl(uri);
        req.headers.set('Accept-Encoding', 'identity');
        req.headers.set('Cache-Control', 'no-cache');
        req.headers.set('Connection', 'keep-alive');
        req.headers.set('Range', 'bytes=$sb-$eb');
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
          } else if (sw.elapsedMilliseconds > 5000) {
            cs = math.max(cs ~/ 2, _Cfg.chunkInit);
          }
        } else {
          await res.drain();
          await Future.delayed(const Duration(milliseconds: 500));
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
    DateTime deadline,
  ) async {
    int ti = 0, ps = 256 * 1024;
    Uint8List ch = _mkPayload(ps);
    while (!lifecycle.shouldStop && DateTime.now().isBefore(deadline)) {
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
          ch = _mkPayload(ps);
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

  Uint8List _mkPayload(int s) {
    final d = Uint8List(s);
    final r = math.Random();
    for (int i = 0; i < s; i += 64) {
      d[i] = r.nextInt(256);
    }
    return d;
  }
}
