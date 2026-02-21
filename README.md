# 🚀 Real Test 

![Version](https://img.shields.io/badge/version-1.0.0-success.svg)
![Flutter](https://img.shields.io/badge/Flutter-Ready-blue.svg)
![Architecture](https://img.shields.io/badge/Architecture-Universal_Orchestrator-orange.svg)

**Real Test** is a professional-grade network diagnostic and speed-testing application built with Flutter. 

Unlike standard speed tests that measure against a single favorable local peer, Real Test probes **7 distinct engines and Global CDNs** to expose ISP traffic shaping, identify local edge-cache configurations, and measure your true unthrottled international bandwidth.

## 🌟 Why Real Test? (The ISP Traffic Shaping Exposer)
ISPs often use Deep Packet Inspection (DPI) to throttle standard downloads while fully unblocking specific media streams (like YouTube or Steam). 
Real Test utilizes dynamic URL extraction, raw socket testing, and streaming protocol simulations to benchmark your connection against specific real-world use cases, revealing exactly *how* your ISP treats different types of traffic.

## 🛠️ Supported Testing Engines
1. **Real Speed (International):** Measures raw, uncached international backbone throughput.
2. **Google Global Cache (GGC):** Simulates 4K YouTube streaming vs. static Google Drive downloads to detect protocol-specific throttling.
3. **Akamai Edge:** Targets massive local caches (like Steam and Apple updates) to find your absolute maximum line rate.
4. **Facebook CDN (FNA):** Tests Meta's localized edge node performance.
5. **Fast.com (Netflix):** Measures streaming-optimized delivery.
6. **Ookla:** Standard multi-thread regional peer testing.
7. **Cloudflare:** Anycast routing and general infrastructure speed.

## 🏗️ Architectural Highlights
This application is built with a highly optimized, custom multi-threading architecture:
* **Universal Orchestrator:** A centralized controller that manages phase transitions natively, eliminating memory leaks and blocked `while` loops.
* **SmoothSpeedMeter:** A custom 3-layer ring buffer with an adaptive Exponential Moving Average (EMA) algorithm for highly precise, human-readable UI updates without thread-locking.
* **Zero-Deadlock Cancellation:** Implements forced socket destruction (`client.close(force: true)`) ensuring instant test termination across all parallel workers.
* **Incompressible Payloads:** Generates real-time pseudo-random bytes to defeat transparent ISP data compression during upload phases.

## 🔒 Privacy First
All test results, including local network names (SSID) and node IPs, are saved strictly locally on the device for historical comparison. Real Test does not collect or transmit your testing data to any external server.

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.0+)
- Dart SDK

### Installation
1. Clone the repository:
   ```bash
   git clone [https://github.com/Ali-tf/network_real_test.git](https://github.com/Ali-tf/network_real_test.git)
