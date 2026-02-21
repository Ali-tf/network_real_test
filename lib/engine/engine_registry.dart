import 'package:flutter/material.dart';
import 'package:network_speed_test/engine/speed_test_engine.dart';
import 'package:network_speed_test/engine/cloudflare_engine.dart';
import 'package:network_speed_test/engine/real_speed_engine.dart';
import 'package:network_speed_test/engine/fast_engine.dart';
import 'package:network_speed_test/engine/ookla_engine.dart';
import 'package:network_speed_test/engine/facebook_cdn_engine.dart';
import 'package:network_speed_test/engine/akamai_engine.dart';
import 'package:network_speed_test/engine/google_ggc_engine.dart';

/// Static registry of all available speed test engines.
///
/// Each entry contains the UI metadata (title, icon, color, subtitle)
/// and a factory function to instantiate the engine. This replaces the
/// 7 inline tile definitions, `_getTestName()`, and `_getTestColor()`
/// that were previously spread across main.dart.
class EngineEntry {
  final int id;
  final String title;
  final IconData icon;
  final Color color;
  final SpeedTestEngine Function() factory;
  final List<StickerDef>? stickers;

  const EngineEntry({
    required this.id,
    required this.title,
    required this.icon,
    required this.color,
    required this.factory,
    this.stickers,
  });
}

/// Defines a small badge/sticker shown below engine names (e.g. "YouTube", "Steam").
class StickerDef {
  final IconData icon;
  final String label;
  final Color color;
  const StickerDef(this.icon, this.label, this.color);
}

class EngineRegistry {
  EngineRegistry._();

  static final List<EngineEntry> engines = [
    EngineEntry(
      id: 1,
      title: 'Real speed',
      icon: Icons.speed,
      color: Colors.cyan,
      factory: RealSpeedEngine.new,
    ),
    EngineEntry(
      id: 2,
      title: 'Fast',
      icon: Icons.movie_filter,
      color: Colors.green,
      factory: FastEngine.new,
    ),
    EngineEntry(
      id: 3,
      title: 'Speedtest by Ookla',
      icon: Icons.network_check,
      color: Colors.orange,
      factory: OoklaEngine.new,
    ),
    EngineEntry(
      id: 4,
      title: 'Cloudflare Speedtest',
      icon: Icons.cloud_queue,
      color: Colors.purple,
      factory: CloudflareEngine.new,
    ),
    EngineEntry(
      id: 5,
      title: 'Facebook CDN (FNA)',
      icon: Icons.facebook,
      color: Colors.blueAccent,
      factory: FacebookCdnEngine.new,
      stickers: const [
        StickerDef(Icons.camera_alt, 'Instagram', Colors.pinkAccent),
        StickerDef(Icons.chat, 'WhatsApp', Colors.greenAccent),
      ],
    ),
    EngineEntry(
      id: 6,
      title: 'Akamai Edge-Cache',
      icon: Icons.cloud_download,
      color: Colors.red,
      factory: AkamaiEngine.new,
      stickers: const [
        StickerDef(Icons.games, 'Steam', Colors.indigoAccent),
        StickerDef(Icons.apple, 'Apple', Colors.grey),
        StickerDef(Icons.picture_as_pdf, 'Adobe', Colors.redAccent),
      ],
    ),
    EngineEntry(
      id: 7,
      title: 'Google Global Cache',
      icon: Icons.g_mobiledata,
      color: Colors.greenAccent,
      factory: GoogleGgcEngine.new,
      stickers: const [
        StickerDef(Icons.play_circle_filled, 'YouTube', Colors.red),
        StickerDef(Icons.android, 'Play Store', Colors.green),
        StickerDef(Icons.storage, 'Cloud', Colors.blue),
      ],
    ),
  ];

  /// Lookup an engine entry by id.
  static EngineEntry? byId(int id) {
    for (final e in engines) {
      if (e.id == id) return e;
    }
    return null;
  }
}
