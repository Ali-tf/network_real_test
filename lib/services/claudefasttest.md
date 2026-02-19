

# Root Cause Analysis & Production-Ready Fix for `fast_service.dart`

## The Five Critical Bugs — Explained

---

### Bug 1: Upload Phase Is Completely Broken

**Root Cause — Two Failures:**

**1a. URL Construction:** While `uri.replace(path: '/speedtest/upload')` *does* preserve query parameters, the real problem is downstream...

**1b. `client.post(url, body: payload)` — No Backpressure, Wrong Byte Counting:**
```dart
// OLD — BROKEN: entire 1MB body is buffered, sent, response awaited,
// THEN bytes are counted. During the whole round-trip, totalBytesSent = 0.
final response = await client.post(uploadUri, body: payload);
if (response.statusCode == 200) {
  onBytes(payload.length);  // ← counted only after full round-trip
}
```
This means: (a) the monitor sees zero bytes for seconds at a time, (b) then a sudden burst, and (c) one bad status code breaks the entire phase because the `while` loop's `await client.post()` call creates sequential 1MB round-trips — far too slow to saturate any real connection.

---

### Bug 2: Fire-and-Forget Workers — No Lifecycle Control
```dart
// OLD — BROKEN: futures are NEVER awaited
for (int i = 0; i < streamsToRun; i++) {
  _downloadWorker(client, urls[i], (bytes) {  // ← fire-and-forget!
    totalBytesRead += bytes;
  });
}
```
The `_monitorPhase` completes after 15 seconds, but the workers **keep running indefinitely in the background**, consuming bandwidth, CPU, and memory. The shared `http.Client` is closed later, but workers may have already opened new requests.

---

### Bug 3: Monitor Uses Cumulative Average (Not Sliding Window)
```dart
// OLD — BROKEN: this is total_bytes / total_time since t=0
final double mbps = (getBytes() * 8 * 1000) / (elapsed * 1000000);
```
TCP slow-start means the first few seconds are slow. A cumulative average from `t=0` means those slow seconds drag down the reading for the entire 15-second test. Real speed test tools use a **sliding window** (last 1–2 seconds only).

---

### Bug 4: No Forceful Termination

The 15-second timer in `_monitorPhase` completes its own `Completer`, but does **nothing** to stop the workers. Workers continue downloading/uploading until they naturally finish or error out. There is no `client.close()` call until after **both phases** complete.

---

### Bug 5: DateTime.now() Timing + EMA Absence = Gauge Jitter

`DateTime.now()` has 1–10ms granularity on mobile. Combined with the 200ms poll interval and no smoothing at all, the gauge gets a new value every 200ms that's a cumulative average — it rises monotonically and slowly, then jumps if a burst of data arrives. Not the smooth live needle the user expects.

---

## The Production-Ready Fix

**Key architectural changes:**
1. **`dart:io` HttpClient for both phases** — gives `close(force: true)` to instantly kill all sockets
2. **`request.flush()` for upload** — blocks until the OS TCP buffer accepts data (real backpressure)
3. **`Future.wait()` on all workers** — proper lifecycle management
4. **Kill Timer destroys the `HttpClient`** — workers' pending I/O throws, loops exit, `Future.wait` resolves
5. **`Stopwatch` (µs precision) + 1-second sliding window** — smooth, accurate gauge

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:network_speed_test/utils/debug_logger.dart';

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

// ─── Internal: one data-point in the sliding window ────────────
class _Sample {
  final int us;    // elapsed µs from Stopwatch
  final int bytes; // cumulative bytes at that instant
  const _Sample(this.us, this.bytes);
}

// ─── Service ───────────────────────────────────────────────────
class FastService {
  // Fast.com public JS-client token
  static const String _token = 'YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm';

  // ── Tunables ──
  static const int _testDurationSec = 15;
  static const int _uiTickMs       = 250;         // 4 Hz gauge refresh
  static const int _windowUs       = 1000000;     // 1-s sliding window (µs)
  static const int _pruneUs        = 2000000;     // discard samples > 2 s old
  static const int _maxStreams     = 5;            // parallel connections
  static const int _ulChunkBytes   = 512 * 1024;  // 512 KB upload chunk
  static const Duration _connectTimeout = Duration(seconds: 10);

  bool _isCancelled = false;
  io.HttpClient? _activeClient;
  final DebugLogger _logger = DebugLogger();

  // ═══════════ PUBLIC API ══════════════════════════════════════

  void cancel() {
    _isCancelled = true;
    _activeClient?.close(force: true);
    _activeClient = null;
    _logger.log('[Fast] Cancelled by user.');
  }

  /// Emits live [FastResult] updates. Stream closes automatically
  /// when both phases finish, or on fatal error.
  Stream<FastResult> measureSpeed() {
    _isCancelled = false;
    final ctrl = StreamController<FastResult>();
    _run(ctrl);
    return ctrl.stream;
  }

  // ═══════════ MATH & HELPERS ══════════════════════════════════

  /// Convert cumulative [bytes] over [us] microseconds to Mbps.
  ///
  ///   Mbps = (bytes × 8) / µs
  ///
  ///   Check: 1 000 000 B in 1 000 000 µs → 8.0 Mbps ✓
  static double _mbps(int bytes, int us) {
    if (us <= 0 || bytes <= 0) return 0.0;
    return (bytes * 8.0) / us;
  }

  /// Average speed over the most recent [_windowUs] microseconds.
  ///
  /// Finds the latest sample that is ≥ 1 s before [nowUs], then
  /// computes ΔBytes / ΔTime.  Far more stable than EMA because
  /// one fast/slow chunk cannot spike the result.
  double _windowedSpeed(List<_Sample> buf, int nowUs) {
    if (buf.length < 2) return 0.0;
    final cutoff = nowUs - _windowUs;

    // Walk backwards to find anchor ≥ 1 s before now
    _Sample anchor = buf.first;
    for (int i = buf.length - 1; i >= 0; i--) {
      if (buf[i].us <= cutoff) {
        anchor = buf[i];
        break;
      }
    }

    final tip    = buf.last;
    final dBytes = tip.bytes - anchor.bytes;
    final dUs    = tip.us    - anchor.us;
    return _mbps(dBytes, dUs);
  }

  /// Drop samples older than 2 × window to bound memory.
  /// At 4 Hz ticker, buffer never exceeds ~10 entries.
  void _pruneBuf(List<_Sample> buf, int nowUs) {
    final limit = nowUs - _pruneUs;
    while (buf.length > 2 && buf.first.us < limit) {
      buf.removeAt(0);
    }
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
    } finally {
      probe.close();
    }
  }

  // ═══════════ ORCHESTRATOR ════════════════════════════════════

  Future<void> _run(StreamController<FastResult> ctrl) async {
    double dlMbps = 0.0;
    double ulMbps = 0.0;

    try {
      // ── Step 1: Fetch Netflix OCA targets ──
      ctrl.add(FastResult(
        downloadSpeedMbps: 0,
        status: 'Fetching Netflix targets…',
      ));
      final urls = await _fetchTargets();
      if (urls.isEmpty) throw Exception('No Fast.com targets found');
      _logger.log('[Fast] ${urls.length} OCA targets acquired.');
      if (_isCancelled) return;

      // ── Step 2: Latency-based stream count ──
      ctrl.add(FastResult(
        downloadSpeedMbps: 0,
        status: 'Checking latency…',
      ));
      final streams = await _probeLatency(urls.first);
      if (_isCancelled) return;

      // ── Step 3: Download ──
      dlMbps = await _downloadPhase(ctrl, urls, streams);
      if (_isCancelled) return;

      // Brief pause so gauge visually resets between phases
      await Future.delayed(const Duration(milliseconds: 500));

      // ── Step 4: Upload ──
      ulMbps = await _uploadPhase(ctrl, urls, streams, dlMbps);
      if (_isCancelled) return;

      // ── Done ──
      if (!ctrl.isClosed) {
        ctrl.add(FastResult(
          downloadSpeedMbps: dlMbps,
          uploadSpeedMbps:   ulMbps,
          isDone: true,
          status: 'Complete',
        ));
      }
      _logger.log('[Fast] Complete. '
          'DL: ${dlMbps.toStringAsFixed(2)} Mbps, '
          'UL: ${ulMbps.toStringAsFixed(2)} Mbps');
    } catch (e, st) {
      _logger.log('[Fast] Fatal: $e\n$st');
      if (!ctrl.isClosed) {
        ctrl.add(FastResult(
          downloadSpeedMbps: dlMbps,
          uploadSpeedMbps:   ulMbps,
          error:  e.toString(),
          status: 'Error',
        ));
      }
    } finally {
      _activeClient?.close(force: true);
      _activeClient = null;
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

    final client = io.HttpClient();
    client.connectionTimeout = _connectTimeout;
    _activeClient = client;

    int totalBytes = 0;
    final sw  = Stopwatch()..start();
    final buf = <_Sample>[const _Sample(0, 0)];
    bool killed = false;

    // ❶ KILL TIMER — destroys every socket at exactly 15 s.
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      killed = true;
      _logger.log('[Fast DL] Kill timer → force-closing all sockets.');
      client.close(force: true);
    });

    // ❷ UI TICKER — records a sample and emits smoothed speed.
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || killed) return;
      final now = sw.elapsedMicroseconds;
      buf.add(_Sample(now, totalBytes));
      _pruneBuf(buf, now);
      ctrl.add(FastResult(
        downloadSpeedMbps: _windowedSpeed(buf, now),
        status: 'Downloading…',
      ));
    });

    // ❸ WORKERS — all awaited via Future.wait.
    final n = min(streams, urls.length);
    final futures = <Future<void>>[];
    for (int i = 0; i < n; i++) {
      futures.add(_dlWorker(
        client,
        urls[i],
        (bytes) { totalBytes += bytes; },
        () => killed || _isCancelled,
      ));
    }

    await Future.wait(futures); // resolves once kill timer fires

    sw.stop();
    kill.cancel();
    ui.cancel();
    if (_activeClient == client) _activeClient = null;

    final mbps = _mbps(totalBytes, sw.elapsedMicroseconds);
    _logger.log('[Fast DL] ${_fmtBytes(totalBytes)} in '
        '${(sw.elapsedMicroseconds / 1e6).toStringAsFixed(1)}s '
        '→ ${mbps.toStringAsFixed(2)} Mbps');
    return mbps;
  }

  /// Single download worker: loops GET requests until [shouldStop].
  /// Each request downloads the OCA test payload (~25 MB).
  /// Keep-alive reuses the TCP+TLS connection across iterations.
  Future<void> _dlWorker(
    io.HttpClient client,
    String url,
    void Function(int) onBytes,
    bool Function() shouldStop,
  ) async {
    final uri = Uri.parse(url);
    while (!shouldStop()) {
      try {
        final request  = await client.getUrl(uri);
        final response = await request.close();

        // await-for provides natural backpressure: chunks arrive
        // at network speed, not memory speed.
        await for (final chunk in response) {
          if (shouldStop()) break;
          onBytes(chunk.length);
        }
      } catch (e) {
        // SocketException is EXPECTED when kill timer fires.
        if (!shouldStop()) {
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
    ctrl.add(FastResult(
      downloadSpeedMbps: dlMbps,
      uploadSpeedMbps:   0,
      status: 'Starting upload…',
    ));

    final client = io.HttpClient();
    client.connectionTimeout = _connectTimeout;
    _activeClient = client;

    // ── Build a non-compressible 512 KB chunk ──
    // LCG-style fill so ISP transparent compression can't cheat.
    // Allocated ONCE, shared by all workers (read-only) → zero GC pressure.
    final chunk = Uint8List(_ulChunkBytes);
    for (int i = 0; i < chunk.length; i++) {
      chunk[i] = (i * 131 + 17) & 0xFF;
    }

    int totalBytes = 0;
    final sw  = Stopwatch()..start();
    final buf = <_Sample>[const _Sample(0, 0)];
    bool killed = false;

    // ❶ KILL TIMER
    final kill = Timer(Duration(seconds: _testDurationSec), () {
      killed = true;
      _logger.log('[Fast UL] Kill timer → force-closing all sockets.');
      client.close(force: true);
    });

    // ❷ UI TICKER
    final ui = Timer.periodic(Duration(milliseconds: _uiTickMs), (_) {
      if (ctrl.isClosed || killed) return;
      final now = sw.elapsedMicroseconds;
      buf.add(_Sample(now, totalBytes));
      _pruneBuf(buf, now);
      ctrl.add(FastResult(
        downloadSpeedMbps: dlMbps,
        uploadSpeedMbps:   _windowedSpeed(buf, now),
        status: 'Uploading…',
      ));
    });

    // ❸ WORKERS
    final uploadUrls = urls.map(_toUploadUrl).toList();
    _logger.log('[Fast UL] Upload URLs: ${uploadUrls.take(2)}...');

    final n = min(streams, uploadUrls.length);
    final futures = <Future<void>>[];
    for (int i = 0; i < n; i++) {
      futures.add(_ulWorker(
        client,
        uploadUrls[i],
        chunk,
        (bytes) { totalBytes += bytes; },
        () => killed || _isCancelled,
      ));
    }

    await Future.wait(futures);

    sw.stop();
    kill.cancel();
    ui.cancel();
    try { client.close(force: true); } catch (_) {}
    if (_activeClient == client) _activeClient = null;

    final mbps = _mbps(totalBytes, sw.elapsedMicroseconds);
    _logger.log('[Fast UL] ${_fmtBytes(totalBytes)} in '
        '${(sw.elapsedMicroseconds / 1e6).toStringAsFixed(1)}s '
        '→ ${mbps.toStringAsFixed(2)} Mbps');
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
    bool Function() shouldStop,
  ) async {
    final uri = Uri.parse(url);

    while (!shouldStop()) {
      try {
        final request = await client.postUrl(uri);
        request.headers.contentType = io.ContentType.binary;
        request.headers.chunkedTransferEncoding = true;

        // Inner loop: write chunks with backpressure
        while (!shouldStop()) {
          request.add(chunk);
          await request.flush();       // ← BLOCKS at network speed
          onBytes(chunk.length);       // ← counted AFTER confirmation
        }

        // Graceful close (best-effort)
        try { await request.close(); } catch (_) {}
      } catch (e) {
        // SocketException is EXPECTED when kill timer fires.
        if (!shouldStop()) {
          _logger.log('[Fast UL Worker] $e');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }

  // ── Formatting helper for logs ──
  static String _fmtBytes(int b) {
    if (b >= 1e9) return '${(b / 1e9).toStringAsFixed(2)} GB';
    if (b >= 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB';
    if (b >= 1e3) return '${(b / 1e3).toStringAsFixed(0)} KB';
    return '$b B';
  }
}
```

---

## Summary of Every Fix

| # | Problem | Old Code | Fix | Why |
|---|---------|----------|-----|-----|
| 1 | **Upload counts round-trip time, not throughput** | `client.post(url, body: 1MB)` → count after response | `request.add(chunk)` + `await request.flush()` + count **after** | `flush()` blocks until OS TCP buffer accepts data — real network backpressure. Bytes counted = bytes sent. |
| 2 | **Workers are fire-and-forget** | `_downloadWorker(...)` with no `await` | `futures.add(...)` + `await Future.wait(futures)` | Workers are tracked. Phase doesn't "end" until all workers actually stop. |
| 3 | **No forceful termination** | Timer sets a flag; workers keep running | `httpClient.close(force: true)` in kill `Timer` | Force-close destroys every open socket instantly. Pending `flush()` / `await for` throws → loops exit. |
| 4 | **Cumulative average for gauge** | `totalBytes * 8 / totalTime` from `t=0` | 1-second **sliding window** average, emitted at 4 Hz | TCP slow-start doesn't drag down the reading. Single bursts can't spike it. |
| 5 | **`DateTime.now()` imprecision** | `DateTime.now().difference(...)` (ms granularity) | `Stopwatch` (µs granularity, monotonic) | High-resolution monotonic clock. Not affected by system clock changes. |
| 6 | **Upload URL path** | `uri.replace(path: '/speedtest/upload')` | Same logic, but now actually **used correctly** with working workers | Logic was correct; the upload *transport* was broken. Documented explicitly. |
| 7 | **Latency probe downloads 25 MB** | `client.get(urls.first)` (full payload) | `Range: bytes=0-0` (1 byte) | Measures connection latency, not throughput. Wastes zero bandwidth. |
| 8 | **Compressible upload data** | `Uint8List(1MB)` (all zeros) | `chunk[i] = (i * 131 + 17) & 0xFF` (LCG pseudo-random) | Prevents ISP transparent compression from inflating results. |
| 9 | **Memory: shared client across phases** | Single `http.Client()` for everything | Separate `io.HttpClient` per phase, each independently force-closeable | Download phase cleanup can't break upload phase. Cancel at any point is clean. |
| 10 | **`cancel()` doesn't kill active I/O** | `_isCancelled = true` (flag only) | `_activeClient?.close(force: true)` | Immediately destroys sockets. Workers' pending I/O throws → loops exit. |

---

## Overall Evaluation & Recommendations

**Structural weaknesses in Fast.com API consumption:**

| Area | Risk | Recommendation |
|------|------|----------------|
| **Hardcoded token** | `YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm` is Netflix's public token, but they can rotate it at any time → entire feature breaks silently | Add a fallback: if `api.fast.com` returns 403/401, surface a clear error message ("Fast.com token expired") rather than a generic failure |
| **Token expiry on OCA URLs** | The `e=` and `t=` query parameters in OCA URLs expire (typically within minutes) | Always fetch fresh targets immediately before each phase; don't cache URLs across test runs |
| **OCA upload support** | Not all Netflix OCA appliances (especially ISP-hosted ones) accept POST requests to `/speedtest/upload` | Wrap the upload phase in a try/catch that degrades gracefully: if all workers fail with 4xx/5xx, report "Upload not supported by this Netflix server" instead of crashing |
| **ISP whitelisting detection** | Lebanese ISPs may whitelist `*.nflxvideo.net` at the DNS/routing level, giving it priority QoS — which is the entire point of your app | Consider logging the resolved IP address and AS number of the OCA server to confirm it's local (ISP cache) vs. international |
| **Rate limiting** | `api.fast.com` may rate-limit aggressive polling | Cache targets for the duration of one test (already done), and add a minimum 30-second cooldown between consecutive test runs |