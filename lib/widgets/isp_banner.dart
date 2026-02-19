// lib/widgets/isp_banner.dart

import 'package:flutter/material.dart';
import 'package:network_speed_test/models/network_info.dart';
import 'package:network_speed_test/services/isp_service.dart';

/// A self-contained widget that automatically detects and displays
/// the user's ISP, IP, and country on mount. No button. No user action.
///
/// States:
///   1. Loading  → shimmer animation + "Detecting provider..."
///   2. Success  → ISP name, masked IP, country flag
///   3. Offline  → "No internet connection" with retry
///   4. Partial  → IP only (ISP unknown)
///
/// Usage:
///   Simply drop `IspBanner()` into any widget tree.
///   It manages its own state and API calls internally.
class IspBanner extends StatefulWidget {
  /// Optional: provide a shared IspService instance
  /// so the cache persists across widget rebuilds.
  final IspService? ispService;

  /// Whether to show the public IP (masked).
  final bool showIp;

  /// Callback when detection completes (for parent widgets
  /// that need the data, e.g., to include in test results).
  final ValueChanged<NetworkInfo?>? onDetected;

  const IspBanner({
    super.key,
    this.ispService,
    this.showIp = true,
    this.onDetected,
  });

  @override
  State<IspBanner> createState() => _IspBannerState();
}

class _IspBannerState extends State<IspBanner>
    with SingleTickerProviderStateMixin {
  late final IspService _service;
  late final AnimationController _shimmerController;

  // States
  bool _isLoading = true;
  bool _isOffline = false;
  NetworkInfo? _info;

  @override
  void initState() {
    super.initState();
    _service = widget.ispService ?? IspService();

    // Shimmer animation
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    // Fire detection immediately — ZERO clicks
    _detect();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  Future<void> _detect() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _isOffline = false;
    });

    final result = await _service.detect();

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _info = result;
      _isOffline = result == null;
    });

    widget.onDetected?.call(result);
  }

  Future<void> _refresh() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _isOffline = false;
    });

    final result = await _service.refresh();

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _info = result;
      _isOffline = result == null;
    });

    widget.onDetected?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _isLoading
          ? _buildLoading()
          : _isOffline
          ? _buildOffline()
          : _buildInfo(),
    );
  }

  // ── Loading State ──────────────────────────────────────────

  Widget _buildLoading() {
    return Container(
      key: const ValueKey('loading'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.cyanAccent.withOpacity(0.6),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Shimmer text
          AnimatedBuilder(
            animation: _shimmerController,
            builder: (context, child) {
              return ShaderMask(
                shaderCallback: (bounds) {
                  return LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.white.withOpacity(0.3),
                      Colors.white.withOpacity(0.7),
                      Colors.white.withOpacity(0.3),
                    ],
                    stops: [
                      _shimmerController.value - 0.3,
                      _shimmerController.value,
                      _shimmerController.value + 0.3,
                    ].map((s) => s.clamp(0.0, 1.0)).toList(),
                  ).createShader(bounds);
                },
                child: const Text(
                  'Detecting provider...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Success State ──────────────────────────────────────────

  Widget _buildInfo() {
    final info = _info!;
    final hasFullData = info.hasFullData;

    return GestureDetector(
      key: const ValueKey('info'),
      onTap: _refresh, // Tap to refresh
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hasFullData
                ? Colors.cyanAccent.withOpacity(0.15)
                : Colors.orangeAccent.withOpacity(0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Country flag or network icon
            _buildLeadingIcon(info),
            const SizedBox(width: 12),

            // ISP info column
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ISP Name
                  Text(
                    info.shortLabel,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.95),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),

                  const SizedBox(height: 2),

                  // Subtitle: IP + Location
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.showIp) ...[
                        Text(
                          info.maskedIp,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.45),
                            fontSize: 12,
                            fontFamily: 'monospace',
                            letterSpacing: 0.5,
                          ),
                        ),
                        if (info.country.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '•',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.25),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ],
                      if (info.country.isNotEmpty)
                        Flexible(
                          child: Text(
                            info.city.isNotEmpty
                                ? '${info.city}, ${info.country}'
                                : info.country,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.45),
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeadingIcon(NetworkInfo info) {
    // Show country flag emoji if we have a country code
    if (info.countryCode.isNotEmpty && info.countryCode.length == 2) {
      final flag = _countryCodeToFlag(info.countryCode);
      return Text(flag, style: const TextStyle(fontSize: 24));
    }

    // Fallback icon
    return Icon(
      info.hasFullData ? Icons.cell_tower_rounded : Icons.language_rounded,
      color: info.hasFullData
          ? Colors.cyanAccent.withOpacity(0.7)
          : Colors.orangeAccent.withOpacity(0.7),
      size: 24,
    );
  }

  /// Convert ISO 3166-1 alpha-2 country code to flag emoji.
  /// "LB" → 🇱🇧, "US" → 🇺🇸
  String _countryCodeToFlag(String code) {
    final upper = code.toUpperCase();
    if (upper.length != 2) return '🌐';

    // Regional indicator symbols: 🇦 = 0x1F1E6, A = 0x41
    final first = 0x1F1E6 + (upper.codeUnitAt(0) - 0x41);
    final second = 0x1F1E6 + (upper.codeUnitAt(1) - 0x41);
    return String.fromCharCodes([first, second]);
  }

  // ── Offline State ──────────────────────────────────────────

  Widget _buildOffline() {
    return GestureDetector(
      key: const ValueKey('offline'),
      onTap: _refresh,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.redAccent.withOpacity(0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              color: Colors.redAccent.withOpacity(0.7),
              size: 22,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'No Connection',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Tap to retry',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
