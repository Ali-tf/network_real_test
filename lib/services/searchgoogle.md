

# Google Global Cache (GGC) Speed Test Engine: Architectural Blueprint

---

## 0. Core Philosophy: Why Google Is a Different Beast

Akamai is third-party infrastructure your code had to *discover* via CNAME chains. Google is vertically integrated: Google controls the content, the DNS, the cache software, the physical servers inside ISPs, and even the protocol layer (QUIC). The consequence: **discovery works through HTTP redirects, not CNAME introspection. Google tells you exactly which cache node to use — you just have to listen.**

The Google Global Cache (GGC) is a physical server installed by Google *inside* the ISP's own datacenter. Traffic to it never leaves the ISP's network. When a GGC node exists, DNS for Google download/video domains resolves to an IP that is topologically zero or one hop from the user. When no GGC exists, traffic goes to the nearest Google Edge PoP at an Internet Exchange Point. Either way, DNS + redirect = discovery. Your code doesn't need to scrape anything.

---

## 1. Target Discovery & Reliable Cache Hits

### 1A. The Two-Stage Resolution: DNS + HTTP 302

Unlike Akamai (where DNS alone gives you the edge IP), Google uses a **two-stage** resolution for its download infrastructure:

```
STAGE 1 — DNS:
  dl.google.com
    → A record(s) pointing to Google Front Ends (GFEs)
    → These are Anycast IPs in AS15169
    → The GFE is NOT the cache. It's a load-balancing proxy.

STAGE 2 — HTTP Redirect:
  GET /linux/direct/google-chrome-stable_current_amd64.deb HTTP/1.1
  Host: dl.google.com
  
  Response:
  HTTP/1.1 302 Found
  Location: https://r5---sn-ab5sznlk.gvt1.com/edgedl/linux/direct/google-chrome-stable_current_amd64.deb
  
  ↑ THIS is your cache node.
  
  r5          → server instance 5 within the node
  sn-ab5sznlk → location identifier (the serving-node code)
  gvt1.com    → Google Video Transcoder 1 (legacy name; now serves
                all cached downloads, not just video)
```

**The `sn-` code is the gold.** It uniquely identifies the cache cluster. If it's a GGC inside the ISP, the `sn-` code maps to that ISP's deployment. If it's a Google PoP at an IXP, the code maps to that metro. Your test should log this code as provenance metadata.

**Critical rule (same as Akamai)**: Use the **system default DNS resolver**. Google's GFE Anycast routing considers the resolver's source IP for geographic affinity. Using `8.8.8.8` or `1.1.1.1` may paradoxically *bypass* the local GGC node because Google's public DNS resolvers identify themselves differently in ECS (EDNS Client Subnet) than the ISP's own resolvers do.

### 1B. The Probe URL Catalog

Your Facebook CDN engine suffered because you had to scrape for URLs. Your Akamai engine improved by using a curated catalog of third-party customer assets. For Google, it's even cleaner: **every URL is a first-party Google asset, controlled by Google, hosted on Google infrastructure.**

**Tier 1 — Primary Candidates (Evergreen URLs)**

These are "latest" URLs that always point to the current version. They never 404. They are large. They are globally cached.

| URL Path (on `dl.google.com`) | Approx Size | Why It's Ideal |
|-------------------------------|-------------|----------------|
| `/linux/direct/google-chrome-stable_current_amd64.deb` | ~100 MB | Updated every 2-4 weeks. Between updates, aggressively cached on every GGC worldwide. Supports `Range`. |
| `/dl/cloudsdk/channels/rapid/google-cloud-cli-linux-x86_64.tar.gz` | ~55 MB | Google Cloud CLI. Updated frequently but cached. Large enough for sustained testing. |
| `/android/repository/platform-tools-latest-linux.zip` | ~15 MB | Android platform tools. Small but always available. Good for fallback/validation. |
| `/dl/android/studio/ide-zips/{version}/android-studio-{version}-linux.tar.gz` | ~1 GB | Extremely large. Overkill for most tests, but ideal for 10Gbps connections. Version-specific (not evergreen). |

**Tier 2 — Additional Google Domains**

| Domain | Use Case | Notes |
|--------|----------|-------|
| `edgedl.me.gvt1.com` | Direct edge download. Sometimes the redirect target. | Resolves to cache node IP directly. |
| `redirector.gvt1.com` | Explicit redirector service. | Returns 302 to nearest `r{N}---sn-{code}.gvt1.com`. |
| `storage.googleapis.com/{public-bucket}` | Google Cloud Storage public objects. | Served via Google's edge but may not use GGC. Good fallback. |
| `dl.google.com/dl/earth/client/advanced/current/googleearthprowin-{ver}.exe` | Google Earth Pro. | ~50 MB. Less frequently updated = warmer cache. |

**Tier 3 — Self-Hosted GCS Bucket (Nuclear Fallback)**

Upload a 100 MB static file to a public Google Cloud Storage bucket in multi-region. Set `Cache-Control: public, max-age=604800`. GCS objects served via `storage.googleapis.com` go through Google's edge network. You control the URL, the caching policy, and the availability. Cost: pennies per month for a speed test payload.

### 1C. The Runtime Discovery Protocol

```
DISCOVERY PROTOCOL (runs during TestLifecycle.init):

1. Select primary probe URL from Tier 1 catalog
   Default: dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

2. Send GET request to probe URL with redirect following DISABLED
   (In Dart: HttpClient.autoRedirect = false)
   
   ├── Expect: HTTP 302
   ├── Extract: Location header → this is the gvt1.com cache URL
   │     Parse: hostname → extract {sn-code} as nodeLocationId
   │     Parse: full URL → this is your testTargetUrl
   │
   ├── IF no 302 (direct 200 response):
   │     The GFE served it directly (rare, happens for small files)
   │     Use the original dl.google.com URL as testTargetUrl
   │     The GFE IP is your edge target
   │
   └── IF HTTP error (403, 404, 5xx):
         Try next candidate from catalog
         After exhausting Tier 1, try Tier 2, then Tier 3

3. DNS-resolve the gvt1.com hostname from the redirect URL
   ├── Record IP address(es) → this is the cache node IP
   ├── Attempt reverse DNS lookup on the IP
   │     GGC nodes sometimes resolve to: 
   │       *.1e100.net (Google's reverse DNS domain)
   │       or simply have no PTR record
   └── Record: { cacheIp, cacheHostname, nodeLocationId }

4. Validate the cache URL with a HEAD request:
   HEAD {testTargetUrl} HTTP/1.1
   Host: r5---sn-ab5sznlk.gvt1.com
   
   Check:
   ├── HTTP 200 (confirms file exists and is accessible)
   ├── Accept-Ranges: bytes (confirms Range requests work)
   ├── Content-Length >= minimum threshold (e.g., 10 MB)
   ├── Age header present AND > 0 (confirms served from cache)
   │     Age: 0 or absent → possibly cold cache; fire warming request
   ├── Server header (typically "downloads" for gvt1.com)
   └── Record RTT of this HEAD request

5. IF Age == 0 or Age header absent (cold cache):
   Fire a warming GET: Range: bytes=0-1048575 (first 1 MB)
   Wait for completion
   Re-send HEAD → verify Age > 0 now

6. GGC vs Edge PoP classification (informational, not blocking):
   ├── IF RTT < 5ms → likely GGC (inside ISP network)
   ├── IF RTT 5-20ms → likely Google Edge PoP (nearby IXP)
   ├── IF RTT > 20ms → likely regional Google datacenter (no local cache)
   └── Store as metadata: { cacheType: "ggc" | "edge_pop" | "datacenter" }

OUTPUT: {
  testTargetUrl:  "https://r5---sn-ab5sznlk.gvt1.com/edgedl/linux/direct/...",
  cacheIp:        "74.125.xxx.xxx",
  nodeLocationId: "sn-ab5sznlk",
  cacheType:      "ggc",
  contentLength:  104857600,
  baseRtt:        2.4,
  ageSeconds:     14523
}
```

### 1D. Why the 302 Redirect Is Actually Better Than CNAME Discovery

With Akamai, you inspected DNS CNAME chains to find the edge. This was indirect — you inferred the edge from DNS metadata. With Google, the HTTP redirect is an **explicit instruction** from Google's infrastructure telling you: *"Download from this specific cache node."* It accounts for:

- Real-time load across cache nodes (not just DNS TTL-based)
- Content availability (the redirect only goes to a node that **has** the file)
- Network topology awareness at the application layer (not just DNS)

This means your test URL is **guaranteed to produce a cache hit** on the first request (assuming the file hasn't been evicted between the redirect and your test, which is extremely unlikely for popular assets within a ~30 second window).

### 1E. Anti-Rate-Limiting Measures

Google's download infrastructure is designed to serve billions of software updates. It's far more tolerant of parallel downloads than Akamai's customer-configured WAFs. But you should still be a good citizen:

| Technique | Rationale |
|-----------|-----------|
| Realistic `User-Agent` (Chrome on the user's actual platform) | Google's GFEs log and filter on UA |
| **4-6 parallel workers** (conservative) | Google may throttle per-IP concurrency beyond 6-10 connections to a single cache node |
| Use the **exact redirect URL** without modification | Adding random query params may change cache key → cache miss → origin fetch |
| Respect `Range` boundaries (don't request beyond `Content-Length`) | Avoids triggering 416 Range Not Satisfiable errors which may be logged as anomalies |
| Total test data cap: **~300-500 MB** | Enough for accurate measurement on gigabit; avoids any abuse detection |
| **Do NOT repeatedly re-fetch the 302 redirect** | The redirect itself is rate-limited. Fetch once, reuse the resulting URL for all workers. |
| Stagger worker start by 100-200ms | Prevents SYN burst that could trigger DDoS detection at the GFE |

---

## 2. Download Strategy: GGC Cache Hits Without Local Cache

### 2A. The Three-Layer Cache Problem

Google adds a layer compared to Akamai:

```
[Google Origin (Cloud Storage / Colossus)]
       ↓
[Google Core Datacenter Cache]   ← NOT what we want
       ↓
[GGC / Edge PoP Cache]          ← THIS is what we measure
       ↓
[OS / Runtime HTTP Cache]       ← BYPASS this
       ↓
[Your App]
```

**Layer 1 (GGC Cache)**: Maximum cache hits. Strategy: use the **exact `gvt1.com` URL** returned by the redirect. No query string modifications. No host header tricks. The cache key on GGC is `{url_path}` (and possibly some headers). Identical requests = cache hits.

**Layer 2 (Local/OS Cache)**: Zero interference. Strategy:

```
Per-HttpClient configuration:
  - Fresh HttpClient instance per phase (your existing pattern)
  - Set request headers:
      Accept-Encoding: identity
        → Forces uncompressed transfer
        → Google's cache will serve the raw file, not gzip'd
        → Bytes on wire = bytes counted = accurate throughput
      
      Cache-Control: no-store
        → Tells any intermediate proxy (corporate, ISP transparent 
           proxy) NOT to cache the response locally
        → Does NOT affect GGC's serving behavior (GGC ignores 
           client Cache-Control for cached objects)
      
  - Do NOT send If-Modified-Since or If-None-Match
      → Prevents 304 Not Modified (zero-byte transfer)
      
  - Stream response via onData listener → count and discard
      → Never buffer full response in memory
      → Each data chunk: bytesReceived += chunk.length
```

**Why `Accept-Encoding: identity` is especially critical for Google:**

Google's infrastructure aggressively applies `gzip` and `br` (Brotli) compression. If you accept compressed encoding, the GGC might serve a compressed stream. Your `Content-Length` header will show the uncompressed size, but the bytes on wire will be smaller (compressed). Your throughput formula `bytes / time` becomes meaningless. With `identity`, what you measure is what actually crossed the wire.

### 2B. Range Request Architecture

The `gvt1.com` cache endpoints support `Accept-Ranges: bytes`. We use this to create a controlled, repeatable, infinitely sustainable download stream:

```
RANGE STRATEGY:

File: 100 MB Google Chrome .deb on GGC (Content-Length: 104857600)

Chunk Assignment (offset-based, not interleaved):
  Worker 0: byte 0          → byte 4,194,303     (chunk 0)
  Worker 1: byte 4,194,304  → byte 8,388,607     (chunk 1)
  Worker 2: byte 8,388,608  → byte 12,582,911    (chunk 2)
  Worker 3: byte 12,582,912 → byte 16,777,215    (chunk 3)
  Worker 4: byte 16,777,216 → byte 20,971,519    (chunk 4)
  Worker 5: byte 20,971,520 → byte 25,165,823    (chunk 5)

Sequential advancement:
  When Worker 0 completes chunk 0:
    → Starts chunk 6 (byte 25,165,824 → 29,360,127)
  When Worker 0 completes chunk 6:
    → Starts chunk 12 (next unassigned)
  ...
  When all chunks exhausted (byte 104,857,599 reached):
    → Wrap to byte 0 and restart
    → GGC doesn't care — same cache hit every time

Global chunk counter (atomic):
  nextChunkIndex = 0 (shared across workers)
  Worker requests: offset = atomicIncrement(nextChunkIndex) * chunkSize
  When offset >= contentLength: offset = offset % contentLength
```

**Adaptive Chunk Sizing (Per-Worker):**

```
Connection speed estimation:
  After each completed chunk, compute:
    chunkDuration = endTime - startTime
  
  Sizing rules:
    chunkDuration < 300ms  → double chunk size (up to 16 MB max)
    chunkDuration > 8s     → halve chunk size (down to 256 KB min)
    otherwise              → keep current size
  
  Initial ramp-up schedule:
    Request 1:  256 KB   (probe — validates Range support, measures baseline)
    Request 2:  1 MB
    Request 3:  4 MB     (standard sustained size)
    Request 4+: adaptive based on above rules

WHY ADAPTIVE MATTERS FOR GOOGLE SPECIFICALLY:
  Google's download servers apply per-connection TCP pacing.
  A single connection rarely exceeds ~50 Mbps even on a fast link.
  Throughput scales with PARALLEL connections, not bigger chunks.
  So chunk size should be "large enough to amortize HTTP overhead"
  but not so large that a single chunk dominates one worker's time.
  4 MB is the sweet spot for most connections.
```

**Request construction per worker:**

```
GET /edgedl/linux/direct/google-chrome-stable_current_amd64.deb HTTP/1.1
Host: r5---sn-ab5sznlk.gvt1.com
Range: bytes=4194304-8388607
Accept-Encoding: identity
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ...
Connection: keep-alive

Expected response:
HTTP/1.1 206 Partial Content
Content-Range: bytes 4194304-8388607/104857600
Content-Length: 4194304
Age: 14523
Server: downloads
```

### 2C. Google-Specific Download Consideration: TCP Pacing

Google's infrastructure implements **TCP-level bandwidth pacing** (BBR congestion control on their servers). This means:

- A single TCP connection to a GGC node is often limited to ~30-80 Mbps regardless of available bandwidth
- This is **intentional** — Google paces downloads to avoid TCP buffer bloat and to be fair to other traffic
- To saturate a fast connection, you **need** multiple parallel connections

This is why **6 workers is the minimum recommendation for download.** On a 500 Mbps connection, you need 6-8 connections each running at ~60-80 Mbps to approach saturation. On a gigabit connection, you might need 10-12, but going beyond 8 risks triggering Google's per-IP concurrency limits.

```
WORKER SCALING HEURISTIC:

After the first 3 seconds of the test (warm-up period):
  measuredAggregate = sum of all worker throughputs
  perWorkerAvg = measuredAggregate / activeWorkers
  
  IF perWorkerAvg < 5 Mbps AND activeWorkers < 8:
    → Connection is slow; adding workers won't help (bottleneck is last-mile)
    → Do NOT add workers
  
  IF perWorkerAvg > 40 Mbps AND activeWorkers < 8:
    → Each worker is being paced; more workers would help
    → Spawn 2 additional workers (up to max 8)
  
  IF perWorkerAvg > 60 Mbps AND activeWorkers == 8:
    → Very fast connection; consider spawning up to 10
    → But log a warning: risk of rate limiting
```

### 2D. Download Phase Throughput Calculation

```
Per-worker, per-chunk measurement:
  startTime = highResolutionTimestamp()  // microsecond precision
  bytesReceived = 0
  
  response.stream.listen((chunk) {
    bytesReceived += chunk.length
    // Discard chunk data immediately (don't accumulate in memory)
  }, onDone: () {
    elapsed = highResolutionTimestamp() - startTime
    chunkBytesPerSec = bytesReceived / elapsed
    reportSample(workerId, chunkBytesPerSec, timestamp)
  })

Global aggregation (every 250ms tick):
  1. For each active worker, take its most recent sample
  2. Sum all worker samples → instantaneousThroughput
  3. Feed into EMA smoother:
       ema = α * instantaneousThroughput + (1 - α) * previousEma
       (your existing model, α = 0.3)
  4. IF testElapsed < 3.0 seconds → discard sample (warm-up)
  5. IF testElapsed >= 3.0 seconds → accumulate into final curve

Test termination:
  WHEN testElapsed >= 15.0 seconds:
    → Stop all workers (cancel pending requests)
    → finalDownloadMbps = last EMA value
    → Record full sample curve for UI rendering

Jitter in download (optional, advanced):
  Compute standard deviation of per-250ms throughput samples
  after warm-up period. This indicates connection stability.
```

---

## 3. Upload Strategy: The Google Challenge

### 3A. The Fundamental Problem (Similar to Akamai, but Different)

GGC nodes are **read-only caches**. They serve `GET` and `HEAD`. They do not have writable storage for arbitrary uploads. `POST` and `PUT` to a `gvt1.com` cache URL returns `405 Method Not Allowed` (if even routed).

However, Google's *broader* edge infrastructure (GFEs — Google Front Ends) handles all incoming traffic for `*.google.com`, `*.googleapis.com`, etc. GFEs **do** accept `POST` for many services. The key insight:

> **GFEs and GGC nodes are often on the same machine or in the same rack inside the ISP.** A POST to `www.google.com` hits the local GFE, which is co-located with the GGC. The upload path to the GFE measures the same last-mile pipe.

### 3B. Tiered Upload Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   UPLOAD STRATEGY                         │
│                                                           │
│  Tier 1: POST to Google GFE Endpoints (Best Case)        │
│     ↓ fails or body rejected                              │
│  Tier 2: TCP Write Measurement to GGC/GFE IP (Fallback)  │
│     ↓ connection reset too early                          │
│  Tier 3: Cross-Engine Cloudflare Fallback (Guaranteed)    │
│     ↓ unavailable                                         │
│  Tier 4: Upload Skipped — Download-Only Result            │
└──────────────────────────────────────────────────────────┘
```

**Tier 1: POST to Google GFE Beacon/Telemetry Endpoints**

Several Google endpoints accept `POST` requests without authentication. These are served by the same GFEs that front the GGC:

| Endpoint | Behavior | Body Limit | Notes |
|----------|----------|-----------|-------|
| `www.google.com/gen_204` | Returns `204 No Content`. Used as telemetry beacon by Chrome, Android. | Accepts body up to ~1 MB before GFE may close | Most reliable. GFE reads and discards body. |
| `clients1.google.com/generate_204` | Same 204 pattern. Used by Android connectivity checks. | Similar ~1 MB | Alternative if `www.google.com` is blocked. |
| `connectivitycheck.gstatic.com/generate_204` | Android captive portal detection. | Small body only | Primarily useful for latency, not upload throughput. |
| `play.googleapis.com/log` | Google Play telemetry. Accepts POST with JSON body. | Potentially larger | May require specific Content-Type. |
| `www.google.com/async/newtab_ogb` | Internal Google async endpoint. | Unknown | Less documented, less stable. |

**Tier 1 upload architecture:**

```
STRATEGY:
  Use multiple parallel POST requests to /gen_204 endpoints.
  Each POST carries a body of random bytes.
  
  The measurement is: how fast can we push bytes TO the GFE?
  The response (204, tiny) is irrelevant — we only time the request phase.

WORKERS:
  6 parallel upload workers, each in a loop:
  
  while (testTimer.isRunning) {
    POST /gen_204 HTTP/1.1
    Host: www.google.com
    Content-Type: application/octet-stream
    Content-Length: {chunkSize}    // start at 128 KB, ramp to 512 KB
    User-Agent: {realistic Chrome UA}
    Connection: keep-alive
    
    Body: [random bytes of chunkSize]
    
    startTime = now()
    send full request (headers + body)
    await response (should be 204)
    elapsed = now() - startTime
    
    // We know the GFE read the entire body because it sent a response
    uploadThroughput = chunkSize / elapsed
    reportSample(uploadThroughput)
  }

CHUNK SIZE CONSTRAINT:
  Google GFEs enforce request body size limits per endpoint.
  /gen_204 typically allows up to ~1 MB.
  Keep chunks at 256 KB - 512 KB for safety.
  
  This means more HTTP overhead per byte transferred compared to
  Cloudflare's /__up (which accepts multi-MB POSTs).
  Compensate with more parallel workers.

FAILURE MODES:
  HTTP 413 Payload Too Large → reduce chunk size by half, retry
  HTTP 403 Forbidden → switch to alternative endpoint
  HTTP 405 Method Not Allowed → endpoint doesn't accept POST; try next
  Connection reset → back off, try once more, then fall to Tier 2
```

**Why this is a real measurement of upload to the Google edge:**

The request body bytes travel from your app → through the OS TCP stack → across the last-mile link → through the ISP network → to the GFE. The GFE is typically co-located with the GGC inside the ISP (or at the nearest IXP). The bottleneck is the user's uplink, which is exactly what we want to measure.

**Tier 2: TCP Write Measurement to GGC/Edge IP**

Same concept as your Akamai engine. Use the GGC/GFE IP resolved during discovery:

```
MECHANISM:
  1. Open SecureSocket to cacheIp:443 (the gvt1.com IP from discovery)
     OR to the resolved IP of www.google.com (GFE IP)
  
  2. Send HTTP headers manually:
       POST / HTTP/1.1\r\n
       Host: www.google.com\r\n
       Content-Type: application/octet-stream\r\n
       Content-Length: 67108864\r\n    ← claim 64 MB
       \r\n
  
  3. Begin writing random bytes to the socket
  4. Measure: bytes accepted by TCP send buffer (ACKed by peer)
  5. Continue until:
     a. Server sends RST or FIN → connection closed
     b. Socket.add() throws → write error
     c. Test timer expires (15 seconds)
  
  6. Throughput = bytes successfully written / elapsed

GOOGLE-SPECIFIC NUANCE:
  Google GFEs are more tolerant of large POST bodies than Akamai
  edges (which often RST immediately). A GFE will typically:
  - Read the headers
  - Begin accepting the body
  - After 1-10 MB (depending on endpoint config), send an HTTP error
    response BUT keep the connection open briefly
  - Eventually close the connection
  
  You often get 3-8 seconds of sustained upload before disconnection.
  This is enough for a meaningful measurement if combined with EMA
  smoothing and warm-up discard.
  
  Use the GFE IP (www.google.com resolution) rather than the gvt1.com
  IP for Tier 2. GFEs are HTTP-aware proxies; gvt1.com nodes may be
  pure cache appliances that RST non-GET requests at the TCP level.
```

**Tier 3: Cloudflare Cross-Engine Fallback**

```
Identical to your Akamai engine's Tier 3:
  - Reuse CloudflareUploadWorker from your CF engine
  - POST to speed.cloudflare.com/__up
  - Tag result: { uploadSource: "cloudflare-fallback" }
  
JUSTIFICATION (same as Akamai):
  - The upload bottleneck is the user's last-mile uplink
  - Cloudflare and Google edge nodes are often at the same IXP
  - Upload to Cloudflare ≈ Upload to Google edge (within margin of error)
  - Your CF engine's upload is battle-tested
```

### 3C. Recommended Upload Wiring

```
uploadPhase():
  // Try Tier 1 first (POST to /gen_204)
  try Tier 1:
    Run 6 workers, POST 512 KB chunks to www.google.com/gen_204
    IF successful responses received AND test duration >= 5 seconds:
      → Use this result. Tag: { uploadSource: "google-gfe" }
    ELSE IF receiving 413/403/405 consistently:
      → Fall through to Tier 2

  catch/fallthrough → try Tier 2:
    TCP write to GFE IP (www.google.com resolved IP)
    IF bytes written > 2 MB AND duration > 3 seconds:
      → Use this result. Tag: { uploadSource: "google-tcp-write" }
    ELSE:
      → Fall through to Tier 3

  catch/fallthrough → Tier 3:
    Cloudflare fallback
    Tag: { uploadSource: "cloudflare-fallback" }
```

**Why Tier 1 is viable for Google but wasn't for Akamai:**

Akamai edges are configured per-customer. A static content delivery property has no reason to accept POST, so the edge rejects it immediately. Google's GFEs, by contrast, are multi-service proxies — they front Search, Maps, YouTube, Gmail, Play, and dozens of other services on the same IP. They *must* accept POST because many of those services need it. The `/gen_204` endpoint specifically exists as a lightweight POST target. This makes Tier 1 far more reliable for Google than any equivalent was for Akamai.

---

## 4. Integration with TestLifecycle

```
class GoogleGgcTestEngine implements TestEngine {

  // ═══════════════════════════════════════════════════
  // PHASE 0: INITIALIZATION    (TestLifecycle.init)
  // ═══════════════════════════════════════════════════
  
  GoogleCacheDiscovery:
    ├── Load probe URL catalog (embedded, Tier 1 URLs)
    ├── GET probe URL with autoRedirect = false
    │     ├── Extract 302 Location → gvt1.com cache URL
    │     ├── Parse sn-{code} → nodeLocationId
    │     └── Parse full URL → testTargetUrl
    ├── DNS resolve gvt1.com hostname → cacheIp
    ├── DNS resolve www.google.com → gfeIp (for upload)
    ├── HEAD testTargetUrl → validate:
    │     ├── HTTP 200, Accept-Ranges: bytes
    │     ├── Content-Length >= threshold
    │     ├── Age > 0 (cached)
    │     └── Measure RTT
    ├── IF Age == 0 → warming GET (first 1 MB via Range)
    ├── GGC classification:
    │     ├── RTT < 5ms → "ggc" (inside ISP)
    │     ├── RTT 5-20ms → "edge_pop" (nearby IXP)
    │     └── RTT > 20ms → "datacenter" (distant)
    └── Output: { testTargetUrl, cacheIp, gfeIp, nodeLocationId,
                  cacheType, contentLength, baseRtt }
  
  Resource allocation:
    ├── Create download HttpClient (isolated, no redirect following)
    │     ├── autoUncompress: false
    │     └── maxConnectionsPerHost: workerCount
    ├── Create upload HttpClient (separate instance, for Tier 1)
    ├── Optionally: prepare SecureSocket factory (for Tier 2 upload)
    └── Initialize EMA smoother, sample buffers, chunk counter

  // ═══════════════════════════════════════════════════
  // PHASE 1: LATENCY           (TestLifecycle.latency)
  // ═══════════════════════════════════════════════════
  
  Target: cacheIp (gvt1.com resolved IP)
  Method: 20x sequential HEAD requests to testTargetUrl
    ├── All on single keep-alive connection
    ├── Measure HTTP-layer RTT per request
    │     (time from request sent to first response byte)
    ├── Discard first 2 samples (TLS handshake + TCP slow start)
    ├── Remaining 18 samples:
    │     ├── ping = median RTT
    │     ├── jitter = IQR (interquartile range) of RTT values
    │     ├── minRtt = minimum (indicates theoretical floor)
    │     └── p95Rtt = 95th percentile (indicates worst-case)
    └── Output: { latencyMs, jitterMs, minRtt, p95Rtt }
  
  GOOGLE-SPECIFIC NOTE:
    The gvt1.com HEAD response is extremely lightweight
    (no body, minimal headers). This gives you clean RTT
    measurement without payload noise. Much better than
    using www.google.com which returns redirect headers,
    cookies, and other overhead.

  // ═══════════════════════════════════════════════════
  // PHASE 2: DOWNLOAD          (TestLifecycle.download)
  // ═══════════════════════════════════════════════════
  
  HttpClient: FRESH instance
    ├── autoRedirect: false (we already have the direct cache URL)
    ├── autoUncompress: false
    ├── connectionTimeout: 10s
    ├── idleTimeout: 15s
    └── maxConnectionsPerHost: 8
  
  Worker Pool: 6 parallel async workers (scale to 8 if fast connection)
    ├── Shared state:
    │     ├── nextChunkIndex: AtomicInt (starts at 0)
    │     ├── contentLength: from discovery (e.g., 104857600)
    │     ├── chunkSize: 4194304 (4 MB default, adaptive per worker)
    │     └── testTimer: Stopwatch (15 second limit)
    │
    ├── Per-worker loop:
    │     while (testTimer.elapsedSeconds < 15) {
    │       chunkIdx = atomicIncrement(nextChunkIndex)
    │       startByte = (chunkIdx * chunkSize) % contentLength
    │       endByte = min(startByte + chunkSize - 1, contentLength - 1)
    │       
    │       // Handle wraparound at file boundary
    │       if (startByte >= contentLength) {
    │         startByte = startByte % contentLength
    │         endByte = min(startByte + chunkSize - 1, contentLength - 1)
    │       }
    │       
    │       GET testTargetUrl
    │         Range: bytes={startByte}-{endByte}
    │         Accept-Encoding: identity
    │         User-Agent: {realistic Chrome UA}
    │         Connection: keep-alive
    │       
    │       Stream response → count bytes, discard data
    │       Report: { workerId, bytes, duration, timestamp }
    │       
    │       // Adaptive chunk sizing
    │       if (chunkDuration < 300ms) chunkSize = min(chunkSize*2, 16MB)
    │       if (chunkDuration > 8s) chunkSize = max(chunkSize/2, 256KB)
    │     }
    │
    ├── Error handling per worker:
    │     HTTP 429 Too Many Requests → back off 2s, retry (max 3)
    │     HTTP 403 → switch to Tier 2 URL (if available), log event
    │     HTTP 416 Range Not Satisfiable → reset offset to 0
    │     HTTP 5xx → retry once, then mark worker failed
    │     Timeout → close connection, open new one, retry
    │     Worker failure is isolated — doesn't kill other workers
    │
    ├── Stagger: Workers launch 150ms apart
    │
    └── Dynamic scaling:
          After 3s, evaluate per-worker throughput
          IF avg > 40 Mbps AND workers < 8 → spawn 2 more
  
  Aggregation:
    ├── 250ms tick → sum throughput across all workers → EMA(α=0.3)
    ├── Discard first 3 seconds (TCP slow-start + ramp-up)
    ├── Test duration: 15 seconds total (12 seconds of valid samples)
    └── Output: { downloadMbps, sampleCurve[], rawSamples[] }

  // ═══════════════════════════════════════════════════
  // PHASE 3: UPLOAD            (TestLifecycle.upload)
  // ═══════════════════════════════════════════════════
  
  Strategy selector (Tier 1 → Tier 2 → Tier 3):
  
  ┌─ TIER 1: POST to Google GFE
  │   HttpClient: FRESH instance
  │   Target: https://www.google.com/gen_204
  │   Workers: 6 parallel
  │   Chunk size: 512 KB per POST
  │   
  │   Per-worker loop:
  │     POST /gen_204 → body: 512 KB random bytes
  │     Measure: time from request start to response received
  │     uploadSpeed = 512 KB / elapsed
  │     reportSample(uploadSpeed)
  │   
  │   Success criteria:
  │     - At least 80% of POST requests return 204
  │     - Test runs for >= 5 seconds without mass failures
  │   
  │   IF success → use result, tag: "google-gfe"
  │   IF failure → fall through
  │
  ├─ TIER 2: TCP Write to GFE IP
  │   Target: gfeIp:443 (www.google.com resolved IP)
  │   Use SecureSocket, manual HTTP framing
  │   Write random bytes after POST headers
  │   Count ACKed bytes
  │   
  │   IF bytes > 2 MB AND duration > 3s → use result, tag: "google-tcp"
  │   ELSE → fall through
  │
  └─ TIER 3: Cloudflare Fallback
      Instantiate CloudflareUploadWorker
      POST to speed.cloudflare.com/__up
      Tag: "cloudflare-fallback"
  
  Output: { uploadMbps, uploadSource, sampleCurve[] }

  // ═══════════════════════════════════════════════════
  // PHASE 4: CLEANUP           (TestLifecycle.cleanup)
  // ═══════════════════════════════════════════════════
  
  ├── Close all HttpClient instances
  ├── Close any SecureSocket instances
  ├── Cancel pending timers
  ├── Flush sample buffers
  └── Aggregate final result:
  
        GoogleGgcTestResult {
          // Cache node identity
          cacheNodeUrl:    "r5---sn-ab5sznlk.gvt1.com"
          cacheIp:         "74.125.xxx.xxx"
          nodeLocationId:  "sn-ab5sznlk"
          cacheType:       "ggc"          // or "edge_pop" / "datacenter"
          testAsset:       "google-chrome-stable_current_amd64.deb"
          
          // Latency
          latencyMs:       2.4
          jitterMs:        0.8
          minRttMs:        1.9
          p95RttMs:        4.1
          
          // Throughput
          downloadMbps:    623.7
          uploadMbps:      48.2
          uploadSource:    "google-gfe"   // or "google-tcp" / "cloudflare-fallback"
          
          // Test metadata
          testDuration:    15.0
          downloadWorkers: 6
          uploadWorkers:   6
          downloadSamples: [...EMA curve...]
          uploadSamples:   [...EMA curve...]
          
          // Cache health (from discovery)
          cacheAgeSeconds: 14523          // how long the object was in GGC
          cacheWasWarm:    true           // did we need a warming request?
        }
}
```

### Integration Class Hierarchy

```
TestEngine (abstract)
  ├── OoklaTestEngine           (existing)
  ├── FastComTestEngine          (existing)
  ├── CloudflareTestEngine       (existing)
  ├── FacebookCdnTestEngine      (existing)
  ├── AkamaiTestEngine           (existing)
  └── GoogleGgcTestEngine        (NEW)
        ├── GoogleCacheDiscovery         (Phase 0)
        │     ├── RedirectResolver           (GET → 302 → gvt1.com URL)
        │     ├── CacheNodeValidator         (HEAD → verify cache hit, Age, Range)
        │     └── GgcClassifier              (RTT → ggc/edge_pop/datacenter)
        ├── GoogleLatencyMeasurer        (Phase 1 — HEAD-based RTT)
        ├── GoogleDownloadWorker         (Phase 2 — Range GET loop)
        │     └── AdaptiveChunkSizer         (dynamic 256KB → 16MB)
        ├── GoogleUploadStrategy         (Phase 3 — tiered)
        │     ├── GfePostUploader            (Tier 1: POST to /gen_204)
        │     ├── TcpWriteUploader           (Tier 2: raw socket write)
        │     └── CloudflareFallbackUploader (Tier 3: reuse CF engine)
        └── GoogleResultAggregator       (Phase 4 — EMA + final stats)

Shared infrastructure (already in your codebase):
  ├── TestLifecycle
  ├── EmaSmoother
  ├── WorkerPool
  ├── HttpClientFactory
  └── CloudflareUploadWorker    ← shared with Akamai engine's Tier 3
```

---

## 5. Key Differences from Your Akamai Engine

| Aspect | Akamai Engine | Google GGC Engine |
|--------|--------------|-------------------|
| Edge discovery | DNS CNAME chain inspection | HTTP 302 redirect following |
| Cache confirmation | `X-Cache: TCP_HIT` header | `Age: {N}` header (N > 0) |
| Server identification | `Server: AkamaiGHost` | `Server: downloads` (gvt1.com) |
| Cache node identity | IP reverse DNS + CNAME chain | `sn-{code}` in redirect URL hostname |
| Test asset source | Third-party customer assets (Adobe, Steam) | First-party Google assets (Chrome, Cloud CLI) |
| Asset discovery | DNS CNAME → Akamai validation → HEAD | GET with redirect disabled → 302 Location → HEAD |
| Per-connection pacing | Minimal (customers control) | Aggressive (Google BBR pacing, ~50 Mbps/conn) |
| Required parallelism | 4-6 workers often sufficient | 6-8 workers minimum due to pacing |
| Upload viability | Tier 1 (POST) nearly impossible | Tier 1 (POST to /gen_204) is viable |
| Upload body limit | N/A (edges reject all POST) | ~512 KB - 1 MB per request to /gen_204 |

---

## 6. Summary of Architectural Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edge discovery | HTTP 302 redirect from `dl.google.com` | Google's redirect IS the discovery API; returns direct cache node URL with location metadata |
| DNS resolver | System default (ISP resolver) | Google's GSLB uses resolver source IP for GGC mapping; public DNS may bypass local GGC |
| Test asset | Chrome stable `.deb` (~100 MB) | Evergreen URL, never 404s, massively cached on every GGC globally, large enough for sustained test |
| Cache hit strategy | Exact redirect URL, no modifications | Cache key = URL path; any variation = cache miss = origin fetch = wrong measurement |
| Local cache bypass | Fresh HttpClient, `Accept-Encoding: identity`, stream-and-discard | No disk cache in Dart HttpClient; identity encoding ensures byte-accurate throughput |
| Download mechanism | Parallel Range GET workers with adaptive chunks and wraparound | Handles Google's per-connection TCP pacing; Range requests are normal HTTP; sustainable indefinitely |
| Worker count | 6 base, scale to 8 adaptively | Google's BBR pacing limits single-connection throughput; need parallelism to saturate fast links |
| Upload primary | POST to `www.google.com/gen_204` | GFE accepts POST (unlike Akamai); co-located with GGC; measures real upload path to Google edge |
| Upload fallback | TCP write → Cloudflare | Guaranteed measurement path when /gen_204 fails |
| Cache type detection | RTT-based classification (< 5ms = GGC, 5-20ms = edge PoP) | Simple, reliable heuristic; traceroute would be more accurate but adds complexity and time |

This engine measures what the user actually experiences when downloading a Chrome update, streaming YouTube, or installing an app from the Play Store: **the real-world throughput to the Google cache node that serves their daily traffic.**