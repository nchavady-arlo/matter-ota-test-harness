# Testing YOUR OTA Provider

This guide is for testing **your own Matter controller/OTA provider** implementation.

## Architecture

```
┌──────────────────────────┐
│ YOUR Controller/Hub      │
│ (Commissioner +          │  1. Discovers & commissions
│  OTA Provider)           │  2. Serves OTA updates
└────────┬─────────────────┘
         │
         │ Commissions & serves OTA
         ▼
┌──────────────────────────┐
│ Simulated OTA Requestor  │
│ (chip-ota-requestor-app) │  • Runs in pairing mode
│                          │  • Accepts commissioning
│                          │  • Queries for OTA updates
└──────────────────────────┘
```

## Prerequisites

1. **Build the harness:**
   ```bash
   cd ~/workspace/github/matter-ota-test-harness
   export MATTER_SDK_ROOT=/home/nchavady/workspace/github/connectedhomeip
   ./build-setup.sh
   ```

2. **Generate test OTA images:**
   ```bash
   ./scripts/make-ota-images.sh
   ```

3. **YOUR controller/provider must be running**

## Workflow

### Step 1: Start Simulated Requestor in Pairing Mode

```bash
./scripts/start-ota-end-node.sh start 1
```

**Output:**
```
==================================================
Starting Simulated OTA Requestor
==================================================
Instance: 1
Discriminator: 3841
Port: 5541
Setup PIN: 20202021

The requestor is now in PAIRING MODE.

Next steps:
  1. Use YOUR controller to commission this device
  2. Configure YOUR controller to serve OTA updates
  3. Monitor progress: ./scripts/start-ota-end-node.sh monitor 1

Waiting for YOUR controller to commission this device...
(Ctrl+C to stop waiting; the requestor keeps running)

  ... still waiting for commissioning (10s elapsed)
  ... still waiting for commissioning (20s elapsed)
✓ Commissioning completed

Device is now on your fabric. Continue the OTA flow from YOUR
controller/provider — no further harness steps are needed.

To monitor OTA progress:
  ./scripts/start-ota-end-node.sh monitor 1
```

The command **blocks** until your controller commissions the device (up to
10 minutes by default), then hands off — everything after that (ACLs,
`AnnounceOTAProvider`/`DefaultOTAProviders`, the OTA flow itself) is driven
entirely by YOUR controller/provider.

### Step 2: Commission from YOUR Controller

**On YOUR controller/hub:**

1. **Discover the device:**
   - Look for discriminator: **3841**
   - Or scan QR code / manual pairing code

2. **Commission the device:**
   - Setup PIN: **20202021**
   - Your controller should discover it via mDNS/BLE
   - Complete commissioning flow

3. **Verify commissioning:**
   - Device should appear in your controller's device list
   - Check that it's on your fabric

### Step 3: Configure OTA on YOUR Controller

**Your controller needs to:**

1. **Set up ACLs** (if not already configured):
   - Grant **Operate privilege (level 3)** to all nodes
   - For **OTA Provider cluster (0x0029)**
   - Without this, QueryImage will fail with UnsupportedAccess

2. **Prepare OTA image:**
   - Use one of the test images from `./images/`
   - Example: `test-normal.ota` (100 KB)

3. **Trigger OTA** via one of these methods:

   **Method A: Send AnnounceOTAProvider command**
   ```
   Send to commissioned device:
   - Cluster: OTA Software Update Requestor (0x002a)
   - Command: AnnounceOTAProvider (0x00)
   - ProviderNodeID: <your-controller-node-id>
   - Endpoint: 0
   - AnnouncementReason: 0 (SimpleAnnouncement)
   ```

   **Method B: Write DefaultOTAProviders attribute**
   ```
   Write to commissioned device:
   - Cluster: OTA Software Update Requestor (0x002a)
   - Attribute: DefaultOTAProviders (0x0000)
   - Value: [{"providerNodeID": <your-node-id>, "endpoint": 0}]
   ```

### Step 4: Monitor OTA Progress

In another terminal:

```bash
./scripts/start-ota-end-node.sh monitor 1
```

**You should see:**
```
QueryImage sent
QueryImageResponse received (status: 0 = UpdateAvailable)
BDX transfer started
Download progress: 10%... 50%... 100%
Download complete
ApplyUpdate sent
ApplyUpdateResponse received (action: Proceed)
NotifyUpdateApplied sent
```

**Or manually tail the log:**
```bash
tail -f logs/requestor-1.log
```

### Step 5: Verify Success

**Check for these key events in the log:**

| Event | What It Means |
|-------|---------------|
| `QueryImageResponse: status: 0` | Provider has update available |
| `BDX transfer` | File download started |
| `Download complete` | Full image transferred |
| `ApplyUpdateResponse: action: 0` | Provider approved application |
| `NotifyUpdateApplied` | Requestor confirmed successful update |

### Step 6: Clean Up

```bash
./scripts/start-ota-end-node.sh clean 1
```

---

## Testing Multiple Requestors

Test concurrent OTA updates:

```bash
# Start 3 requestors
./scripts/start-ota-end-node.sh start 1
./scripts/start-ota-end-node.sh start 2
./scripts/start-ota-end-node.sh start 3

# Commission each from YOUR controller:
# - Instance 1: Discriminator 3841, Port 5541
# - Instance 2: Discriminator 3842, Port 5542
# - Instance 3: Discriminator 3843, Port 5543

# Monitor each
./scripts/start-ota-end-node.sh monitor 1  # Terminal 1
./scripts/start-ota-end-node.sh monitor 2  # Terminal 2
./scripts/start-ota-end-node.sh monitor 3  # Terminal 3

# Check status
./scripts/start-ota-end-node.sh status
```

---

## Using Different Test Images

Test different scenarios by configuring YOUR provider with these images:

```bash
# Fast test (1 KB)
images/test-small.ota

# Normal test (100 KB)
images/test-normal.ota

# Stress test (5 MB, ~5000 BDX blocks)
images/test-large.ota

# Should fail - corrupted digest
images/test-corrupted.ota

# Should fail - downgrade (version 9 < current 10)
images/test-downgrade.ota
```

---

## Troubleshooting

### Requestor Not Discovered

**Symptom:** Your controller can't find the simulated device

**Fixes:**
- Check requestor is running: `./scripts/start-ota-end-node.sh status`
- Verify discriminator: should be 3840 + instance number
- Check network connectivity (same subnet)
- Look for mDNS advertisements: `avahi-browse -a`

### QueryImage Returns UnsupportedAccess (0x580)

**Symptom:** Log shows `CHIP_ERROR: 0x00000580`

**Cause:** Missing ACLs on YOUR provider

**Fix:** Configure ACL on YOUR provider:
```json
{
  "privilege": 3,           // Operate
  "authMode": 2,            // CASE
  "subjects": null,         // All nodes
  "targets": [{"cluster": 41, "endpoint": null}]  // OTA Provider (0x0029)
}
```

### BDX Transfer Timeout

**Symptom:** Download starts but times out after 5 minutes

**Causes:**
1. YOUR provider stopped sending blocks
2. Network connectivity lost
3. YOUR provider crashed

**Debug:**
- Check YOUR provider logs
- Verify YOUR provider process is running
- Check network: `ping <provider-ip>`

### Download Complete but NotifyUpdateApplied Not Sent

**Symptom:** Download succeeds but no NotifyUpdateApplied

**Expected:** This is normal in test mode (no actual reboot occurs)

**Verify:**
- Check log for "Download complete"
- Check for "ApplyUpdateResponse"
- The simulated device doesn't actually reboot, so NotifyUpdateApplied may not be sent

---

## Expected Behavior

**✅ Success Indicators:**
- Requestor discovers YOUR controller as provider
- QueryImage succeeds (status 0)
- BDX transfer completes (100% progress)
- ApplyUpdate succeeds
- No errors in logs

**❌ Failure Indicators:**
- QueryImage returns non-zero status (Busy=1, NotAvailable=2)
- BDX timeout after 5 minutes
- ERROR messages in logs
- Requestor state stuck (not progressing)

---

## Quick Reference

```bash
# Start requestor in pairing mode
./scripts/start-ota-end-node.sh start 1

# Commission from YOUR controller
# Discriminator: 3841, PIN: 20202021

# Monitor OTA progress
./scripts/start-ota-end-node.sh monitor 1

# Check status
./scripts/start-ota-end-node.sh status

# Clean up
./scripts/start-ota-end-node.sh clean 1
```

**The simulated requestor is now a test device for validating YOUR OTA provider!** 🎯
