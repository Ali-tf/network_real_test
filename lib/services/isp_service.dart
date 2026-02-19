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
        _logger.log(
          "[ISP] Detected: ${result.displayString} "
          "(via ${result.source})",
        );
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
