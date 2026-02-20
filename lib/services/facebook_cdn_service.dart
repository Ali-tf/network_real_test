// lib/services/facebook_cdn_service.dart
//
// Meta/Facebook CDN (FNA) Speed Test Service — v12
//
// FIX: "1.4 KB Error Pages / 3.6 Mbps Cap"
// V11 missed auth tokens in the query string, causing the CDN to reject requests.
//
// V12 Changes:
// 1. Path Storage: Stores full `path + ? + query` so auth tokens (`oh`, `oe`) are valid.
// 2. Parser Fix: Removed `statusCode == 206` from body-less check (though Range is removed).
// 3. Removed Range Header: Unnecessary for single downloads, causes parser issues.
// 4. `og:image` Scraping: Uses bot UA to scrape public FB pages for large cover photos (300KB-1.5MB).
// 5. Hostname Substitution: Replaces the `og:image` generic host with the local FNA host discovered via Graph API.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/utils/smooth_speed_meter.dart';
import 'package:network_speed_test/utils/test_lifecycle.dart';

// ═══════════════════════════════════════════════════════════════════
//  CONFIGURATION
// ═══════════════════════════════════════════════════════════════════

class _Config {
  static const int downloadDurationSeconds = 15;
  static const int uploadDurationSeconds = 15;
  static const int uiUpdateIntervalMs = 200;

  static const int downloadWorkerCount = 4;
  static const int uploadWorkerCount = 3;

  static const int uploadPayloadBytes = 1024 * 1024; // 1 MB
  static const int uploadChunkSize = 16 * 1024; // 16 KB flush chunks

  static const Duration discoveryTimeout = Duration(seconds: 8);
  static const Duration probeTimeout = Duration(seconds: 6);
  static const Duration socketConnectTimeout = Duration(seconds: 8);

  static const String uploadHost = 'graph.facebook.com';
  static const String uploadPath = '/v19.0/me';

  // v12: Native App User-Agent to trigger correct traffic shaping
  static const String userAgent =
      '[FBAN/FB4A;FBAV/465.0.0.40.23;FBBV/593853032;FBDM/{density=2.625,width=1080,height=2206};FBLC/en_US;FBRV/0;FBCR/Verizon;FBMF/Google;FBBD/Pixel;FBPN/com.facebook.katana;FBDV/Pixel 8;FBSV/14;FBOP/1;FBCA/arm64-v8a:;]';

  // v12: Bot UA for scraping og:image tags
  static const String botUserAgent = 'facebookexternalhit/1.1';

  // v12: Graph API seeds to find local FNA hostname
  static const List<String> graphApiSeeds = [
    'facebook',
    'instagram',
    'whatsapp',
    'meta',
  ];

  // v12: Public FB pages to scrape for large og:image cover photos
  static const List<String> ogImagePages = [
    'https://www.facebook.com/facebook',
    'https://www.facebook.com/meta',
    'https://www.facebook.com/instagram',
    'https://www.facebook.com/whatsapp',
  ];

  // v12: Fallbacks must be on *.fbcdn.net if possible
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

class FacebookCdnResult {
  final double downloadMbps;
  final double uploadMbps;
  final bool isDone;
  final String? error;
  final String status;
  final String? cdnEdge;
  final String? assetUsed;

  const FacebookCdnResult({
    required this.downloadMbps,
    this.uploadMbps = 0.0,
    this.isDone = false,
    this.error,
    this.status = '',
    this.cdnEdge,
    this.assetUsed,
  });
}

// Deprecated counter classes removed

// ═══════════════════════════════════════════════════════════════════
//  PERSISTENT HTTP CONNECTION (Stateful Parser + Chunked Flush)
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

class FBParsedResponse {
  final int statusCode;
  final int bodyBytes;
  FBParsedResponse(this.statusCode, this.bodyBytes);
}

class PersistentHttpConnection {
  final io.Socket _socket;
  final void Function() _onClose;
  final SmoothSpeedMeter? _meter;

  // State Machine
  bool _readingHeaders = true;
  int _contentLength = -1;
  bool _isChunked = false;
  int _bytesReadForCurrentResponse = 0;

  // Buffers
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<FBParsedResponse>? _responseCompleter;

  // Metrics
  // (Removed _totalBytesParsed since it was unused)

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
      onDone: () {
        _close();
      },
      cancelOnError: true,
    );
  }

  void _close() {
    _completeWith(0, 0); // Close pending request
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
          // Parse Headers
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

          // v12 FIX: Removed `statusCode == 206` from here. 206 HAS a body.
          if ((_contentLength == 0 && !_isChunked) ||
              statusCode == 204 ||
              statusCode == 304) {
            _finishResponse(statusCode);
            progress = true;
          }
        }
      } else {
        // READING BODY
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
          // Simplified chunk handling (count all)
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
//  FACEBOOK CDN SERVICE
// ═══════════════════════════════════════════════════════════════════

class FacebookCdnService {
  final TestLifecycle _lifecycle = TestLifecycle();
  final DebugLogger _logger = DebugLogger();

  late final Uint8List _uploadPayload = _generatePayload();
  late final Uint8List _uploadRequestHeaders = _buildUploadHeaders();

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

  Stream<FacebookCdnResult> measureSpeed() {
    _lifecycle.reset();
    final controller = StreamController<FacebookCdnResult>();
    _runTest(controller);
    return controller.stream;
  }

  void cancel() {
    _lifecycle.cancel();
    _logger.log('[FNA] ✕ Cancel requested');
  }

  void _emit(StreamController<FacebookCdnResult> c, FacebookCdnResult r) {
    if (!c.isClosed) c.add(r);
  }

  void _close(StreamController<FacebookCdnResult> c) {
    if (!c.isClosed) c.close();
  }

  bool _isExpired(DateTime deadline) {
    return _lifecycle.shouldStop || DateTime.now().isAfter(deadline);
  }

  String _truncateUrl(String url) {
    return url.length > 80 ? '${url.substring(0, 77)}...' : url;
  }

  Future<void> _runTest(StreamController<FacebookCdnResult> ctrl) async {
    try {
      _logger.log('[FNA] ═══════════════════════════════════════');
      _logger.log('[FNA]  Facebook CDN Speed Test v12 (DL Fix)');
      _logger.log('[FNA] ═══════════════════════════════════════');

      // ── PHASE 0: Discovery ──
      _emit(
        ctrl,
        const FacebookCdnResult(
          downloadMbps: 0,
          uploadMbps: -1.0,
          status: 'Discovering Meta FNA edge nodes...',
        ),
      );

      final candidates = await _discoverCdnUrls();
      if (_lifecycle.isUserCancelled) return _close(ctrl);

      // ── PHASE 1: Probe ──
      _emit(
        ctrl,
        const FacebookCdnResult(
          downloadMbps: 0,
          uploadMbps: -1.0,
          status: 'Probing for hot edge content...',
        ),
      );

      final fallbackTargets = [...candidates, ..._Config.stableFallbacks];
      final probe = await _probeTargets(fallbackTargets);

      if (probe == null) {
        _emit(
          ctrl,
          const FacebookCdnResult(
            downloadMbps: 0,
            uploadMbps: -1.0,
            isDone: true,
            error:
                'All Meta CDN endpoints unreachable or returned small files.',
            status: 'Failed',
          ),
        );
        return _close(ctrl);
      }

      if (_lifecycle.isUserCancelled) return _close(ctrl);

      _logger.log(
        '[FNA] ✓ Best: ${probe.label} '
        '(${(probe.contentLength / 1024).toStringAsFixed(1)} KB)',
      );
      _logger.log('[FNA]   Host: ${probe.host}');
      _logger.log('[FNA]   Path: ${probe.path}');
      _logger.log('[FNA]   Edge: ${probe.cdnEdge ?? "unknown"}');

      _emit(
        ctrl,
        FacebookCdnResult(
          downloadMbps: 0,
          uploadMbps: -1.0,
          status: 'Connected to ${probe.cdnEdge ?? probe.host}',
          cdnEdge: probe.cdnEdge,
          assetUsed: probe.label,
        ),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      if (_lifecycle.isUserCancelled) return _close(ctrl);

      // ── PHASE 2: Download ──
      _logger.log(
        '[FNA] ── Download Phase '
        '(${_Config.downloadDurationSeconds}s, '
        '${_Config.downloadWorkerCount} workers) ──',
      );

      final dlMbps = await _runDownloadPhase(ctrl, probe);
      _logger.log('[FNA] Download: ${dlMbps.toStringAsFixed(2)} Mbps');

      if (_lifecycle.isUserCancelled) return _close(ctrl);

      // ── PHASE 3: Upload ──
      _logger.log(
        '[FNA] ── Upload Phase '
        '(${_Config.uploadDurationSeconds}s, '
        '${_Config.uploadWorkerCount} workers) ──',
      );

      _emit(
        ctrl,
        FacebookCdnResult(
          downloadMbps: dlMbps,
          uploadMbps: 0.0,
          status: 'Testing upload to Meta edge...',
          cdnEdge: probe.cdnEdge,
          assetUsed: probe.label,
        ),
      );

      final ulMbps = await _runUploadPhase(ctrl, dlMbps, probe);
      _logger.log('[FNA] Upload: ${ulMbps.toStringAsFixed(2)} Mbps');

      _emit(
        ctrl,
        FacebookCdnResult(
          downloadMbps: dlMbps,
          uploadMbps: ulMbps,
          isDone: true,
          status: 'Complete',
          cdnEdge: probe.cdnEdge,
          assetUsed: probe.label,
        ),
      );

      _logger.log('[FNA] ═══ Test Complete ═══');
      _logger.log('[FNA] ═══ Test Complete ═══');
    } catch (e, st) {
      _logger.log('[FNA] FATAL: $e\n$st');
      _emit(
        ctrl,
        FacebookCdnResult(
          downloadMbps: 0,
          isDone: true,
          error: e.toString(),
          status: 'Error',
        ),
      );
    } finally {
      _close(ctrl);
    }
  }

  Future<List<_CdnTarget>> _discoverCdnUrls() async {
    String? fnaHost;

    // Step 1: Discover FNA Hostname via Graph API (small profile pics)
    for (final seed in _Config.graphApiSeeds) {
      if (_lifecycle.isUserCancelled) break;
      try {
        final urlStr = await _discoverFromGraphApi(seed);
        if (urlStr != null) {
          final uri = Uri.parse(urlStr);
          fnaHost = uri.host; // e.g., scontent.fbey2-2.fna.fbcdn.net
          _logger.log('[FNA] Discovered FNA host: $fnaHost');
          break; // Found one, stop
        }
      } catch (_) {}
    }

    final allTargets = <_CdnTarget>[];

    // Step 2: Discover Large Hot Media via og:image scraping
    for (final pageUrl in _Config.ogImagePages) {
      if (_lifecycle.isUserCancelled) break;
      try {
        String? ogUrl = await _scrapeOgImage(pageUrl);
        if (ogUrl != null) {
          _logger.log('[FNA] Scraped og:image: ${_truncateUrl(ogUrl)}');

          // Step 3: Hostname Substitution (Force local FNA routing)
          if (fnaHost != null && ogUrl.contains('.fbcdn.net')) {
            final uri = Uri.parse(ogUrl);
            final subUrl = uri.replace(host: fnaHost).toString();
            _logger.log('[FNA] Substituted host: ${_truncateUrl(subUrl)}');
            allTargets.add(
              _CdnTarget(
                url: subUrl,
                label: 'og:image (FNA sub)',
                minBytes: 50000,
              ),
            );
          } else {
            // Add original if substitution fails
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

    return allTargets;
  }

  /// Hits Graph API for a profile picture; redirects to a CDN URL.
  Future<String?> _discoverFromGraphApi(String id) async {
    final uri = Uri.parse(
      'https://graph.facebook.com/v19.0/$id/picture?type=large&redirect=false',
    );
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

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

  /// Scrapes public FB pages for `og:image` meta tags using bot UA
  Future<String?> _scrapeOgImage(String pageUrl) async {
    final client = io.HttpClient();
    _lifecycle.registerClient(client);

    try {
      final request = await client.getUrl(Uri.parse(pageUrl));
      // v12 FIX: Bot UA is required to get og tags from FB
      request.headers.set('User-Agent', _Config.botUserAgent);

      final response = await request.close().timeout(_Config.discoveryTimeout);
      if (response.statusCode != 200) {
        try {
          await response.drain<void>();
        } catch (_) {}
        return null;
      }

      // We only need the first ~100KB to find the meta tags
      final chunks = <List<int>>[];
      int totalRead = 0;
      final done = Completer<void>();
      final sub = response.listen(
        (chunk) {
          chunks.add(chunk);
          totalRead += chunk.length;
          if (totalRead >= 200000) {
            // Safety limit
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

      // Extract og:image
      final match = RegExp(
        r'<meta property="og:image"\s+content="([^"]+)"',
      ).firstMatch(html);
      if (match != null) {
        return match.group(1)?.replaceAll('&amp;', '&');
      }
    } catch (_) {}
    return null;
  }

  Future<_ProbeResult?> _probeTargets(List<_CdnTarget> candidates) async {
    final validProbes = <_ProbeResult>[];
    for (final target in candidates) {
      if (_lifecycle.isUserCancelled) break;

      final innerHttp = io.HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      // Native User Agent required for CDN to trust us
      innerHttp.userAgent = _Config.userAgent;
      _lifecycle.registerClient(innerHttp);

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

        // v12 FIX: Check size to ensure we didn't get a 1.4KB error page
        if (bytesRead > 10000) {
          // At least 10KB
          validProbes.add(
            _ProbeResult(
              url: target.url,
              host: request.uri.host,
              // v12 FIX: Include query string so `oh` and `oe` auth tokens are preserved!
              path: request.uri.hasQuery
                  ? '${request.uri.path}?${request.uri.query}'
                  : request.uri.path,
              label: target.label,
              cdnEdge: cdnEdge,
              contentLength: bytesRead,
            ),
          );
          _logger.log(
            '[FNA] ✓ ${bytesRead}B, edge=$cdnEdge host=${request.uri.host}',
          );
          // If we found a large one, we can stop early
          if (bytesRead > target.minBytes) break;
        } else {
          _logger.log('[FNA] ✕ Too small: ${bytesRead}B for ${target.label}');
        }
      } catch (e) {
        _logger.log('[FNA] ✕ $e');
      }
    }
    if (validProbes.isEmpty) return null;

    // Sort by presence of "fna" in host (local ISP node), then size
    validProbes.sort((a, b) {
      final aFna = a.host.contains('fna') ? 1 : 0;
      final bFna = b.host.contains('fna') ? 1 : 0;
      if (aFna != bFna) return bFna.compareTo(aFna);
      return b.contentLength.compareTo(a.contentLength);
    });

    return validProbes.first;
  }

  Future<io.SecureSocket?> _openSocket(String host) async {
    try {
      final socket = await io.SecureSocket.connect(
        host,
        443,
        timeout: _Config.socketConnectTimeout,
        supportedProtocols: ['http/1.1'],
      );
      _lifecycle.registerSocket(socket);
      return socket;
    } catch (e) {
      _logger.log('[FNA] Connect failed: $e');
      return null;
    }
  }

  Uint8List _buildGetRequest(String host, String path) {
    // v12 FIX: Removed `Range: bytes=0-`
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

  // ── PHASE 2: DOWNLOAD (Persistent) ──

  Future<double> _runDownloadPhase(
    StreamController<FacebookCdnResult> ctrl,
    _ProbeResult probe,
  ) async {
    final meter = SmoothSpeedMeter(
      totalDurationSeconds: _Config.downloadDurationSeconds,
    );
    meter.start();
    final startTime = DateTime.now();
    final deadline = startTime.add(
      Duration(seconds: _Config.downloadDurationSeconds),
    );
    final phaseCompleter = Completer<double>();
    _lifecycle.beginPhase();

    final monitor = Timer.periodic(
      const Duration(milliseconds: _Config.uiUpdateIntervalMs),
      (t) {
        if (_isExpired(deadline) || ctrl.isClosed) {
          _lifecycle.timeoutPhase();
          return;
        }
        _emit(
          ctrl,
          FacebookCdnResult(
            downloadMbps: math.max(0.0, meter.tick()),
            uploadMbps: 0.0,
            status:
                'Downloading from ${probe.host}... (${_Config.downloadWorkerCount} workers)',
            cdnEdge: probe.cdnEdge,
            assetUsed: probe.label,
          ),
        );
      },
    );
    _lifecycle.registerTimer(monitor);

    final getRequest = _buildGetRequest(probe.host, probe.path);
    final workerReqCounts = List<int>.filled(_Config.downloadWorkerCount, 0);

    for (int w = 0; w < _Config.downloadWorkerCount; w++) {
      _lifecycle.launchWorker(
        () => Future.delayed(
          Duration(milliseconds: w * 50),
          () => _dlSocketWorker(
            w,
            probe.host,
            getRequest,
            meter,
            deadline,
            workerReqCounts,
          ),
        ),
      );
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    if (!phaseCompleter.isCompleted) phaseCompleter.complete(meter.finish());
    final result = await phaseCompleter.future;

    final totalReqs = workerReqCounts.reduce((a, b) => a + b);
    _logger.log(
      '[FNA] DL: $totalReqs reqs, finished at ${result.toStringAsFixed(2)} Mbps',
    );
    return result;
  }

  Future<void> _dlSocketWorker(
    int id,
    String host,
    Uint8List requestBytes,
    SmoothSpeedMeter meter,
    DateTime deadline,
    List<int> reqCounts,
  ) async {
    while (!_isExpired(deadline)) {
      io.SecureSocket? socket;
      PersistentHttpConnection? connection;

      try {
        socket = await _openSocket(host);
        if (socket == null) return;

        connection = PersistentHttpConnection(socket, () {}, meter: meter);
        _logger.log('[FNA] DL W$id: Connected');

        while (!_isExpired(deadline)) {
          final resp = await connection.sendRequest(requestBytes);
          if (resp.statusCode == 0) break;

          reqCounts[id]++;

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

  // ── PHASE 3: UPLOAD (Persistent + Chunked Flush) ──

  Future<double> _runUploadPhase(
    StreamController<FacebookCdnResult> ctrl,
    double dlMbps,
    _ProbeResult probe,
  ) async {
    final meter = SmoothSpeedMeter(
      totalDurationSeconds: _Config.uploadDurationSeconds,
    );
    meter.start();
    final startTime = DateTime.now();
    final deadline = startTime.add(
      Duration(seconds: _Config.uploadDurationSeconds),
    );
    final phaseCompleter = Completer<double>();
    _lifecycle.beginPhase();

    final monitor = Timer.periodic(
      const Duration(milliseconds: _Config.uiUpdateIntervalMs),
      (t) {
        if (_isExpired(deadline) || ctrl.isClosed) {
          _lifecycle.timeoutPhase();
          return;
        }

        _emit(
          ctrl,
          FacebookCdnResult(
            downloadMbps: dlMbps,
            uploadMbps: meter.tick(),
            status: 'Uploading... (${_Config.uploadWorkerCount} workers)',
            cdnEdge: probe.cdnEdge,
            assetUsed: probe.label,
          ),
        );
      },
    );
    _lifecycle.registerTimer(monitor);

    final workerReqCounts = List<int>.filled(_Config.uploadWorkerCount, 0);

    for (int w = 0; w < _Config.uploadWorkerCount; w++) {
      _lifecycle.launchWorker(
        () => Future.delayed(
          Duration(milliseconds: w * 50),
          () => _ulSocketWorker(w, meter, deadline, workerReqCounts),
        ),
      );
    }

    await _lifecycle.awaitPhaseComplete();
    await _lifecycle.awaitAllWorkers();

    if (!phaseCompleter.isCompleted) phaseCompleter.complete(meter.finish());
    final result = await phaseCompleter.future;

    final totalReqs = workerReqCounts.reduce((a, b) => a + b);
    _logger.log(
      '[FNA] UL: $totalReqs reqs, finished at ${result.toStringAsFixed(2)} Mbps',
    );
    return result;
  }

  Future<void> _ulSocketWorker(
    int id,
    SmoothSpeedMeter meter,
    DateTime deadline,
    List<int> reqCounts,
  ) async {
    while (!_isExpired(deadline)) {
      io.SecureSocket? socket;

      try {
        socket = await _openSocket(_Config.uploadHost);
        if (socket == null) return;

        final connection = PersistentHttpConnection(socket, () {});
        _logger.log('[FNA] UL W$id: Connected');

        while (!_isExpired(deadline)) {
          reqCounts[id]++;

          final resp = await connection.sendRequestChunked(
            header: _uploadRequestHeaders,
            body: _uploadPayload,
            chunkSize: _Config.uploadChunkSize,
            meter: meter,
          );

          if (resp.statusCode == 0) break;
        }
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }
}
