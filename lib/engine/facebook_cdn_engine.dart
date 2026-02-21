import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

// ═══════════════════════════════════════════════════════════════════
//  CONFIGURATION
// ═══════════════════════════════════════════════════════════════════

class _Config {
  static const int downloadWorkerCount = 4;
  static const int uploadWorkerCount = 3;
  static const int uploadPayloadBytes = 1024 * 1024; // 1 MB
  static const int uploadChunkSize = 16 * 1024; // 16 KB flush chunks

  static const Duration discoveryTimeout = Duration(seconds: 8);
  static const Duration probeTimeout = Duration(seconds: 6);
  static const Duration socketConnectTimeout = Duration(seconds: 8);

  static const String uploadHost = 'graph.facebook.com';
  static const String uploadPath = '/v19.0/me';

  static const String userAgent =
      '[FBAN/FB4A;FBAV/465.0.0.40.23;FBBV/593853032;FBDM/{density=2.625,width=1080,height=2206};FBLC/en_US;FBRV/0;FBCR/Verizon;FBMF/Google;FBBD/Pixel;FBPN/com.facebook.katana;FBDV/Pixel 8;FBSV/14;FBOP/1;FBCA/arm64-v8a:;]';

  static const String botUserAgent = 'facebookexternalhit/1.1';

  static const List<String> graphApiSeeds = [
    'facebook',
    'instagram',
    'whatsapp',
    'meta',
  ];

  static const List<String> ogImagePages = [
    'https://www.facebook.com/facebook',
    'https://www.facebook.com/meta',
    'https://www.facebook.com/instagram',
    'https://www.facebook.com/whatsapp',
  ];

  static const List<_CdnTarget> stableFallbacks = [
    _CdnTarget(
      url:
          'https://scontent.xx.fbcdn.net/v/t39.30808-6/434271874_122137913348123605_8741362638890479717_n.jpg?_nc_cat=1&ccb=1-7&_nc_sid=5f2048&_nc_ohc=Mw8v6c6q6cQAb7r8z8_&_nc_ht=scontent.xx.fbcdn.net&oh=00_AfD_8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t8t&oe=664B3B0C',
      label: 'FB Profile (Fallback)',
      minBytes: 50000,
    ),
  ];
}

class _CdnTarget {
  final String url;
  final String label;
  final int minBytes;
  const _CdnTarget({
    required this.url,
    required this.label,
    required this.minBytes,
  });
}

// ═══════════════════════════════════════════════════════════════════
//  PROBE RESULT
// ═══════════════════════════════════════════════════════════════════

class _ProbeResult {
  final String url;
  final String host;
  final String path;
  final String label;
  final String? cdnEdge;
  final int contentLength;

  const _ProbeResult({
    required this.url,
    required this.host,
    required this.path,
    required this.label,
    this.cdnEdge,
    required this.contentLength,
  });
}

// ═══════════════════════════════════════════════════════════════════
//  PERSISTENT HTTP CONNECTION (Socket-Level I/O)
// ═══════════════════════════════════════════════════════════════════

class FBParsedResponse {
  final int statusCode;
  final int bodyBytes;
  FBParsedResponse(this.statusCode, this.bodyBytes);
}

class PersistentHttpConnection {
  final io.Socket _socket;
  final void Function() _onClose;
  final SmoothSpeedMeter? _meter;

  bool _readingHeaders = true;
  int _contentLength = -1;
  bool _isChunked = false;
  int _bytesReadForCurrentResponse = 0;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<FBParsedResponse>? _responseCompleter;

  PersistentHttpConnection(
    this._socket,
    this._onClose, {
    SmoothSpeedMeter? meter,
  }) : _meter = meter {
    _socket.listen(
      _onData,
      onError: (e) {
        _close();
        return <void>[];
      },
      onDone: () => _close(),
      cancelOnError: true,
    );
  }

  void _close() {
    _completeWith(0, 0);
    _onClose();
  }

  void _completeWith(int status, int bytes) {
    if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
      _responseCompleter!.complete(FBParsedResponse(status, bytes));
    }
  }

  Future<FBParsedResponse> sendRequest(Uint8List data) {
    if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
      throw StateError('Cannot send request while waiting for response');
    }

    _responseCompleter = Completer<FBParsedResponse>();
    _bytesReadForCurrentResponse = 0;

    try {
      _socket.add(data);
    } catch (_) {
      _close();
      return Future.value(FBParsedResponse(0, 0));
    }

    return _responseCompleter!.future;
  }

  Future<FBParsedResponse> sendRequestChunked({
    required Uint8List header,
    required Uint8List body,
    required int chunkSize,
    required SmoothSpeedMeter meter,
  }) async {
    if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
      throw StateError('Cannot send request while waiting for response');
    }

    _responseCompleter = Completer<FBParsedResponse>();
    _bytesReadForCurrentResponse = 0;

    try {
      _socket.add(header);
      int offset = 0;
      while (offset < body.length) {
        final end = math.min(offset + chunkSize, body.length);
        final slice = body.sublist(offset, end);
        _socket.add(slice);
        await _socket.flush();
        meter.addBytes(slice.length);
        offset += slice.length;
      }
    } catch (_) {
      _close();
      return Future.value(FBParsedResponse(0, 0));
    }

    return _responseCompleter!.future;
  }

  void _onData(Uint8List chunk) {
    _meter?.addBytes(chunk.length);
    _buffer.add(chunk);
    _processBuffer();
  }

  void _processBuffer() {
    bool progress = true;
    while (progress && _buffer.isNotEmpty) {
      progress = false;

      if (_readingHeaders) {
        final bytes = _buffer.toBytes();
        final headerEnd = _findHeaderEnd(bytes);

        if (headerEnd != -1) {
          final headerBytes = bytes.sublist(0, headerEnd);
          final headerStr = latin1.decode(headerBytes);

          int statusCode = 0;
          final lines = headerStr.split('\r\n');
          if (lines.isNotEmpty) {
            final parts = lines[0].split(' ');
            if (parts.length >= 2) statusCode = int.tryParse(parts[1]) ?? 0;
          }

          _contentLength = -1;
          _isChunked = false;

          for (final line in lines) {
            final lower = line.toLowerCase();
            if (lower.startsWith('content-length:')) {
              _contentLength = int.tryParse(line.split(':')[1].trim()) ?? -1;
            } else if (lower.contains('transfer-encoding: chunked')) {
              _isChunked = true;
            }
          }

          _readingHeaders = false;
          _bytesReadForCurrentResponse = 0;

          final leftover = bytes.sublist(headerEnd + 4);
          _buffer.clear();
          if (leftover.isNotEmpty) _buffer.add(leftover);

          progress = true;

          if ((_contentLength == 0 && !_isChunked) ||
              statusCode == 204 ||
              statusCode == 304) {
            _finishResponse(statusCode);
            progress = true;
          }
        }
      } else {
        if (_contentLength != -1) {
          final needed = _contentLength - _bytesReadForCurrentResponse;
          final available = _buffer.length;

          if (available >= needed) {
            _bytesReadForCurrentResponse += needed;
            final bytes = _buffer.toBytes();
            final leftover = bytes.sublist(needed);
            _buffer.clear();
            if (leftover.isNotEmpty) _buffer.add(leftover);
            _finishResponse(200);
            progress = true;
          } else {
            _bytesReadForCurrentResponse += available;
            _buffer.clear();
          }
        } else if (_isChunked) {
          final available = _buffer.length;
          _bytesReadForCurrentResponse += available;
          _buffer.clear();
        } else {
          final available = _buffer.length;
          _bytesReadForCurrentResponse += available;
          _buffer.clear();
        }
      }
    }
  }

  int _findHeaderEnd(Uint8List data) {
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _finishResponse(int statusCode) {
    _readingHeaders = true;
    _completeWith(statusCode, _bytesReadForCurrentResponse);
  }
}

// ═══════════════════════════════════════════════════════════════════
//  FACEBOOK CDN ENGINE
// ═══════════════════════════════════════════════════════════════════

/// Meta/Facebook CDN (FNA) speed test engine — v12.
///
/// Discovery: Graph API → og:image scraping → hostname substitution → probe.
/// Download: persistent socket-level GET workers on FNA edge.
/// Upload: chunked POST workers to graph.facebook.com upload endpoint.
class FacebookCdnEngine extends SpeedTestEngine {
  final DebugLogger _logger = DebugLogger();

  late final Uint8List _uploadPayload = _generatePayload();
  late final Uint8List _uploadRequestHeaders = _buildUploadHeaders();

  @override
  String get engineName => 'Facebook CDN';

  @override
  bool get hasDiscovery => true;

  @override
  bool get hasLatencyTest => false;

  @override
  int get phaseDurationSeconds => 15;

  // ═══════════════════════════════════════════════════════════════
  // DISCOVERY
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<Map<String, dynamic>?> discover(TestLifecycle lifecycle) async {
    // Step 1: Find FNA host via Graph API
    String? fnaHost;
    for (final seed in _Config.graphApiSeeds) {
      if (lifecycle.isUserCancelled) break;
      try {
        final urlStr = await _discoverFromGraphApi(seed, lifecycle);
        if (urlStr != null) {
          final uri = Uri.parse(urlStr);
          fnaHost = uri.host;
          _logger.log('[FNA] Discovered FNA host: $fnaHost');
          break;
        }
      } catch (_) {}
    }

    // Step 2: Discover large hot media via og:image scraping
    final allTargets = <_CdnTarget>[];
    for (final pageUrl in _Config.ogImagePages) {
      if (lifecycle.isUserCancelled) break;
      try {
        String? ogUrl = await _scrapeOgImage(pageUrl, lifecycle);
        if (ogUrl != null) {
          _logger.log('[FNA] Scraped og:image: ${_truncUrl(ogUrl)}');
          if (fnaHost != null && ogUrl.contains('.fbcdn.net')) {
            final uri = Uri.parse(ogUrl);
            final subUrl = uri.replace(host: fnaHost).toString();
            allTargets.add(
              _CdnTarget(
                url: subUrl,
                label: 'og:image (FNA sub)',
                minBytes: 50000,
              ),
            );
          } else {
            allTargets.add(
              _CdnTarget(
                url: ogUrl,
                label: 'og:image (Original)',
                minBytes: 50000,
              ),
            );
          }
        }
      } catch (e) {
        _logger.log('[FNA] Scraping failed for $pageUrl: $e');
      }
    }

    // Step 3: Probe targets
    final fallbackTargets = [...allTargets, ..._Config.stableFallbacks];
    final probe = await _probeTargets(fallbackTargets, lifecycle);
    if (probe == null) return null;

    _logger.log(
      '[FNA] ✓ Best: ${probe.label} (${(probe.contentLength / 1024).toStringAsFixed(1)} KB)',
    );

    return {
      'host': probe.host,
      'path': probe.path,
      'cdnEdge': probe.cdnEdge,
      'label': probe.label,
    };
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
    final host = metadata['host'] as String;
    final path = metadata['path'] as String;
    final getRequest = _buildGetRequest(host, path);

    final workers = <Future<void>>[];
    for (int w = 0; w < _Config.downloadWorkerCount; w++) {
      workers.add(
        Future.delayed(
          Duration(milliseconds: w * 50),
          () => _dlSocketWorker(w, host, getRequest, lifecycle, onBytes),
        ),
      );
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
    final workers = <Future<void>>[];
    for (int w = 0; w < _Config.uploadWorkerCount; w++) {
      workers.add(
        Future.delayed(
          Duration(milliseconds: w * 50),
          () => _ulSocketWorker(w, lifecycle, onBytes),
        ),
      );
    }
    await Future.wait(workers);
  }

  // ═══════════════════════════════════════════════════════════════
  // DOWNLOAD WORKER (Persistent Socket)
  // ═══════════════════════════════════════════════════════════════

  Future<void> _dlSocketWorker(
    int id,
    String host,
    Uint8List requestBytes,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
  ) async {
    // We need a dedicated SmoothSpeedMeter for PersistentHttpConnection's
    // internal byte counting (its _onData calls meter.addBytes).
    // But the Orchestrator owns the real meter. So we create a proxy meter
    // that forwards addBytes to onBytes.
    final proxyMeter = _ProxyMeter(onBytes);

    while (!lifecycle.shouldStop) {
      io.SecureSocket? socket;
      try {
        socket = await _openSocket(host, lifecycle);
        if (socket == null) return;

        final connection = PersistentHttpConnection(
          socket,
          () {},
          meter: proxyMeter,
        );
        _logger.log('[FNA] DL W$id: Connected');

        while (!lifecycle.shouldStop) {
          final resp = await connection.sendRequest(requestBytes);
          if (resp.statusCode == 0) break;
          if (resp.statusCode != 200) {
            _logger.log('[FNA] DL W$id error HTTP ${resp.statusCode}');
            break;
          }
        }
      } catch (e) {
        _logger.log('[FNA] DL W$id error: $e');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // UPLOAD WORKER (Persistent Socket + Chunked Flush)
  // ═══════════════════════════════════════════════════════════════

  Future<void> _ulSocketWorker(
    int id,
    TestLifecycle lifecycle,
    void Function(int) onBytes,
  ) async {
    final proxyMeter = _ProxyMeter(onBytes);

    while (!lifecycle.shouldStop) {
      io.SecureSocket? socket;
      try {
        socket = await _openSocket(_Config.uploadHost, lifecycle);
        if (socket == null) return;

        final connection = PersistentHttpConnection(socket, () {});
        _logger.log('[FNA] UL W$id: Connected');

        while (!lifecycle.shouldStop) {
          final resp = await connection.sendRequestChunked(
            header: _uploadRequestHeaders,
            body: _uploadPayload,
            chunkSize: _Config.uploadChunkSize,
            meter: proxyMeter,
          );
          if (resp.statusCode == 0) break;
        }
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // DISCOVERY HELPERS
  // ═══════════════════════════════════════════════════════════════

  Future<String?> _discoverFromGraphApi(
    String id,
    TestLifecycle lifecycle,
  ) async {
    final uri = Uri.parse(
      'https://graph.facebook.com/v19.0/$id/picture?type=large&redirect=false',
    );
    final client = io.HttpClient();
    lifecycle.registerClient(client);

    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        final data = jsonDecode(responseBody);
        final url = data['data']?['url'];
        if (url != null && url is String && url.contains('fbcdn.net')) {
          return url;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _scrapeOgImage(
    String pageUrl,
    TestLifecycle lifecycle,
  ) async {
    final client = io.HttpClient();
    lifecycle.registerClient(client);

    try {
      final request = await client.getUrl(Uri.parse(pageUrl));
      request.headers.set('User-Agent', _Config.botUserAgent);

      final response = await request.close().timeout(_Config.discoveryTimeout);
      if (response.statusCode != 200) {
        try {
          await response.drain<void>();
        } catch (_) {}
        return null;
      }

      final chunks = <List<int>>[];
      int totalRead = 0;
      final done = Completer<void>();
      final sub = response.listen(
        (chunk) {
          chunks.add(chunk);
          totalRead += chunk.length;
          if (totalRead >= 200000) {
            if (!done.isCompleted) done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );

      await done.future.timeout(const Duration(seconds: 4), onTimeout: () {});
      await sub.cancel();
      if (totalRead == 0) return null;

      final allBytes = chunks.expand((c) => c).toList();
      final html = utf8.decode(allBytes, allowMalformed: true);

      final match = RegExp(
        r'<meta property="og:image"\s+content="([^"]+)"',
      ).firstMatch(html);
      if (match != null) {
        return match.group(1)?.replaceAll('&amp;', '&');
      }
    } catch (_) {}
    return null;
  }

  Future<_ProbeResult?> _probeTargets(
    List<_CdnTarget> candidates,
    TestLifecycle lifecycle,
  ) async {
    final validProbes = <_ProbeResult>[];
    for (final target in candidates) {
      if (lifecycle.isUserCancelled) break;

      final innerHttp = io.HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      innerHttp.userAgent = _Config.userAgent;
      lifecycle.registerClient(innerHttp);

      try {
        final request = await innerHttp.getUrl(Uri.parse(target.url));
        request.headers.set('Accept', 'image/webp,image/*,*/*');
        final response = await request.close().timeout(_Config.probeTimeout);

        if (response.statusCode != 200) {
          _logger.log(
            '[FNA] Probe failed for ${target.label}, HTTP ${response.statusCode}',
          );
          try {
            await response.drain();
          } catch (_) {}
          continue;
        }

        int bytesRead = 0;
        await response.forEach((chunk) => bytesRead += chunk.length);

        final cdnEdge =
            response.headers.value('x-served-by') ??
            response.headers.value('x-fb-edge-debug');

        if (bytesRead > 10000) {
          validProbes.add(
            _ProbeResult(
              url: target.url,
              host: request.uri.host,
              path: request.uri.hasQuery
                  ? '${request.uri.path}?${request.uri.query}'
                  : request.uri.path,
              label: target.label,
              cdnEdge: cdnEdge,
              contentLength: bytesRead,
            ),
          );
          if (bytesRead > target.minBytes) break;
        }
      } catch (e) {
        _logger.log('[FNA] ✕ $e');
      }
    }
    if (validProbes.isEmpty) return null;

    validProbes.sort((a, b) {
      final aFna = a.host.contains('fna') ? 1 : 0;
      final bFna = b.host.contains('fna') ? 1 : 0;
      if (aFna != bFna) return bFna.compareTo(aFna);
      return b.contentLength.compareTo(a.contentLength);
    });

    return validProbes.first;
  }

  // ═══════════════════════════════════════════════════════════════
  // SOCKET & REQUEST HELPERS
  // ═══════════════════════════════════════════════════════════════

  Future<io.SecureSocket?> _openSocket(
    String host,
    TestLifecycle lifecycle,
  ) async {
    try {
      final socket = await io.SecureSocket.connect(
        host,
        443,
        timeout: _Config.socketConnectTimeout,
        supportedProtocols: ['http/1.1'],
      );
      lifecycle.registerSocket(socket);
      return socket;
    } catch (e) {
      _logger.log('[FNA] Connect failed: $e');
      return null;
    }
  }

  Uint8List _buildGetRequest(String host, String path) {
    final req =
        'GET $path HTTP/1.1\r\n'
        'Host: $host\r\n'
        'User-Agent: ${_Config.userAgent}\r\n'
        'Accept: image/webp,image/*,*/*\r\n'
        'Accept-Encoding: identity\r\n'
        'Connection: keep-alive\r\n'
        '\r\n';
    return latin1.encode(req);
  }

  Uint8List _generatePayload() {
    final rng = math.Random(42);
    final data = Uint8List(_Config.uploadPayloadBytes);
    for (int i = 0; i < data.length; i++) {
      data[i] = rng.nextInt(256);
    }
    return data;
  }

  Uint8List _buildUploadHeaders() {
    final header =
        'POST ${_Config.uploadPath} HTTP/1.1\r\n'
        'Host: ${_Config.uploadHost}\r\n'
        'User-Agent: ${_Config.userAgent}\r\n'
        'Content-Type: application/octet-stream\r\n'
        'Content-Length: ${_Config.uploadPayloadBytes}\r\n'
        'Connection: keep-alive\r\n'
        '\r\n';
    return latin1.encode(header);
  }

  String _truncUrl(String url) =>
      url.length > 80 ? '${url.substring(0, 77)}...' : url;
}

/// Proxy SmoothSpeedMeter that forwards addBytes calls to the
/// Orchestrator's onBytes callback. PersistentHttpConnection expects
/// a SmoothSpeedMeter; this adapter bridges it to the engine interface.
class _ProxyMeter extends SmoothSpeedMeter {
  final void Function(int) _onBytes;
  _ProxyMeter(this._onBytes) : super(totalDurationSeconds: 15);

  @override
  void addBytes(int bytes) {
    _onBytes(bytes);
  }
}
