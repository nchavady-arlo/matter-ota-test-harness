# Matter OTA Requestor Test Harness

**Purpose**: End-to-end testing of Matter OTA Provider implementations using simulated OTA Requestors.

**SDK Version**: connectedhomeip v1.5.1.0 (Matter 1.5 spec)  
**Platform**: Linux aarch64, Ubuntu Server 24.04  
**Approach**: Unmodified `chip-ota-requestor-app` + external orchestration

---

## Architecture

```
Test Orchestrator Scripts
  ├─ run-requestor.sh      → Launch N independent requestor instances
  ├─ commission.sh         → Commission requestors, setup ACLs, wire provider
  ├─ make-ota-images.sh        → Generate test OTA images
  └─ run-test.sh           → Execute test scenarios with assertions

Each Requestor Instance:
  - Unique discriminator, port, node ID, KVS file
  - Independent processes (concurrent execution)
  - Clean state reset between test runs

Provider Under Test:
  - YOUR provider implementation (when ready)
  - OR SDK's reference ota-provider-app (control mode)
```

---

## 5-Minute Quickstart

### 1. Build SDK Components

```bash
cd /home/nchavady/workspace/github/iris/ota-test-harness
./build-setup.sh
```

**What this does:**
- Verifies SDK at v1.5.1.0
- Builds `chip-ota-requestor-app`, `chip-ota-provider-app`, `chip-tool` for aarch64
- Takes ~10 minutes on first run (subsequent rebuilds <1 min)

### 2. Generate Test Images

```bash
./scripts/make-ota-images.sh
```

**Generated images:**
- `test-normal.ota` (100 KB) — baseline happy path
- `test-small.ota` (1 KB) — fast iteration
- `test-large.ota` (5 MB) — BDX stress test
- `test-corrupted.ota` — digest validation failure
- `test-wrong-vid.ota` — VID/PID mismatch
- `test-downgrade.ota` — downgrade attempt
- Plus min/max version rejection images

### 3. Run Test Scenario

```bash
./scripts/internal/run-test.sh happy-path
```

**What this does:**
1. Launches requestor instance 1
2. Starts reference `ota-provider-app` with `test-normal.ota`
3. Commissions requestor onto fabric
4. Installs ACLs on provider (**CRITICAL**)
5. Wires requestor to provider via `AnnounceOTAProvider`
6. Monitors logs for: QueryImage → Download → Apply → NotifyUpdateApplied
7. Reports PASS/FAIL

**Expected output:**
```
[INFO] ==================================================
[INFO] TEST: Happy Path - Full OTA Update
[INFO] ==================================================
[INFO] ✓ QueryImage successful
[INFO] ✓ Download complete
[INFO] ✓ Apply initiated
[INFO] ==================================================
[INFO] TEST PASSED: Happy Path
[INFO] ==================================================
```

---

## Test Scenarios

| Scenario | Command | What It Tests |
|----------|---------|---------------|
| **Happy Path** | `./scripts/internal/run-test.sh happy-path` | Full update: QueryImage → Download → Apply → NotifyUpdateApplied |
| **Provider Busy** | `./scripts/internal/run-test.sh provider-busy` | Provider returns Busy, requestor honors `delayedActionTime` (30s) |
| **BDX Interrupted** | `./scripts/internal/run-test.sh bdx-interrupted` | Provider killed mid-transfer, requestor detects failure and resets |
| **Concurrent Updates** | `./scripts/internal/run-test.sh concurrent-updates` | 3 requestors query simultaneously, tests provider concurrency |
| **All Tests** | `./scripts/internal/run-test.sh all` | Run all scenarios sequentially |

---

## Using YOUR Provider (Not Reference Provider)

### Step 1: Start Your Provider

```bash
# Example (adjust for your provider's setup):
your-provider-app \
    --discriminator 3000 \
    --secured-device-port 5540 \
    --vendor-id 0xFFF1 \
    --product-id 0x8000 \
    --image-path /path/to/your/image.ota
```

**Note your provider's:**
- Node ID (e.g., `0x1234`)
- Endpoint (typically `0`)
- Image file location

### Step 2: Manual Test Flow

```bash
# Clean state
./scripts/internal/run-requestor.sh clean-all

# Start requestor
./scripts/internal/run-requestor.sh start 1 --auto-apply

# Commission it
./scripts/internal/commission.sh commission 1

# Setup ACLs on YOUR provider
./scripts/internal/commission.sh setup-provider-acl <YOUR_PROVIDER_NODE_ID>

# Wire requestor to YOUR provider
./scripts/internal/commission.sh wire-provider 1 <YOUR_PROVIDER_NODE_ID> 0

# Monitor logs
tail -f logs/requestor-1.log
```

### Step 3: Check Requestor State

```bash
# Read UpdateState attribute (0=Unknown, 1=Idle, 2=Querying, 4=Downloading, 5=Applying)
cd /home/nchavady/workspace/github/connectedhomeip
./out/aarch64/chip-tool otasoftwareupdaterequestor read update-state 0x101 0

# Read UpdateStateProgress (percentage)
./out/aarch64/chip-tool otasoftwareupdaterequestor read update-state-progress 0x101 0
```

---

## Advanced Usage

### Launch Multiple Requestors

```bash
# Start 5 requestor instances (IDs 1-5)
./scripts/internal/run-requestor.sh start-multi 5

# Commission all 5
./scripts/internal/commission.sh commission-multi 5

# Setup provider ACLs (once)
./scripts/internal/commission.sh setup-provider-acl 0x1234

# Wire all to provider
for i in {1..5}; do
    ./scripts/internal/commission.sh wire-provider $i 0x1234 0
done

# Check status
./scripts/internal/run-requestor.sh status
```

### Custom Requestor Options

```bash
# Require user consent
./scripts/internal/run-requestor.sh start 1 --user-consent denied

# Set periodic query timeout (auto-retry every 60 seconds)
./scripts/internal/run-requestor.sh start 2 --periodic-query 60

# Custom download path
./scripts/internal/run-requestor.sh start 3 --download-path /tmp/my-ota.bin
```

### Using DefaultOTAProviders Attribute (Periodic Polling)

```bash
# Instead of AnnounceOTAProvider (immediate), use attribute for periodic polling
./scripts/internal/commission.sh wire-provider-attribute 1 0x1234 0

# Requestor will query provider based on --periodicQueryTimeout
# Default: 24 hours (configure with --periodic-query flag)
```

### Inject Faults via Provider

**Using reference provider:**
```bash
# Provider returns Busy with 120s delay
chip-ota-provider-app --filepath test.ota --queryImageStatus busy --delayedQueryActionTimeSec 120

# Drop first 3 QueryImage commands (timeout test)
chip-ota-provider-app --filepath test.ota --ignoreQueryImage 3

# Require user consent
chip-ota-provider-app --filepath test.ota --userConsentNeeded

# Suspend on ApplyUpdate
chip-ota-provider-app --filepath test.ota --applyUpdateAction awaitNextAction --delayedApplyActionTimeSec 300
```

**Network-level faults:**
```bash
# Start transfer, then simulate network partition mid-download
iptables -A OUTPUT -p tcp --dport 5540 -j DROP

# Restore after 30s
sleep 30
iptables -D OUTPUT -p tcp --dport 5540 -j DROP
```

---

## Troubleshooting

### 1. QueryImage Returns UnsupportedAccess

**Symptom:** Requestor log shows:
```
Received QueryImage failure response: 0x00000580 (UnsupportedAccess)
```

**Cause:** Provider ACLs not configured correctly.

**Fix:**
```bash
# Verify provider is commissioned
chip-tool basicinformation read vendor-id <PROVIDER_NODE_ID> 0

# Install correct ACL (run from test harness root)
./scripts/internal/commission.sh setup-provider-acl <PROVIDER_NODE_ID>
```

**Critical ACL requirement:**
```json
{
  "fabricIndex": 1,
  "privilege": 3,           // Operate privilege
  "authMode": 2,
  "subjects": null,         // All nodes
  "targets": [{"cluster": 41, "endpoint": null, "deviceType": null}]  // OTA Provider cluster 0x0029
}
```

### 2. BDX Transfer Timeout

**Symptom:** Requestor log shows:
```
BDX transfer timed out after 300 seconds
OnDownloadTimeout
```

**Causes:**
1. Provider not sending blocks (check provider logs)
2. Network connectivity lost
3. Provider crashed mid-transfer

**Diagnosis:**
```bash
# Check provider process
ps aux | grep ota-provider-app

# Check network connectivity
ping <provider-ip>

# Look for BDX messages in provider log
grep -i "BlockSend\|BDX" logs/provider.log
```

**SDK Reference:** `DefaultOTARequestor.cpp:52` — 5-minute watchdog only fires if **no block progress**. A very slow transfer won't timeout.

### 3. Digest Mismatch / Image Validation Failure

**Symptom:** Requestor log shows:
```
Image validation failed
Digest mismatch
```

**Causes:**
1. Image corrupted during generation (use `test-corrupted.ota` to test this path)
2. Provider serving different image than declared in QueryImageResponse
3. Disk corruption

**Diagnosis:**
```bash
# Verify image header
python3 /home/nchavady/workspace/github/connectedhomeip/src/app/ota_image_tool.py show images/test-normal.ota

# Check downloaded file
ls -lh images/downloaded-1.bin

# Compare digest
sha256sum images/test-normal.ota images/downloaded-1.bin
```

### 4. Requestor Stuck in kQuerying State

**Symptom:** UpdateState remains `2` (kQuerying) for >30 seconds.

**Causes:**
1. Provider not responding (check commissioning)
2. CASE session establishment failure
3. Provider node ID mismatch in imageURI

**Diagnosis:**
```bash
# Check CASE session
grep -i "CASE.*session\|Establishing secure session" logs/requestor-1.log

# Verify provider is reachable
chip-tool basicinformation read vendor-id <PROVIDER_NODE_ID> 0

# Check provider node ID in imageURI matches
grep "imageURI" logs/requestor-1.log
# Should show: bdx://NODE_ID/file.ota where NODE_ID matches provider
```

**SDK Reference:** `DefaultOTARequestor.cpp:172-179` — requestor validates imageURI nodeId matches provider nodeId from QueryImageResponse.

### 5. Downgrade Not Rejected

**Symptom:** Requestor accepts image with `softwareVersion < currentVersion`.

**Expected Behavior:** Requestor should reject with:
```
Available update version X is <= current version Y, update ignored
UpdateNotFound(UpToDate)
```

**Diagnosis:**
```bash
# Check requestor's current version
grep "current.*version\|CurrentVersion" logs/requestor-1.log

# Check QueryImageResponse softwareVersion
grep "softwareVersion" logs/requestor-1.log

# Verify image metadata
python3 /home/nchavady/workspace/github/connectedhomeip/src/app/ota_image_tool.py show images/test-downgrade.ota
```

**SDK Reference:** `DefaultOTARequestor.cpp:182-221` — version check happens on QueryImageResponse, before download.

### 6. Concurrent Requestors: Only One Succeeds

**Symptom:** With 3 requestors, only one downloads; others timeout or stuck.

**Cause:** Reference provider handles 1 BDX transfer at a time (by design).

**Expected:** Reference provider serializes transfers. Your provider should handle concurrency better.

**SDK Reference:** `examples/ota-provider-app/linux/README.md:112` — "Only one BDX transfer at a time."

**Test YOUR provider's concurrency:**
```bash
# Launch 10 requestors against YOUR provider
./scripts/internal/run-requestor.sh start-multi 10
./scripts/internal/commission.sh commission-multi 10
./scripts/internal/commission.sh setup-provider-acl <YOUR_PROVIDER_NODE_ID>

for i in {1..10}; do
    ./scripts/internal/commission.sh wire-provider $i <YOUR_PROVIDER_NODE_ID> 0 &
done

# Monitor which ones succeed
tail -f logs/requestor-*.log | grep "Download complete"
```

### 7. NotifyUpdateApplied Never Sent

**Symptom:** After image download + apply, no NotifyUpdateApplied seen.

**Causes:**
1. Requestor not configured with `--auto-apply` (manual apply mode)
2. Image `execv()` failed (image not executable)
3. Boot reason not set correctly

**Diagnosis:**
```bash
# Check if auto-apply enabled
grep "autoApplyImage\|skipExecImageFile" logs/requestor-1.log

# Check for execv attempt
grep "execv\|boot.*new.*image" logs/requestor-1.log

# If using --skipExecImageFile, NotifyUpdateApplied sent via timer (main.cpp:190-199)
```

**SDK Reference:** `main.cpp:336-358` — After apply, requestor calls `execv()` to boot new image. If `--skipExecImageFile` flag used, sends NotifyUpdateApplied via timer instead of actual reboot.

### 8. Stale KVS Breaks Re-runs

**Symptom:** Second test run fails with commissioning errors or wrong fabric.

**Cause:** KVS (persistent storage) from previous run not cleaned.

**Fix:**
```bash
# Full cleanup
./scripts/internal/run-requestor.sh clean-all

# Clean specific instance
./scripts/internal/run-requestor.sh clean 1

# Also clean provider KVS
rm -f /tmp/chip_kvs_provider
```

---

## Log Patterns for Assertions

Use these patterns to parse logs programmatically:

| Event | Log Pattern | File Reference |
|-------|-------------|----------------|
| **QueryImage sent** | `Sending QueryImage` | DefaultOTARequestor.cpp:742 |
| **QueryImageResponse received** | `QueryImageResponse:` | DefaultOTARequestor.cpp:56 |
| **UpdateAvailable** | `status: 0` | DefaultOTARequestor.cpp:57 (OTAQueryStatus::kUpdateAvailable) |
| **Busy** | `status: 1` | DefaultOTARequestor.cpp:57 (OTAQueryStatus::kBusy) |
| **NotAvailable** | `status: 2` | DefaultOTARequestor.cpp:57 (OTAQueryStatus::kNotAvailable) |
| **delayedActionTime** | `delayedActionTime: \d+ seconds` | DefaultOTARequestor.cpp:60 |
| **BDX transfer started** | `Starting BDX transfer` | BDXDownloader.cpp |
| **Block received** | `BlockSend.*received\|Received block \d+` | BDXDownloader.cpp |
| **Download complete** | `Transfer complete\|BDX transfer complete` | BDXDownloader.cpp |
| **ApplyUpdate sent** | `Sending ApplyUpdateRequest` | DefaultOTARequestor.cpp |
| **ApplyUpdateResponse** | `ApplyUpdateResponse:` | DefaultOTARequestor.cpp:92 |
| **NotifyUpdateApplied sent** | `Sending NotifyUpdateApplied` | DefaultOTARequestor.cpp |
| **Error: UnsupportedAccess** | `0x00000580` | (CHIP_ERROR from IM) |
| **Error: Timeout** | `CHIP_ERROR_TIMEOUT\|0x00000032` | DefaultOTARequestor.cpp:260 |
| **State transition** | `UpdateState.*->.*` | OTA requestor server |
| **Digest mismatch** | `digest.*mismatch\|validation.*fail` | OTAImageProcessorImpl |

---

## Project Structure

```
ota-test-harness/
├── README.md                         # This file
├── START-OTA-END-NODE.md             # Bring-your-controller workflow guide
├── build-setup.sh                    # One-time build script
├── scripts/
│   ├── start-ota-end-node.sh         # Start simulated OTA Requestor for YOUR controller
│   ├── make-ota-images.sh            # Generate test OTA images
│   └── internal/
│       ├── run-requestor.sh          # Launch/stop requestor instances
│       ├── commission.sh             # Commission + wire provider
│       ├── commission-ble.sh         # BLE-based commissioning
│       └── run-test.sh               # Test scenario runner
├── images/                           # Generated .ota files
│   ├── test-normal.ota
│   ├── test-large.ota
│   ├── test-corrupted.ota
│   └── image-list.json               # Manifest for reference provider
├── kvs/                              # Persistent storage per requestor
│   ├── requestor-1.kvs
│   └── requestor-N.kvs
└── logs/                             # Log files per instance
    ├── requestor-1.log
    ├── requestor-N.log
    └── provider.log
```

---

## Node ID Allocation

| Component | Node ID | Discriminator | Port |
|-----------|---------|---------------|------|
| Commissioner (chip-tool) | 0x1B669 (112233) | N/A | N/A |
| Reference Provider | 0x1000 (4096) | 3000 | 5540 |
| Requestor Instance 1 | 0x101 (257) | 3841 | 5541 |
| Requestor Instance 2 | 0x102 (258) | 3842 | 5542 |
| Requestor Instance N | 0x100+N | 3840+N | 5540+N |
| **YOUR Provider** | <your-choice> | <your-choice> | <your-choice> |

---

## SDK Version Notes

**This harness is validated against connectedhomeip v1.5.1.0 (commit abcc720b48).**

### Upgrading to v1.6.x

1. Check out new SDK tag:
   ```bash
   cd /home/nchavady/workspace/github/connectedhomeip
   git fetch --tags
   git checkout v1.6.0.0
   ```

2. Rebuild:
   ```bash
   cd /home/nchavady/workspace/github/iris/ota-test-harness
   ./build-setup.sh
   ```

3. Verify tests still pass:
   ```bash
   ./scripts/internal/run-test.sh all
   ```

**No code patches to maintain** — unmodified app approach means zero rebase pain.

---

## Control Mode: Isolating Bugs

When a test fails, determine if the bug is in:
- Your provider implementation
- The test harness
- The Matter SDK itself

**Method:** Swap in SDK's reference `ota-provider-app` and re-run the test.

```bash
# Test with YOUR provider
./scripts/internal/commission.sh setup-provider-acl <YOUR_NODE_ID>
./scripts/internal/commission.sh wire-provider 1 <YOUR_NODE_ID> 0
# Observe failure

# Test with reference provider (control)
./scripts/internal/run-test.sh happy-path
# If this passes → bug is in YOUR provider
# If this also fails → bug is in harness or SDK
```

---

## Performance Notes

**Tested Configuration:**
- **Platform:** aarch64, 4 cores, 8 GB RAM
- **Max concurrent requestors:** 10 (tested)
- **Large image (5 MB) download time:** ~8 seconds with reference provider
- **Commission time:** ~3 seconds per requestor

**Scaling:**
- Each requestor uses ~15 MB RAM
- Concurrent limit determined by provider's BDX session handling
- Reference provider serializes transfers (1 at a time)
- Your provider should handle N concurrent transfers (test with `concurrent-updates`)

---

## Next Steps

1. **Validate harness with reference provider:**
   ```bash
   ./build-setup.sh
   ./scripts/make-ota-images.sh
   ./scripts/internal/run-test.sh all
   ```

2. **Integrate YOUR provider:**
   - Start your provider
   - Note its node ID
   - Run: `./scripts/internal/commission.sh setup-provider-acl <YOUR_NODE_ID>`
   - Run: `./scripts/internal/commission.sh wire-provider 1 <YOUR_NODE_ID> 0`
   - Monitor: `tail -f logs/requestor-1.log`

3. **Add custom test scenarios:**
   - Edit `scripts/internal/run-test.sh`
   - Add new test functions following existing patterns
   - Use `wait_for_log_pattern()` for assertions

4. **Stress test YOUR provider:**
   ```bash
   ./scripts/internal/run-requestor.sh start-multi 10
   ./scripts/internal/commission.sh commission-multi 10
   ./scripts/internal/commission.sh setup-provider-acl <YOUR_NODE_ID>
   for i in {1..10}; do
       ./scripts/internal/commission.sh wire-provider $i <YOUR_NODE_ID> 0 &
   done
   ```

---

## Support

**SDK Documentation:**
- OTA Requestor Guide: `examples/ota-requestor-app/linux/README.md`
- OTA Provider Guide: `examples/ota-provider-app/linux/README.md`
- Matter Spec: Section 11.21 (OTA Software Update)

**Harness Issues:**
- Check logs in `logs/` directory
- Enable verbose mode: `./scripts/internal/run-test.sh happy-path --verbose`
- Review troubleshooting section above

**SDK Issues:**
- connectedhomeip GitHub: https://github.com/project-chip/connectedhomeip/issues
- Discord: Matter Developer Community

---

**Built with:** Matter SDK v1.5.1.0, Approach (a) — Unmodified requestor + External orchestration  
**License:** Same as Matter SDK (Apache 2.0)
