# OTA Test Harness - Quick Start

Complete Matter OTA Provider testing in 3 commands.

## Prerequisites

- Matter SDK v1.5.1.0 at `/home/nchavady/workspace/github/connectedhomeip`
- Linux aarch64 (Ubuntu Server 24.04)
- Network connectivity on localhost

## 3-Minute Setup

```bash
cd /home/nchavady/workspace/github/iris/ota-test-harness

# 1. Build SDK components (~10 min first time)
./build-setup.sh

# 2. Generate test images (~5 sec)
./scripts/make-ota-images.sh

# 3. Run happy path test (~30 sec)
./scripts/run-test.sh happy-path
```

## Expected Output

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

## What Just Happened?

1. **Requestor launched** with discriminator 3841, port 5541, node ID 0x101
2. **Reference provider launched** serving `test-normal.ota` (100 KB)
3. **Commissioned** requestor onto fabric
4. **ACLs installed** on provider (Operate privilege for OTA cluster)
5. **Wired** requestor to provider via `AnnounceOTAProvider` command
6. **Monitored logs** for: QueryImage → BDX transfer → Apply → NotifyUpdateApplied

## Next: Test YOUR Provider

```bash
# Start YOUR provider (example - adjust for your setup)
your-provider-app --discriminator 3000 --secured-device-port 5540

# Start a requestor
./scripts/run-requestor.sh start 1 --auto-apply

# Commission it
./scripts/commission.sh commission 1

# Setup ACLs on YOUR provider (use your provider's node ID)
./scripts/commission.sh setup-provider-acl 0x1234

# Wire requestor to YOUR provider
./scripts/commission.sh wire-provider 1 0x1234 0

# Monitor
tail -f logs/requestor-1.log
```

## Full Documentation

See [README.md](README.md) for:
- Complete test scenarios (busy, timeout, concurrent, etc.)
- Troubleshooting guide with specific log patterns
- Advanced usage (multiple requestors, fault injection)
- Control mode (isolating bugs with reference provider)

## Quick Commands

```bash
# View running requestors
./scripts/run-requestor.sh status

# Stop all requestors
./scripts/run-requestor.sh stop-all

# Clean all state
./scripts/run-requestor.sh clean-all

# Run all tests
./scripts/run-test.sh all

# Start 5 concurrent requestors
./scripts/run-requestor.sh start-multi 5
./scripts/commission.sh commission-multi 5
```

## Common Issues

### QueryImage returns UnsupportedAccess (0x580)
→ ACLs not set. Run: `./scripts/commission.sh setup-provider-acl <PROVIDER_NODE_ID>`

### BDX transfer timeout
→ Check provider is running: `ps aux | grep ota-provider`

### Requestor won't commission
→ Check discriminator/port match: `./scripts/run-requestor.sh status`

### Stale state from previous run
→ Clean: `./scripts/run-requestor.sh clean-all`

---

**Ready to test your provider end-to-end!**
