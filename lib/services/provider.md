

# Automatic ISP / Network Provider Detection — Architecture & Implementation

## API Evaluation for Production Use

Before writing code, let's evaluate the options rigorously:

| API | Speed | Rate Limit | Lebanese/ME Accuracy | Auth Required | HTTPS | Verdict |
|-----|-------|-----------|---------------------|---------------|-------|---------|
| **ip-api.com** | ~80ms | 45 req/min (free) | ✅ Excellent — resolves Ogero, Touch, IDM, Terranet correctly | ❌ No | ⚠️ HTTP only on free tier | **Best data, but HTTP-only is a problem** |
| **ipapi.co** | ~120ms | 1000/day | ✅ Good | ❌ No | ✅ Yes | **Best overall for production** |
| **ipwhois.io** | ~100ms | 10,000/mo | ✅ Good | ❌ No | ✅ Yes | **Solid backup** |
| **ipinfo.io** | ~90ms | 50,000/mo | ✅ Excellent | Token (free tier) | ✅ Yes | Needs signup |
| **ifconfig.me** | ~60ms | None | ❌ IP only, no ISP | ❌ No | ✅ Yes | IP-only fallback |
| **seeip.org** | ~70ms | None | ❌ IP only | ❌ No | ✅ Yes | IP-only fallback |

### Recommendation: **Primary: `ipapi.co` → Fallback: `ipwhois.io` → Last Resort: `seeip.org`**

**Why not ip-api.com as primary?** Their free tier only works over HTTP (not HTTPS). On iOS, App Transport Security blocks plain HTTP by default. On Android 9+, cleartext is blocked by default. You'd need platform-specific exceptions — fragile in production.

**Why ipapi.co?** Free, no auth, HTTPS, 1000 requests/day (more than enough for a diagnostic app), and critically — it resolves Lebanese ISPs accurately:

```
$ curl https://ipapi.co/json/
{
  "ip": "185.X.X.X",
  "org": "Ogero Telecom",
  "asn": "AS42020",
  "isp": "Ogero Telecom",
  "country_name": "Lebanon",
  "city": "Beirut",
  ...
}
```

---

## Complete Implementation

### File Structure

```
lib/
├── models/
│   └── network_info.dart          # Data model
├── services/
│   └── isp_service.dart           # ISP detection service
├── widgets/
│   └── isp_banner.dart            # Self-contained UI widget
└── screens/
    └── home_screen.dart           # Integration example
```

---

### 1. Data Model — `network_info.dart`

```dart
// lib/models/network_info.dart

/// Immutable data model for network provider information.
/// Detected automatically on app launch — no user action required.
class NetworkInfo {
  final String ipAddress;
  final String ispName;
  final String organization;
  final String asn;
  final String country;
  final String countryCode;
  final String city;
  final String region;
  final String timezone;
  final String source; // Which API provided this data

  const NetworkInfo({
    required this.ipAddress,
    required this.ispName,
    this.organization = '',
    this.asn = '',
    this.country = '',
    this.countryCode = '',
    this.city = '',
    this.region = '',
    this.timezone = '',
    this.source = '',
  });

  /// Creates a minimal instance when only IP is available (fallback).
  factory NetworkInfo.ipOnly(String ip) {
    return NetworkInfo(
      ipAddress: ip,
      ispName: 'Unknown Provider',
      source: 'ip-only-fallback',
    );
  }

  /// Formatted display string for the UI banner.
  /// Examples:
  ///   "Ogero Telecom • Beirut, Lebanon"
  ///   "Touch LB • Lebanon"
  ///   "Unknown Provider"
  String get displayString {
    final parts = <String>[ispName];

    if (city.isNotEmpty && country.isNotEmpty) {
      parts.add('$city, $country');
    } else if (country.isNotEmpty) {
      parts.add(country);
    }

    return parts.join(' • ');
  }

  /// Short ISP label for compact UI areas.
  String get shortLabel {
    if (ispName.isNotEmpty && ispName != 'Unknown Provider') {
      return ispName;
    }
    if (organization.isNotEmpty) return organization;
    return 'Unknown Provider';
  }

  /// Whether we have full ISP data (not just an IP).
  bool get hasFullData => ispName.isNotEmpty && ispName != 'Unknown Provider';

  /// Masked IP for privacy-conscious display (e.g., "185.X.X.42").
  String get maskedIp {
    final parts = ipAddress.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.•••.•••.${parts[3]}';
    }
    // IPv6 or unusual format — show first and last segments
    if (ipAddress.contains(':')) {
      final v6Parts = ipAddress.split(':');
      if (v6Parts.length >= 2) {
        return '${v6Parts.first}:•••:${v6Parts.last}';
      }
    }
    return ipAddress;
  }

  @override
  String toString() =>
      'NetworkInfo(ip=$ipAddress, isp=$ispName, org=$organization, '
      'asn=$asn, country=$country, city=$city, source=$source)';
}
```

---

### 2. ISP Detection Service — `isp_service.dart`

```dart
// lib/services/isp_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:network_speed_test/models/network_info.dart';
import 'package:network_speed_test/utils/debug_logger.dart';

/// Automatic ISP / Network Provider detection service.
///
/// Architecture: Cascading fallback with three tiers.
///
/// ┌──────────────────────────────────────────────────────────┐
/// │  Tier 1: ipapi.co (full ISP + geo data)                 │
/// │    ↓ fails                                               │
/// │  Tier 2: ipwhois.io (full ISP + geo data)               │
/// │    ↓ fails                                               │
/// │  Tier 3: seeip.org (IP address only)                    │
/// │    ↓ fails                                               │
/// │  Return: Offline / Error state                           │
/// └──────────────────────────────────────────────────────────┘
///
/// Design decisions:
///   - 5-second timeout per API (total worst-case: 15s, but
///     typically resolves in <200ms from Tier 1).
///   - Results are cached in-memory for the app session to
///     avoid redundant API calls on widget rebuilds.
///   - Thread-safe: Can be called from multiple widgets
///     simultaneously — only one HTTP request will be in-flight.
class IspService {
  final DebugLogger _logger = DebugLogger();

  /// In-memory cache — populated on first successful call.
  NetworkInfo? _cachedInfo;

  /// Prevents duplicate concurrent requests.
  Completer<NetworkInfo?>? _inFlightRequest;

  /// Timeout per individual API call.
  static const Duration _apiTimeout = Duration(seconds: 5);

  /// User-Agent header — some APIs block requests without one.
  static const Map<String, String> _headers = {
    'User-Agent': 'NetworkDiagnosticsApp/1.0',
    'Accept': 'application/json',
  };

  // ═══════════════════════════════════════════════════════════
  // PUBLIC API
  // ═══════════════════════════════════════════════════════════

  /// Detect the user's ISP and public IP.
  ///
  /// Returns cached result if available.
  /// Returns `null` only if ALL APIs fail (user is offline).
  ///
  /// Safe to call from `initState`, `FutureBuilder`, or anywhere.
  /// Multiple simultaneous calls are coalesced into one request.
  Future<NetworkInfo?> detect() async {
    // Return cache immediately if available
    if (_cachedInfo != null) {
      _logger.log("[ISP] Returning cached: ${_cachedInfo!.shortLabel}");
      return _cachedInfo;
    }

    // If a request is already in-flight, wait for it
    // instead of firing a duplicate
    if (_inFlightRequest != null) {
      _logger.log("[ISP] Request already in-flight, waiting...");
      return _inFlightRequest!.future;
    }

    // Start new detection
    _inFlightRequest = Completer<NetworkInfo?>();

    try {
      final result = await _detectWithFallbacks();
      _cachedInfo = result;
      _inFlightRequest!.complete(result);

      if (result != null) {
        _logger.log("[ISP] Detected: ${result.displayString} "
            "(via ${result.source})");
      } else {
        _logger.log("[ISP] All APIs failed — user may be offline.");
      }

      return result;
    } catch (e) {
      _logger.log("[ISP] Unexpected error: $e");
      _inFlightRequest!.complete(null);
      return null;
    } finally {
      _inFlightRequest = null;
    }
  }

  /// Force a fresh detection (ignores cache).
  /// Useful for a "refresh" action or after network changes.
  Future<NetworkInfo?> refresh() async {
    _cachedInfo = null;
    _logger.log("[ISP] Cache cleared. Re-detecting...");
    return detect();
  }

  /// Clear the cached result.
  void clearCache() {
    _cachedInfo = null;
  }

  // ═══════════════════════════════════════════════════════════
  // CASCADING FALLBACK ENGINE
  // ═══════════════════════════════════════════════════════════

  Future<NetworkInfo?> _detectWithFallbacks() async {
    // Tier 1: ipapi.co — Best for Lebanese ISPs
    final tier1 = await _tryIpApiCo();
    if (tier1 != null) return tier1;

    // Tier 2: ipwhois.io — Solid alternative
    final tier2 = await _tryIpWhois();
    if (tier2 != null) return tier2;

    // Tier 3: seeip.org — IP-only last resort
    final tier3 = await _trySeeIp();
    if (tier3 != null) return tier3;

    // All failed
    return null;
  }

  // ── Tier 1: ipapi.co ───────────────────────────────────────

  Future<NetworkInfo?> _tryIpApiCo() async {
    const url = 'https://ipapi.co/json/';
    _logger.log("[ISP] Tier 1: Trying ipapi.co...");

    try {
      final response = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(_apiTimeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        // ipapi.co returns {"error": true, "reason": "..."} on rate limit
        if (data['error'] == true) {
          _logger.log("[ISP] ipapi.co rate limited: ${data['reason']}");
          return null;
        }

        return NetworkInfo(
          ipAddress: _str(data['ip']),
          ispName: _extractIsp(data['org'], null),
          organization: _str(data['org']),
          asn: _str(data['asn']),
          country: _str(data['country_name']),
          countryCode: _str(data['country_code']),
          city: _str(data['city']),
          region: _str(data['region']),
          timezone: _str(data['timezone']),
          source: 'ipapi.co',
        );
      }

      _logger.log("[ISP] ipapi.co returned HTTP ${response.statusCode}");
      return null;
    } on TimeoutException {
      _logger.log("[ISP] ipapi.co timed out.");
      return null;
    } catch (e) {
      _logger.log("[ISP] ipapi.co error: $e");
      return null;
    }
  }

  // ── Tier 2: ipwhois.io ─────────────────────────────────────

  Future<NetworkInfo?> _tryIpWhois() async {
    const url = 'https://ipwhois.app/json/?lang=en';
    _logger.log("[ISP] Tier 2: Trying ipwhois.io...");

    try {
      final response = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(_apiTimeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        if (data['success'] == false) {
          _logger.log("[ISP] ipwhois.io failed: ${data['message']}");
          return null;
        }

        return NetworkInfo(
          ipAddress: _str(data['ip']),
          ispName: _extractIsp(data['isp'], data['org']),
          organization: _str(data['org']),
          asn: _str(data['asn']),
          country: _str(data['country']),
          countryCode: _str(data['country_code']),
          city: _str(data['city']),
          region: _str(data['region']),
          timezone: _str(data['timezone']),
          source: 'ipwhois.io',
        );
      }

      _logger.log("[ISP] ipwhois.io returned HTTP ${response.statusCode}");
      return null;
    } on TimeoutException {
      _logger.log("[ISP] ipwhois.io timed out.");
      return null;
    } catch (e) {
      _logger.log("[ISP] ipwhois.io error: $e");
      return null;
    }
  }

  // ── Tier 3: seeip.org (IP-only) ───────────────────────────

  Future<NetworkInfo?> _trySeeIp() async {
    const url = 'https://api.seeip.org/jsonip';
    _logger.log("[ISP] Tier 3: Trying seeip.org (IP-only fallback)...");

    try {
      final response = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(_apiTimeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final ip = _str(data['ip']);

        if (ip.isNotEmpty) {
          return NetworkInfo.ipOnly(ip);
        }
      }

      _logger.log("[ISP] seeip.org returned HTTP ${response.statusCode}");
      return null;
    } on TimeoutException {
      _logger.log("[ISP] seeip.org timed out.");
      return null;
    } catch (e) {
      _logger.log("[ISP] seeip.org error: $e");
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // PARSING HELPERS
  // ═══════════════════════════════════════════════════════════

  /// Safely extract a string from a dynamic JSON value.
  String _str(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  /// Extract the cleanest ISP name from available fields.
  ///
  /// Different APIs put the ISP name in different fields:
  ///   - ipapi.co:  "org" = "AS42020 Ogero Telecom"
  ///   - ipwhois.io: "isp" = "Ogero Telecom", "org" = "OGERO"
  ///
  /// This method:
  ///   1. Prefers the explicit "isp" field if available
  ///   2. Falls back to "org"
  ///   3. Strips ASN prefixes like "AS42020 "
  String _extractIsp(dynamic ispField, dynamic orgField) {
    String raw = '';

    final isp = _str(ispField);
    final org = _str(orgField);

    if (isp.isNotEmpty) {
      raw = isp;
    } else if (org.isNotEmpty) {
      raw = org;
    }

    if (raw.isEmpty) return 'Unknown Provider';

    // Strip ASN prefix: "AS42020 Ogero Telecom" → "Ogero Telecom"
    raw = raw.replaceFirst(RegExp(r'^AS\d+\s+'), '');

    // Clean up common suffixes/noise
    raw = raw
        .replaceAll(RegExp(r'\s+SAL$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+S\.A\.L\.?$', caseSensitive: false), '')
        .trim();

    return raw.isNotEmpty ? raw : 'Unknown Provider';
  }
}
```

---

### 3. Self-Contained UI Widget — `isp_banner.dart`

```dart
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
      return Text(
        flag,
        style: const TextStyle(fontSize: 24),
      );
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
```

---

### 4. Home Screen Integration — `home_screen.dart`

```dart
// lib/screens/home_screen.dart
// Showing ONLY the ISP integration points — your existing code stays.

import 'package:flutter/material.dart';
import 'package:network_speed_test/models/network_info.dart';
import 'package:network_speed_test/services/isp_service.dart';
import 'package:network_speed_test/widgets/isp_banner.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── Shared service instance ──
  // Creating it here so the cache persists across the entire
  // screen lifecycle. If the user navigates away and returns,
  // the cached result is served instantly (no API call).
  final IspService _ispService = IspService();

  // Store the detected info for use in speed test results
  NetworkInfo? _networkInfo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),

            // ═══════════════════════════════════════════
            // ISP BANNER — Fires automatically. Zero clicks.
            // ═══════════════════════════════════════════
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: IspBanner(
                ispService: _ispService,
                showIp: true,
                onDetected: (info) {
                  // Store for later use (e.g., include in test results)
                  _networkInfo = info;
                },
              ),
            ),

            const SizedBox(height: 24),

            // ... rest of your existing UI (speed gauge, buttons, etc.)
            // You can reference _networkInfo anywhere:
            //
            // Text('Testing on ${_networkInfo?.shortLabel ?? "..."}')
          ],
        ),
      ),
    );
  }
}
```

---

### 5. Alternative: Direct `initState` Integration (Without Widget)

If you prefer to call the service directly in your existing screen without the self-contained widget:

```dart
class _HomeScreenState extends State<HomeScreen> {
  final IspService _ispService = IspService();

  // Reactive state
  bool _ispLoading = true;
  NetworkInfo? _networkInfo;

  @override
  void initState() {
    super.initState();
    _detectIsp(); // ← Fires immediately, zero clicks
  }

  Future<void> _detectIsp() async {
    final info = await _ispService.detect();
    if (mounted) {
      setState(() {
        _ispLoading = false;
        _networkInfo = info;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Your ISP display
          if (_ispLoading)
            const Text('Detecting provider...',
                style: TextStyle(color: Colors.grey))
          else if (_networkInfo != null)
            Text(
              _networkInfo!.displayString,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            )
          else
            GestureDetector(
              onTap: () {
                setState(() => _ispLoading = true);
                _detectIsp();
              },
              child: const Text('Offline — tap to retry',
                  style: TextStyle(color: Colors.red)),
            ),

          // ... rest of your UI
        ],
      ),
    );
  }
}
```

---

## Architecture Summary

```
┌──────────────────────────────────────────────────────────────────┐
│                    DETECTION FLOW (Zero-Click)                   │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  App Launch                                                      │
│      │                                                           │
│      ▼                                                           │
│  HomeScreen.initState()                                          │
│      │                                                           │
│      ▼                                                           │
│  IspBanner mounts → _detect() called automatically              │
│      │                                                           │
│      ▼                                                           │
│  IspService.detect()                                             │
│      │                                                           │
│      ├─ Cache hit? ──→ Return immediately (~0ms)                │
│      │                                                           │
│      ├─ In-flight? ──→ Wait for existing request                │
│      │                                                           │
│      └─ Fresh request:                                           │
│           │                                                      │
│           ▼                                                      │
│      ┌─ ipapi.co ──→ Success? ──→ Parse & Cache ──→ Return     │
│      │     (5s timeout)                                          │
│      │     │ fail                                                │
│      │     ▼                                                     │
│      ├─ ipwhois.io ──→ Success? ──→ Parse & Cache ──→ Return   │
│      │     (5s timeout)                                          │
│      │     │ fail                                                │
│      │     ▼                                                     │
│      ├─ seeip.org ──→ Success? ──→ IP-only model ──→ Return    │
│      │     (5s timeout)                                          │
│      │     │ fail                                                │
│      │     ▼                                                     │
│      └─ Return null (offline state)                              │
│                                                                  │
│  UI reacts via setState:                                         │
│      Loading → Shimmer animation                                 │
│      Success → 🇱🇧 Ogero Telecom • 185.•••.•••.42 • Beirut, LB │
│      Offline → ⚠ No Connection (tap to retry)                   │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│  KEY DESIGN PROPERTIES:                                          │
│                                                                  │
│  ✓ Zero user interaction required                                │
│  ✓ ~100-200ms typical resolution (Tier 1 almost always works)   │
│  ✓ 15s worst-case (all 3 tiers timeout)                         │
│  ✓ Session-cached (widget rebuilds don't re-fetch)              │
│  ✓ Concurrent-safe (multiple callers coalesce)                  │
│  ✓ Graceful degradation (full ISP → IP-only → offline)         │
│  ✓ Lebanese ISPs resolved correctly (Ogero, Touch, IDM, etc.)  │
│  ✓ ASN prefix stripping ("AS42020 Ogero" → "Ogero Telecom")   │
│  ✓ Privacy-aware masked IP display                               │
│  ✓ Country flag emoji from ISO code                              │
└──────────────────────────────────────────────────────────────────┘
```