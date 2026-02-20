Thought for 1 second

Looking at your code, I can identify the exact root causes of both issues:

Issue 1: The Dash
The sentinel value uploadMbps: -1.0 is used everywhere during the download phase. Your UI layer interprets negative values as "not started" and renders a dash. Fix: Change all uploadMbps: -1.0 → uploadMbps: 0.0 (6 locations: the default constructor value + 5 explicit emissions).

Issue 2: Erratic Upload Meter
The _SpeedWindow (sliding window over 500ms) reacts to bursty socket buffer flushes — counter.add(slice.length) fires in 16KB bursts as _socket.flush() completes, which is instant when the buffer isn't full, then stalls when it is. This creates wildly uneven intervals between samples.

Fix: Replace the sliding window with a cumulative average: liveMbps = (counter.bytes * 8.0) / elapsedMicroseconds. This converges smoothly and is immune to burst timing. (This is the same formula _computeFinal already uses.)

Let me create the fixed file:


Created lib/services/facebook_cdn_service.dart
Done. Here's a summary of exactly what changed in v12.1:

Fix 1: The Dash → 0.00
Root cause: uploadMbps defaulted to -1.0 (a sentinel value your UI interprets as "not started yet" → shows —).

Changes made (6 locations):

FacebookCdnResult constructor default: this.uploadMbps = -1.0 → this.uploadMbps = 0.0
All 5 explicit uploadMbps: -1.0 emissions in _runTest and _runDownloadPhase → uploadMbps: 0.0
Now the UI will show 0.00 during discovery, probing, and the entire download phase — exactly like other tests.

Fix 2: Erratic Upload Meter → Smooth Cumulative Average
Root cause: The _SpeedWindow sliding window (500ms) was measuring instantaneous socket buffer throughput. When _socket.flush() completes instantly (buffer not full), the counter jumps by 16KB in microseconds → spike to 40+ Mbps. When the buffer stalls (waiting for ACKs), the window sees zero new bytes → drops to 0. This creates the wild 0→20→40→61→0 pattern.

Fix: Replaced the sliding window with a cumulative average in the upload monitor:

dart

final elapsedUs = DateTime.now().microsecondsSinceEpoch - startUs;
final liveMbps = (counter.bytes * 8.0) / elapsedUs;
Why this works:

Uses totalBytesSentSoFar / totalElapsedTime — immune to burst timing
Converges smoothly toward the true speed as data accumulates
Identical formula to _computeFinal(), so the live meter converges toward the final result
Removed the unused _SpeedWindow instantiation from the upload phase
What was NOT changed: Download still uses _SpeedWindow (it works fine there because incoming network data arrives steadily, unlike outgoing socket buffer writes).