import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_speed_test/services/real_speed_service.dart';
import 'package:network_speed_test/services/fast_service.dart';
import 'package:network_speed_test/services/ookla_service.dart';
import 'package:network_speed_test/services/cloudflare_service.dart';
import 'package:network_speed_test/services/facebook_cdn_service.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/services/isp_service.dart';
import 'package:network_speed_test/models/network_info.dart';
import 'package:network_speed_test/widgets/isp_banner.dart';
import 'package:network_speed_test/services/akamai_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Network Speed Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SpeedTestScreen(),
    );
  }
}

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  // Services
  final RealSpeedHttpService _realSpeedService = RealSpeedHttpService();
  final FastService _fastService = FastService();
  final OoklaService _ooklaService = OoklaService();
  final CloudflareService _cloudflareService = CloudflareService();
  final FacebookCdnService _facebookService = FacebookCdnService();
  final AkamaiService _akamaiService = AkamaiService();
  final IspService _ispService = IspService();
  final DebugLogger _logger = DebugLogger();

  // --- Global State ---
  // 0 = None, 1 = Real, 2 = Stream, 3 = Standard, 4 = Cloudflare, 5 = Facebook
  int _activeTestId = 0;
  double _globalDownload = 0.0;
  double _globalUpload = 0.0;
  String _globalStatus = "Ready";
  bool _isGlobalBusy = false;

  // Network Info
  NetworkInfo? _networkInfo;

  // --- Persistent Results & Status per Test ---
  // Real Speed (iperf3)
  String? _realStatus;

  // Streaming (Fast)
  FastResult? _savedFastResult;
  String? _fastStatus;

  // Standard (Ookla)
  OoklaResult? _savedOoklaResult;
  String? _ooklaStatus;

  // Cloudflare
  CloudflareResult? _savedCloudflareResult;
  String? _cloudflareStatus;

  // Facebook CDN
  FacebookCdnResult? _savedFacebookResult;
  String? _facebookStatus;

  // Akamai Edge CDN
  AkamaiResult? _savedAkamaiResult;
  String? _akamaiStatus;

  // Real Speed Result
  // No retry logic needed for HTTP simple test

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onLog);
  }

  @override
  void dispose() {
    _realSpeedService.cancel();
    _fastService.cancel();
    _ooklaService.cancel();
    _cloudflareService.cancel();
    _facebookService.cancel();
    _akamaiService.cancel();
    _logger.removeListener(_onLog);
    super.dispose();
  }

  void _onLog(String msg) {
    // Console logging if needed
  }

  // --- Test Runners ---

  Future<void> _cancelActiveTest() async {
    if (!_isGlobalBusy) return;

    _logger.log("Cancelling active test: $_activeTestId");

    // 1. Stop the specific service
    switch (_activeTestId) {
      case 1: // Real
        _realSpeedService.cancel();
        break;
      case 2: // Fast
        _fastService.cancel();
        break;
      case 3: // Ookla
        _ooklaService.cancel();
        break;
      case 4: // Cloudflare
        _cloudflareService.cancel();
        break;
      case 5: // Facebook
        _facebookService.cancel();
        break;
    }

    // 2. Update UI State immediately
    setState(() {
      _isGlobalBusy = false;
      String statusText = "Canceled";

      // Update specific status
      switch (_activeTestId) {
        case 1:
          _realStatus = statusText;
          break;
        case 2:
          _fastStatus = statusText;
          break;
        case 3:
          _ooklaStatus = statusText;
          break;
        case 4:
          _cloudflareStatus = statusText;
          break;
        case 5:
          _facebookStatus = statusText;
          break;
      }

      _activeTestId = 0;
      _globalStatus = "Ready";
      _globalDownload = 0.0;
      _globalUpload = 0.0;
    });
  }

  Future<void> _runRealSpeedTest() async {
    if (_isGlobalBusy) return;

    setState(() {
      _isGlobalBusy = true;
      _activeTestId = 1;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Connecting...";
      _realStatus = "Connecting...";
      // Reset saved results if you want fresh start, or keep them until new ones come
    });

    try {
      final stream = _realSpeedService.measureSpeed();
      await for (final result in stream) {
        if (!mounted || _activeTestId != 1) break;
        setState(() {
          if (result.error != null) {
            _realStatus = "Error: ${result.error}";
            _globalStatus = "Error";
          } else {
            // Update gauges
            _globalDownload = result.downloadSpeedMbps;
            _globalUpload = result.uploadSpeedMbps;

            // Update status text
            _realStatus = result.status;
            _globalStatus = result.status;

            // When done, save final result
            if (result.isDone) {
              _finalRealDl = result.downloadSpeedMbps;
              _finalRealUl = result.uploadSpeedMbps;
            }
          }
        });
      }
    } catch (e) {
      if (_activeTestId == 1) {
        setState(() {
          _realStatus = "Error: $e";
          _globalStatus = "Failed";
        });
      }
    } finally {
      if (mounted && _activeTestId == 1) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  // To properly save Real Speed results (since IperfResult is single-ended),
  // let's add specific double variables for persistence.
  double? _finalRealDl;
  double? _finalRealUl;

  Future<void> _runStreamingTest() async {
    if (_isGlobalBusy) return;
    setState(() {
      _isGlobalBusy = true;
      _activeTestId = 2;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Connecting...";
      _savedFastResult = null;
      _fastStatus = "Connecting...";
    });

    try {
      final stream = _fastService.measureSpeed();
      await for (final result in stream) {
        if (!mounted || _activeTestId != 2) break;
        setState(() {
          if (result.error != null) {
            _fastStatus = "Error: ${result.error}";
            _globalStatus = "Error";
          } else {
            _globalDownload = result.downloadSpeedMbps;
            _globalUpload = result.uploadSpeedMbps;
            _fastStatus = result.status;
            _globalStatus = result.status;
            if (result.isDone) {
              _savedFastResult = result;
            }
          }
        });
      }
    } catch (e) {
      if (_activeTestId == 2) {
        setState(() => _fastStatus = "Error: $e");
      }
    } finally {
      if (mounted && _activeTestId == 2) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  Future<void> _runStandardTest() async {
    if (_isGlobalBusy) return;
    setState(() {
      _isGlobalBusy = true;
      _activeTestId = 3;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Finding Server...";
      _savedOoklaResult = null;
      _ooklaStatus = "Finding Server...";
    });

    try {
      final stream = _ooklaService.measureSpeed();
      await for (final result in stream) {
        if (!mounted || _activeTestId != 3) break;
        setState(() {
          if (result.error != null) {
            _ooklaStatus = "Error: ${result.error}";
            _globalStatus = "Error";
          } else {
            _globalDownload = result.downloadSpeedMbps;
            _globalUpload = result.uploadSpeedMbps;
            _ooklaStatus = result.status;
            _globalStatus = result.status;
            if (result.isDone) {
              _savedOoklaResult = result;
            }
          }
        });
      }
    } catch (e) {
      if (_activeTestId == 3) {
        setState(() => _ooklaStatus = "Error: $e");
      }
    } finally {
      if (mounted && _activeTestId == 3) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  Future<void> _runCloudflareTest() async {
    if (_isGlobalBusy) return;
    setState(() {
      _isGlobalBusy = true;
      _activeTestId = 4;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Connecting...";
      _savedCloudflareResult = null;
      _cloudflareStatus = "Connecting...";
    });

    try {
      final stream = _cloudflareService.measureSpeed();
      await for (final result in stream) {
        if (!mounted || _activeTestId != 4) break;
        setState(() {
          if (result.error != null) {
            _cloudflareStatus = "Error: ${result.error}";
            _globalStatus = "Error";
          } else {
            _globalDownload = result.downloadSpeedMbps;
            _globalUpload = result.uploadSpeedMbps;
            _cloudflareStatus = result.status;
            _globalStatus = result.status;
            if (result.isDone) {
              _savedCloudflareResult = result;
            }
          }
        });
      }
    } catch (e) {
      if (_activeTestId == 4) {
        setState(() => _cloudflareStatus = "Error: $e");
      }
    } finally {
      if (mounted && _activeTestId == 4) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  Future<void> _runFacebookTest() async {
    if (_isGlobalBusy) return;
    setState(() {
      _isGlobalBusy = true;
      _activeTestId = 5;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Probing Meta CDN...";
      _savedFacebookResult = null;
      _facebookStatus = "Probing Meta CDN...";
    });

    try {
      final stream = _facebookService.measureSpeed();
      await for (final result in stream) {
        if (!mounted || _activeTestId != 5) break;
        setState(() {
          if (result.error != null) {
            _facebookStatus = "Error: ${result.error}";
            _globalStatus = "Error";
          } else {
            _globalDownload = result.downloadMbps;
            _globalUpload = result.uploadMbps;
            _facebookStatus = result.status;
            _globalStatus = result.status;
            if (result.isDone) {
              _savedFacebookResult = result;
            }
          }
        });
      }
    } catch (e) {
      if (_activeTestId == 5) {
        setState(() => _facebookStatus = "Error: $e");
      }
    } finally {
      if (mounted && _activeTestId == 5) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  Future<void> _runAkamaiTest() async {
    if (_isGlobalBusy) return;
    setState(() {
      _isGlobalBusy = true;
      _activeTestId = 6;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Starting...";
      _akamaiStatus = "Connecting";
      _savedAkamaiResult = null;
    });

    try {
      final stream = _akamaiService.measureSpeed();
      await for (final res in stream) {
        if (!mounted) break;
        if (_activeTestId != 6) return; // Cancelled

        setState(() {
          // Status propagation
          _akamaiStatus = res.status;
          _globalStatus = res.status;

          if (res.downloadMbps > 0) {
            _globalDownload = res.downloadMbps;
          }
          if (res.uploadMbps > 0) {
            _globalUpload = res.uploadMbps;
          }
          if (res.error != null) {
            _globalStatus = "Failed";
            _akamaiStatus = "Error: ${res.error}";
          } else if (res.isDone) {
            _globalStatus = "Complete";
            _akamaiStatus = "Finished";
            _savedAkamaiResult = res;
          }
        });
      }
    } finally {
      if (mounted && _activeTestId == 6) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  // Retry logic removed

  // --- UI Builders ---

  void _showDebugConsole() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => DebugConsoleScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101010), // Ultra dark background
      appBar: AppBar(
        leading: const Center(
          child: Text(
            "AliTf",
            style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
          ),
        ),
        title: const Text('Real test'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: _showDebugConsole,
            tooltip: "Debug Console",
          ),
        ],
      ),
      body: Column(
        children: [
          // 0. ISP Banner (Zero-Click Detection)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: IspBanner(
              ispService: _ispService,
              showIp: true,
              onDetected: (info) {
                _networkInfo = info;
                // Optional: trigger setState if you need to use info elsewhere
              },
            ),
          ),

          // 1. Top Section: Global Meter (Compact)
          Expanded(flex: 30, child: _buildGlobalMeter()),

          // 2. Bottom Section: Test List (Compact)
          Expanded(
            flex: 60,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20), // Reduced radius
                  topRight: Radius.circular(20),
                ),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                physics:
                    const ClampingScrollPhysics(), // Try to avoid bounce if fitting
                children: [
                  // Real Speed
                  _buildTestTile(
                    id: 1,
                    title: "Real speed",
                    icon: Icons.speed,
                    color: Colors.cyan,
                    status: _realStatus,
                    finalDl: _activeTestId == 1 ? null : _finalRealDl,
                    // If active, we don't show result in card, we show it on top.
                    // Wait, user said "Live Routing" to top.
                    // "Persistence: ... keeps saved final result from earlier."
                    // So if active, maybe dim the result or show running status.
                    finalUl: _activeTestId == 1 ? null : _finalRealUl,
                    onStart: _runRealSpeedTest,
                  ),

                  // Streaming
                  _buildTestTile(
                    id: 2,
                    title: "Fast",
                    icon: Icons.movie_filter,
                    color: Colors.green,
                    status: _fastStatus,
                    finalDl: _savedFastResult?.downloadSpeedMbps,
                    finalUl: _savedFastResult?.uploadSpeedMbps,
                    onStart: _runStreamingTest,
                  ),

                  // Standard
                  _buildTestTile(
                    id: 3,
                    title: "Speedtest by Ookla",
                    icon: Icons.network_check,
                    color: Colors.orange,
                    status: _ooklaStatus,
                    finalDl: _savedOoklaResult?.downloadSpeedMbps,
                    finalUl: _savedOoklaResult?.uploadSpeedMbps,
                    onStart: _runStandardTest,
                  ),

                  // Cloudflare
                  _buildTestTile(
                    id: 4,
                    title: "Cloudflare Speedtest",
                    icon: Icons.cloud_queue,
                    color: Colors.purple,
                    status: _cloudflareStatus,
                    finalDl: _savedCloudflareResult?.downloadSpeedMbps,
                    finalUl: _savedCloudflareResult?.uploadSpeedMbps,
                    onStart: _runCloudflareTest,
                  ),

                  // Facebook CDN
                  _buildTestTile(
                    id: 5,
                    title: "Facebook CDN (FNA)",
                    subtitle: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildSticker(
                          Icons.camera_alt,
                          "Instagram",
                          Colors.pinkAccent,
                        ),
                        const SizedBox(width: 6),
                        _buildSticker(
                          Icons.chat,
                          "WhatsApp",
                          Colors.greenAccent,
                        ),
                      ],
                    ),
                    icon: Icons.facebook,
                    color: Colors.blueAccent,
                    status: _facebookStatus,
                    finalDl: _savedFacebookResult?.downloadMbps,
                    finalUl: _savedFacebookResult?.uploadMbps, // Now supported
                    onStart: _runFacebookTest,
                  ),

                  // Akamai CDN
                  _buildTestTile(
                    id: 6,
                    title: "Akamai Edge-Cache",
                    subtitle: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildSticker(
                          Icons.games,
                          "Steam",
                          Colors.indigoAccent,
                        ),
                        const SizedBox(width: 6),
                        _buildSticker(Icons.apple, "Apple", Colors.grey),
                        const SizedBox(width: 6),
                        _buildSticker(
                          Icons.picture_as_pdf,
                          "Adobe",
                          Colors.redAccent,
                        ),
                      ],
                    ),
                    icon: Icons.cloud_download,
                    color: Colors.red,
                    status: _akamaiStatus,
                    finalDl: _savedAkamaiResult?.downloadMbps,
                    finalUl: _savedAkamaiResult?.uploadMbps,
                    onStart: _runAkamaiTest,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalMeter() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Active Test Name Badge
          if (_activeTestId != 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              margin: const EdgeInsets.only(bottom: 10), // Reduced margin
              decoration: BoxDecoration(
                color: _getTestColor(_activeTestId).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _getTestColor(_activeTestId).withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                _getTestName(_activeTestId).toUpperCase(),
                style: TextStyle(
                  color: _getTestColor(_activeTestId),
                  fontWeight: FontWeight.bold,
                  fontSize: 12, // Reduced font
                  letterSpacing: 1.0,
                ),
              ),
            ),

          // Speed Values
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBigGauge("DOWNLOAD", _globalDownload, Colors.white),
              _buildBigGauge("UPLOAD", _globalUpload, Colors.white70),
            ],
          ),

          const SizedBox(height: 10), // Reduced height
          // Status Text
          Text(
            _globalStatus,
            style: const TextStyle(
              fontSize: 14, // Reduced font
              color: Colors.grey,
              fontFamily: 'monospace',
            ),
          ),

          // Debugging Info (Network Info if available)
          if (_networkInfo != null && _activeTestId != 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                "Testing against ${_networkInfo!.ispName}",
                style: const TextStyle(color: Colors.grey, fontSize: 10),
              ),
            ),

          // FB Specific Info (CDN Edge)
          if (_activeTestId == 5 &&
              _savedFacebookResult != null &&
              _savedFacebookResult!.cdnEdge != null)
            Text(
              "Edge: ${_savedFacebookResult!.cdnEdge}",
              style: const TextStyle(color: Colors.blueGrey, fontSize: 10),
            ),

          // Akamai Specific Info
          if (_activeTestId == 6 &&
              _savedAkamaiResult != null &&
              _savedAkamaiResult!.edgeIp != null)
            Text(
              "Node IP: ${_savedAkamaiResult!.edgeIp} • ${_savedAkamaiResult!.edgeNode}",
              style: const TextStyle(color: Colors.redAccent, fontSize: 10),
            ),
        ],
      ),
    );
  }

  Widget _buildBigGauge(String label, double value, Color color) {
    return Column(
      children: [
        Text(
          value.toStringAsFixed(2),
          style: TextStyle(
            fontSize: 40, // Reduced from 48
            fontWeight: FontWeight.w300,
            color: color,
            height: 1.0,
          ),
        ),
        Text(
          "Mbps",
          style: TextStyle(
            fontSize: 12, // Reduced from 14
            color: color.withValues(alpha: 0.6),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4), // Reduced from 10
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.5,
            color: color.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }

  Widget _buildTestTile({
    required int id,
    required String title,
    Widget? subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onStart,
    String? status,
    double? finalDl,
    double? finalUl,
  }) {
    final bool isRunning = _activeTestId == id;
    final bool canStart = !_isGlobalBusy;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6), // Reduced from 8
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ), // Reduced vertical padding
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(12),
        border: isRunning ? Border.all(color: color, width: 2) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8), // Reduced from 10
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 20), // Reduced from 24
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      subtitle,
                    ],
                  ],
                ),
              ),

              // Start Button or Running Indicator
              if (isRunning)
                Tooltip(
                  message: "Tap to Cancel",
                  child: GestureDetector(
                    onTap: _cancelActiveTest,
                    child: SizedBox(
                      width: 24,
                      height: 24, // Reduced size
                      child: CircularProgressIndicator(
                        color: color,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.play_arrow_rounded, size: 28),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: canStart
                      ? Colors.white
                      : Colors.grey.withValues(alpha: 0.3),
                  onPressed: canStart ? onStart : null,
                ),
            ],
          ),

          // Status & Results Row
          if (status != null || finalDl != null || finalUl != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Divider(color: Colors.white10),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Status Text
                Expanded(
                  child: Text(
                    status ?? "Ready",
                    style: TextStyle(
                      color: isRunning ? color : Colors.grey,
                      fontSize: 11, // Reduced font
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),

                // Results
                if (finalDl != null)
                  Row(
                    children: [
                      const Icon(Icons.download, size: 12, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(
                        finalDl.toStringAsFixed(1),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.upload, size: 12, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(
                        // If test is done but upload isn't supported (like some others), we default to 0.0 or hide
                        // But finalUl will be null if not supported.
                        (finalUl ?? 0.0).toStringAsFixed(1),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Color _getTestColor(int id) {
    switch (id) {
      case 1:
        return Colors.cyan;
      case 2:
        return Colors.green;
      case 3:
        return Colors.orange;
      case 4:
        return Colors.purple;
      case 5:
        return Colors.blueAccent;
      case 6:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  Widget _buildSticker(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              fontSize: 9,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getTestName(int id) {
    switch (id) {
      case 1:
        return "Real speed";
      case 2:
        return "Fast";
      case 3:
        return "Speedtest by Ookla";
      case 4:
        return "Cloudflare Speedtest";
      case 5:
        return "Facebook CDN";
      case 6:
        return "Akamai Edge-Cache";
      default:
        return "";
    }
  }
}

// Keep DebugConsoleScreen as is...
class DebugConsoleScreen extends StatefulWidget {
  const DebugConsoleScreen({super.key});

  @override
  State<DebugConsoleScreen> createState() => _DebugConsoleScreenState();
}

class _DebugConsoleScreenState extends State<DebugConsoleScreen> {
  final DebugLogger _logger = DebugLogger();
  late List<String> _logs;

  @override
  void initState() {
    super.initState();
    _logs = List.from(_logger.logs);
    _logger.addListener(_onLogAdded);
  }

  @override
  void dispose() {
    _logger.removeListener(_onLogAdded);
    super.dispose();
  }

  void _onLogAdded(String msg) {
    if (mounted) {
      setState(() {
        _logs.add(msg);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Debug Console"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              _logger.clear();
              setState(() {
                _logs.clear();
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final text = _logs.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("All logs copied to clipboard")),
              );
            },
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _logs.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _logs[index],
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
