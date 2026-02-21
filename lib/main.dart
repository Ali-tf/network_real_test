import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_speed_test/utils/debug_logger.dart';
import 'package:network_speed_test/services/isp_service.dart';
import 'package:network_speed_test/models/network_info.dart';
import 'package:network_speed_test/models/unified_result.dart';
import 'package:network_speed_test/widgets/isp_banner.dart';
import 'package:network_speed_test/engine/universal_orchestrator.dart';
import 'package:network_speed_test/engine/engine_registry.dart';

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
  final IspService _ispService = IspService();
  final DebugLogger _logger = DebugLogger();
  final UniversalOrchestrator _orchestrator = UniversalOrchestrator();

  // --- Global State ---
  int _activeTestId = 0;
  double _globalDownload = 0.0;
  double _globalUpload = 0.0;
  String _globalStatus = "Ready";
  bool _isGlobalBusy = false;

  // Network Info
  NetworkInfo? _networkInfo;

  // Per-engine saved results and status strings (keyed by engine id)
  final Map<int, UnifiedResult> _savedResults = {};
  final Map<int, String> _statuses = {};

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onLog);
  }

  @override
  void dispose() {
    _orchestrator.cancel();
    _logger.removeListener(_onLog);
    super.dispose();
  }

  void _onLog(String msg) {}

  // --- Single Generic Test Runner ---

  Future<void> _runTest(EngineEntry entry) async {
    if (_isGlobalBusy) return;
    setState(() {
      _isGlobalBusy = true;
      _activeTestId = entry.id;
      _globalDownload = 0.0;
      _globalUpload = 0.0;
      _globalStatus = "Connecting...";
      _savedResults.remove(entry.id);
      _statuses[entry.id] = "Connecting...";
    });

    try {
      final stream = _orchestrator.start(entry.factory());
      await for (final result in stream) {
        if (!mounted || _activeTestId != entry.id) break;
        setState(() {
          if (result.hasError) {
            _statuses[entry.id] = "Error: ${result.error}";
            _globalStatus = "Error";
          } else {
            _globalDownload = result.downloadMbps;
            _globalUpload = result.uploadMbps;
            _statuses[entry.id] = result.status;
            _globalStatus = result.status;
            if (result.isDone) {
              _savedResults[entry.id] = result;
            }
          }
        });
      }
    } catch (e) {
      if (_activeTestId == entry.id) {
        setState(() => _statuses[entry.id] = "Error: $e");
      }
    } finally {
      if (mounted && _activeTestId == entry.id) {
        setState(() {
          _isGlobalBusy = false;
          _activeTestId = 0;
          _globalStatus = "Ready";
        });
      }
    }
  }

  Future<void> _cancelActiveTest() async {
    if (!_isGlobalBusy) return;
    _logger.log("Cancelling active test: $_activeTestId");
    _orchestrator.cancel();
    setState(() {
      _statuses[_activeTestId] = "Canceled";
      _isGlobalBusy = false;
      _activeTestId = 0;
      _globalStatus = "Ready";
      _globalDownload = 0.0;
      _globalUpload = 0.0;
    });
  }

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
                  ...EngineRegistry.engines.map(
                    (e) => _buildTestTile(
                      id: e.id,
                      title: e.title,
                      subtitle: e.stickers != null
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (
                                  int i = 0;
                                  i < e.stickers!.length;
                                  i++
                                ) ...[
                                  if (i > 0) const SizedBox(width: 6),
                                  _buildSticker(
                                    e.stickers![i].icon,
                                    e.stickers![i].label,
                                    e.stickers![i].color,
                                  ),
                                ],
                              ],
                            )
                          : null,
                      icon: e.icon,
                      color: e.color,
                      status: _statuses[e.id],
                      finalDl: _savedResults[e.id]?.downloadMbps,
                      finalUl: _savedResults[e.id]?.uploadMbps,
                      onStart: () => _runTest(e),
                    ),
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
                color:
                    (EngineRegistry.byId(_activeTestId)?.color ?? Colors.grey)
                        .withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      (EngineRegistry.byId(_activeTestId)?.color ?? Colors.grey)
                          .withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                EngineRegistry.byId(_activeTestId)?.title.toUpperCase() ?? '',
                style: TextStyle(
                  color:
                      EngineRegistry.byId(_activeTestId)?.color ?? Colors.grey,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
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

          // Engine-specific metadata display
          if (_activeTestId != 0 && _savedResults[_activeTestId] != null) ...[
            if (_savedResults[_activeTestId]!.engineMetadata['cdnEdge'] != null)
              Text(
                "Edge: ${_savedResults[_activeTestId]!.engineMetadata['cdnEdge']}",
                style: const TextStyle(color: Colors.blueGrey, fontSize: 10),
              ),
            if (_savedResults[_activeTestId]!.engineMetadata['edgeIp'] != null)
              Text(
                "Node IP: ${_savedResults[_activeTestId]!.engineMetadata['edgeIp']} • ${_savedResults[_activeTestId]!.engineMetadata['host'] ?? ''}",
                style: const TextStyle(color: Colors.redAccent, fontSize: 10),
              ),
            if (_savedResults[_activeTestId]!.engineMetadata['cacheIp'] != null)
              Text(
                "Cache Node: ${_savedResults[_activeTestId]!.engineMetadata['nodeLocationId'] ?? 'Unknown'} • ${_savedResults[_activeTestId]!.engineMetadata['cacheIp']}",
                style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
              ),
          ],
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
