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
