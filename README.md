# 🚀 Network Speed Test & ISP Shaping Detector

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white) 
![Dark Mode](https://img.shields.io/badge/UI-Dark%20Mode-black?style=for-the-badge)

A high-performance, professional-grade network diagnostic tool built with Flutter. Designed with a **SOC and Network Engineering mindset**, this project goes beyond generic speed tests. It features distinct testing engines built to expose **ISP Traffic Shaping**, **Local Caching policies**, and the real-world gap between "Marketing Speed" and actual single-thread throughput.

## 🔥 Key Features

### 1. **Marketing Speed Engine (Speedtest-like)** _Comparable to Speedtest.net_
* **Multi-Threaded Saturation**: Utilizes **8 parallel download workers** and **6 upload workers** to fully saturate the network bandwidth and bypass per-connection ISP throttling.
* **Progressive Ramp-Up**: Starts with 2 workers and scales up dynamically to measure the maximum potential throughput of the connection.
* **Smart Stabilization**: Implements **EMA (Exponential Moving Average)** smoothing for a stable, jitter-free gauge UI (updated every 150ms).
* **Accurate Upload**: Resolves "buffer bloat" issues by counting bytes only after server confirmation (HTTP 200), ensuring 100% accurate upload speed measurement without double-counting.
* **Precision Metrics**: Calculates **Jitter** based on standard deviation (RFC 3550) and measures latency using precise median values.

### 2. **Real Speed Engine (Traffic Shaping Detector)**
_Comparable to fast.com / Single-Threaded HTTP Downloads_
* **Single-Threaded Reality**: Uses a single, raw HTTP stream to international servers (e.g., OVH, Cloudflare) to simulate real-world usage scenarios (downloading a file, updating software).
* **Exposing Throttling**: Measures the actual speed a single application can achieve. While ISPs often whitelist multi-threaded tests to show high numbers, this engine reveals the strict bandwidth limits (Hard Caps) applied to standard international traffic.
* **Buffer Health**: Helps diagnose buffering issues by showing the sustainable speed for a single un-cached stream.

### 3. **Fast Engine (Netflix CDN)**
_Optimized for Content Delivery_
* **Netflix OCA Integration**: Targets Netflix Open Connect Appliances to measure streaming quality specifically from the nearest content delivery node.
* **Smart Worker Management**: Dynamically adjusts connection count based on latency to the content server.

### 4. **🕵️ Zero-Click ISP & ASN Detection (Passive Recon)**
* **Automatic Intelligence**: Automatically performs passive reconnaissance on launch to fetch the user's Public IP, ISP/Organization Name, and Autonomous System Number (ASN) seamlessly in the background.

---

## 🗺️ Roadmap (Upcoming Features)

* **Specific CDN Diagnostics:** Direct speed tests to Google Global Cache (GGC), Meta/Facebook Edge (FNA), and Akamai to map out local ISP caching rules.
* **Gaming Server Routing:** Ping and throughput tests to major gaming servers (Steam, PSN) to detect gaming-specific QoS throttling.

---

## 🛠️ Technical Highlights

* **Resource Isolation**: Each worker runs with its own isolated `http.Client` instance to prevent connection interference and ensure accurate measurements.
* **Memory Safety (Mobile Optimized)**: 
    * **Downloads**: Data is streamed directly from the network without buffering large files in RAM.
    * **Uploads**: Uses a shared, pre-allocated payload buffer (1MB chunks) to minimize garbage collection (GC) overhead and prevent OOM (Out-of-Memory) crashes during massive gigabit uploads.
* **Strict Timeouts**: Enforces hard 15-second limits per phase to violently close connections and prevent suspended or hung tests on unstable networks.
* **Global Server Network**: Automatically selects the optimal server based on **Ping** and **Jitter** metrics, prioritizing local low-latency servers for marketing tests.

---

## 📦 Installation & Build

This project is built with Flutter. To run it locally:

```bash
# 1. Clone the repository
git clone [https://github.com/Start-app-dev/network_speed_test.git](https://github.com/Start-app-dev/network_speed_test.git)

# 2. Install dependencies
flutter pub get

# 3. Run the app
flutter run
Build for Android (APK)
Bash
# Clean build
flutter clean
flutter pub get

# Generate Release APK
flutter build apk --release
The APK will be located at:

build/app/outputs/flutter-apk/app-release.apk

🤝 Contributing
Contributions are welcome! Please fork the repository and submit a pull request for any enhancements, bug fixes, or new features.

Developed with ❤️ by AliTf