# Spock 3.1.8 Bi-Directional Replication Setup Guide

This document describes the complete setup process for Spock bi-directional replication between two self-hosted Supabase instances communicating via Cloudflare Zero Trust tunnels.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Cloudflare Tunnel Setup](#cloudflare-tunnel-setup)
4. [PostgreSQL Configuration](#postgresql-configuration)
5. [Spock Extension Setup](#spock-extension-setup)
6. [Manual Fixes Required](#manual-fixes-required)
7. [Adding Tables to Replication](#adding-tables-to-replication)
8. [Verification](#verification)
9. [Conflict Resolution Behavior](#conflict-resolution-behavior)
10. [Troubleshooting](#troubleshooting)
11. [Quick Reference Commands](#quick-reference-commands)

---

## Architecture Overview

```
┌─────────────────────────────────┐         ┌─────────────────────────────────┐
│  PRIMARY (server-a.example.com) │         │  STANDBY (server-b.example.com) │
│                                 │         │                                 │
│  ┌─────────────────────────┐   │         │   ┌─────────────────────────┐   │
│  │ supabase-db             │   │         │   │ supabase-db             │   │
│  │ (PostgreSQL + Spock)    │   │         │   │ (PostgreSQL + Spock)    │   │
│  │                         │   │         │   │                         │   │
│  │ Node: primary           │◄──┼─────────┼──►│ Node: standby           │   │
│  │ Sub: sub_from_standby   │   │         │   │ Sub: sub_from_primary   │   │
│  └───────────┬─────────────┘   │         │   └───────────┬─────────────┘   │
│              │                 │         │               │                 │
│  ┌───────────▼─────────────┐   │         │   ┌───────────▼─────────────┐   │
│  │ cloudflared-pg-         │   │         │   │ cloudflared-pg-         │   │
│  │ replication             │   │         │   │ replication             │   │
│  │ (connects to STANDBY)   │   │         │   │ (connects to PRIMARY)   │   │
│  │ port ${PG_REPLICATION_PORT}              │   │         │   │ port ${PG_REPLICATION_PORT}              │   │
│  └───────────┬─────────────┘   │         │   └───────────┬─────────────┘   │
│              │                 │         │               │                 │
└──────────────┼─────────────────┘         └───────────────┼─────────────────┘
               │                                           │
               │         Cloudflare Zero Trust             │
               └───────────────────────────────────────────┘
```

### Key Concepts

- **Node**: A Spock participant in replication (each server is a node)
- **Node Interface**: Connection details for reaching a node
- **Subscription**: A node subscribing to changes from another node
- **Replication Set**: A collection of tables to replicate
- **Replication Slot**: PostgreSQL mechanism to track replication progress (on provider)
- **Replication Origin**: Local tracking of received changes (on subscriber)

---

## Prerequisites

### 1. Custom Docker Image with Spock

The standard Supabase PostgreSQL image does not include Spock. A custom image `supabase-postgres-spock:15` was built with:
- Spock 3.1.8 extension
- PostgreSQL 15
- All required patches for Spock compatibility

The image must be present on both servers and referenced in `docker-compose.yml`:

```yaml
db:
  image: supabase-postgres-spock:15
```

### 2. Required PostgreSQL Settings

These settings must be in `docker-compose.yml` under the `db` service command:

```yaml
command: >
  postgres
  -c wal_level=logical
  -c max_wal_senders=10
  -c max_replication_slots=10
  -c track_commit_timestamp=on
  -c shared_preload_libraries='...,spock'
```

**Critical Settings:**
| Setting | Value | Purpose |
|---------|-------|---------|
| `wal_level` | `logical` | Required for logical replication |
| `max_wal_senders` | `10` | Allow multiple replication connections |
| `max_replication_slots` | `10` | Allow multiple replication slots |
| `track_commit_timestamp` | `on` | **CRITICAL** - Spock requires this for conflict resolution |
| `shared_preload_libraries` | includes `spock` | Load Spock extension at startup |

### 3. Cloudflare Tunnels

Each server needs a cloudflared container to connect to the OTHER server's PostgreSQL:

- PRIMARY's cloudflared connects to: `pg-standby.example.com` (STANDBY's tunnel)
- STANDBY's cloudflared connects to: `pg-primary.example.com` (PRIMARY's tunnel)

---

## Cloudflare Tunnel Setup

### Directory Structure

```
./cloudflare/
├── docker-compose.yml
└── .env
```

### docker-compose.yml

```yaml
services:
  cloudflared-pg-replication:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-pg-replication
    restart: unless-stopped
    networks:
      - supabase_default
    command: access tcp --hostname ${PG_REPLICATION_HOSTNAME} --url 0.0.0.0:${PG_REPLICATION_PORT}

networks:
  supabase_default:
    external: true
```

### .env files

**On PRIMARY (connects TO standby):**
```
PG_REPLICATION_HOSTNAME=pg-standby.example.com
```

**On STANDBY (connects TO primary):**
```
PG_REPLICATION_HOSTNAME=pg-primary.example.com
```

### Start the tunnel

```bash
cd ./cloudflare
docker compose up -d
```

### Verify tunnel connectivity

```bash
# From PRIMARY, test connection to STANDBY through tunnel
docker exec supabase-db psql -h cloudflared-pg-replication -p ${PG_REPLICATION_PORT} -U postgres -c "SELECT 1;"
```

---

## PostgreSQL Configuration

### 1. Update pg_hba.conf for Spock Replicator

On BOTH servers, add this line to allow replication connections:

```bash
docker exec supabase-db bash -c "echo 'host replication spock_replicator 0.0.0.0/0 scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec supabase-db bash -c "gosu postgres pg_ctl reload -D /var/lib/postgresql/data"
```

### 2. Create Spock Replicator User

On BOTH servers:

```sql
-- Connect as supabase_admin (the superuser)
CREATE USER spock_replicator WITH REPLICATION PASSWORD 'your_secure_password';
GRANT ALL ON SCHEMA spock TO spock_replicator;
GRANT ALL ON ALL TABLES IN SCHEMA spock TO spock_replicator;
GRANT USAGE ON SCHEMA public TO spock_replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO spock_replicator;
```

### 3. Fix Collation Mismatch (if present)

If you see collation warnings, run on BOTH servers:

```sql
ALTER DATABASE postgres REFRESH COLLATION VERSION;
```

---

## Spock Extension Setup

All SQL commands should be run as `supabase_admin` (the superuser):

```bash
docker exec supabase-db gosu postgres psql -U supabase_admin -d postgres
```

### Step 1: Create the Spock Extension

On BOTH servers:

```sql
CREATE EXTENSION IF NOT EXISTS spock;
```

### Step 2: Create Local Node

**On PRIMARY:**
```sql
SELECT spock.node_create(
    node_name := 'primary',
    dsn := 'host=localhost port=5432 dbname=postgres user=spock_replicator password=your_password'
);
```

**On STANDBY:**
```sql
SELECT spock.node_create(
    node_name := 'standby',
    dsn := 'host=localhost port=5432 dbname=postgres user=spock_replicator password=your_password'
);
```

### Step 3: Add Remote Node Interface

**On PRIMARY (add STANDBY as remote node):**
```sql
-- First add the remote node
INSERT INTO spock.node (node_id, node_name)
SELECT 33686201, 'standby'
WHERE NOT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'standby');

-- Add interface to reach STANDBY through the tunnel
SELECT spock.node_add_interface(
    node_name := 'standby',
    interface_name := 'standby',
    dsn := 'host=cloudflared-pg-replication port=${PG_REPLICATION_PORT} dbname=postgres user=spock_replicator password=your_password sslmode=disable'
);
```

**On STANDBY (add PRIMARY as remote node):**
```sql
-- First add the remote node
INSERT INTO spock.node (node_id, node_name)
SELECT 144417090, 'primary'
WHERE NOT EXISTS (SELECT 1 FROM spock.node WHERE node_name = 'primary');

-- Add interface to reach PRIMARY through the tunnel
SELECT spock.node_add_interface(
    node_name := 'primary',
    interface_name := 'primary',
    dsn := 'host=cloudflared-pg-replication port=${PG_REPLICATION_PORT} dbname=postgres user=spock_replicator password=your_password sslmode=disable'
);
```

### Step 4: Create Subscriptions

**On PRIMARY (subscribe to STANDBY):**
```sql
SELECT spock.sub_create(
    subscription_name := 'sub_from_standby',
    provider_dsn := 'host=cloudflared-pg-replication port=${PG_REPLICATION_PORT} dbname=postgres user=spock_replicator password=your_password sslmode=disable',
    replication_sets := ARRAY['default'],
    synchronize_structure := false,
    synchronize_data := false
);
```

**On STANDBY (subscribe to PRIMARY):**
```sql
SELECT spock.sub_create(
    subscription_name := 'sub_from_primary',
    provider_dsn := 'host=cloudflared-pg-replication port=${PG_REPLICATION_PORT} dbname=postgres user=spock_replicator password=your_password sslmode=disable',
    replication_sets := ARRAY['default'],
    synchronize_structure := false,
    synchronize_data := false
);
```

At this point, the subscriptions will be created but the apply workers will crash. This is expected - see the next section for the required manual fixes.

---

## Manual Fixes Required

**IMPORTANT**: The Spock apply worker crashes during initialization without logging the actual error. The following manual steps are required to make replication work.

### Understanding the Issue

When a subscription is created:
1. Spock sets `sync_status = 'i'` (INIT)
2. The apply worker tries to initialize
3. It crashes before logging any useful error
4. The actual issues are: missing replication origin and missing replication slot

### Fix for PRIMARY (subscribing from STANDBY)

**Step 1: Get the subscription slot name**
```sql
-- On PRIMARY
SELECT sub_id, sub_slot_name FROM spock.subscription WHERE sub_name = 'sub_from_standby';
-- Example result: sub_id = 1713478936, slot = 'spk_postgres_standby_sub_from_standby'
```

**Step 2: Create the replication origin (on PRIMARY)**
```sql
-- On PRIMARY
SELECT pg_replication_origin_create('spk_postgres_standby_sub_from_standby');
```

**Step 3: Update sync status to READY (on PRIMARY)**
```sql
-- On PRIMARY
UPDATE spock.local_sync_status
SET sync_status = 'r', sync_statuslsn = '0/0'
WHERE sync_subid = 1713478936;  -- Use your actual sub_id
```

**Step 4: Create the replication slot on the PROVIDER (on STANDBY)**
```sql
-- On STANDBY (the provider for this subscription)
SELECT pg_create_logical_replication_slot('spk_postgres_standby_sub_from_standby', 'spock');
```

### Fix for STANDBY (subscribing from PRIMARY)

**Step 1: Get the subscription slot name**
```sql
-- On STANDBY
SELECT sub_id, sub_slot_name FROM spock.subscription WHERE sub_name = 'sub_from_primary';
-- Example result: sub_id = 2768527301, slot = 'spk_postgres_primary_sub_from_primary'
```

**Step 2: Create the replication origin (on STANDBY)**
```sql
-- On STANDBY
SELECT pg_replication_origin_create('spk_postgres_primary_sub_from_primary');
```

**Step 3: Update sync status to READY (on STANDBY)**
```sql
-- On STANDBY
UPDATE spock.local_sync_status
SET sync_status = 'r', sync_statuslsn = '0/0'
WHERE sync_subid = 2768527301;  -- Use your actual sub_id
```

**Step 4: Create the replication slot on the PROVIDER (on PRIMARY)**
```sql
-- On PRIMARY (the provider for this subscription)
SELECT pg_create_logical_replication_slot('spk_postgres_primary_sub_from_primary', 'spock');
```

### Summary of What Goes Where

| Item | PRIMARY | STANDBY |
|------|---------|---------|
| Replication Origin for sub_from_standby | Create here | - |
| Replication Origin for sub_from_primary | - | Create here |
| Replication Slot for sub_from_standby | - | Create here (provider) |
| Replication Slot for sub_from_primary | Create here (provider) | - |
| Sync status update for sub_from_standby | Update here | - |
| Sync status update for sub_from_primary | - | Update here |

---

## Adding Tables to Replication

### Create a Test Table

On BOTH servers (must have identical structure):

```sql
CREATE TABLE IF NOT EXISTS public.spock_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    source TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Grant permissions to spock_replicator
GRANT SELECT, INSERT, UPDATE, DELETE ON public.spock_test TO spock_replicator;
```

### Add Table to Replication Set

On BOTH servers:

```sql
SELECT spock.repset_add_table('default', 'public.spock_test');
```

### For Existing Tables with Data

If the table already has data and you want to sync it:

1. **Option A**: Manually copy data, then add to replication
2. **Option B**: Use `spock.sub_resync_table()` (may cause duplicates if not careful)

For bi-directional replication, it's safest to:
1. Add table to replication set on both sides when empty
2. Or manually ensure data is identical before adding

---

## Verification

### Check Subscription Status

```sql
SELECT * FROM spock.sub_show_status();
```

Expected output:
```
 subscription_name |   status    | provider_node | ...
-------------------+-------------+---------------+----
 sub_from_standby  | replicating | standby   | ...
```

Status should be `replicating`, not `down` or `initializing`.

### Check Replication Slots

On the PROVIDER server:
```sql
SELECT slot_name, plugin, active FROM pg_replication_slots WHERE plugin = 'spock';
```

`active` should be `t` (true).

### Check Replication Origins

On the SUBSCRIBER server:
```sql
SELECT * FROM pg_replication_origin;
```

### Test Bi-Directional Replication

**Insert on PRIMARY:**
```sql
INSERT INTO public.spock_test (data, source) VALUES ('Test from PRIMARY', 'primary');
```

**Check on STANDBY (should appear within seconds):**
```sql
SELECT * FROM public.spock_test ORDER BY created_at DESC LIMIT 5;
```

**Insert on STANDBY:**
```sql
INSERT INTO public.spock_test (data, source) VALUES ('Test from STANDBY', 'standby');
```

**Check on PRIMARY (should appear within seconds):**
```sql
SELECT * FROM public.spock_test ORDER BY created_at DESC LIMIT 5;
```

---

## Conflict Resolution Behavior

Spock uses **"last writer wins"** conflict resolution based on commit timestamps. This section documents the tested conflict scenarios and their outcomes.

### Critical Requirement

**`track_commit_timestamp = on`** MUST be enabled in PostgreSQL. Without this, Spock cannot properly resolve conflicts.

### Tested Conflict Scenarios

#### 1. UPDATE/UPDATE Conflict (Same Row)

**Scenario**: Same row is updated on both servers with different values.

**Result**: ✅ **Automatically resolved** - The update with the later commit timestamp wins. Both servers converge to the same value.

**Example**:
```
PRIMARY: UPDATE ... SET data = 'A' WHERE id = 1;  (timestamp: 12:00:01)
STANDBY: UPDATE ... SET data = 'B' WHERE id = 1;  (timestamp: 12:00:02)
Result: Both servers have data = 'B' (STANDBY wins due to later timestamp)
```

#### 2. INSERT/INSERT Conflict (Same Primary Key)

**Scenario**: Same primary key is inserted on both servers while disconnected.

**Result**: ⚠️ **Temporary divergence** - Each server receives the other's INSERT and converts it to an UPDATE. This can cause data to "swap" between servers.

**Important**: The divergence resolves automatically on the **next write** to that row.

**Example**:
```
While disconnected:
  PRIMARY: INSERT (id=1, data='A')
  STANDBY: INSERT (id=1, data='B')

After reconnection:
  PRIMARY has: data='B' (received from STANDBY)
  STANDBY has: data='A' (received from PRIMARY)

After ANY subsequent update:
  Both servers converge to the same value
```

**Mitigation**: Use different ID ranges on each server (e.g., PRIMARY uses 1000000+, STANDBY uses 2000000+) to avoid same-PK conflicts.

#### 3. DELETE/UPDATE Conflict

**Scenario**: Row is deleted on one server while updated on another.

**Result**: ✅ **DELETE wins** (if it has the later timestamp). The row is deleted on both servers.

**Example**:
```
PRIMARY: DELETE ... WHERE id = 1;  (timestamp: 12:00:02)
STANDBY: UPDATE ... SET data = 'X' WHERE id = 1;  (timestamp: 12:00:01)
Result: Row deleted on both servers (DELETE had later timestamp)
```

#### 4. High Concurrency

**Scenario**: Many rapid updates on both servers simultaneously.

**Result**: ✅ **All conflicts resolved** - Despite chaotic concurrent updates, both servers eventually converge to the same final value.

### Conflict Resolution Summary Table

| Conflict Type | Resolution | Data Convergence |
|---------------|------------|------------------|
| UPDATE/UPDATE | Last writer wins | Immediate |
| INSERT/INSERT (same PK) | Each applies other's INSERT as UPDATE | After next write |
| DELETE/UPDATE | DELETE wins (if later) | Immediate |
| UPDATE/DELETE | DELETE wins (if later) | Immediate |
| High concurrency | Last writer wins | Eventual |

### Best Practices for Avoiding Conflicts

1. **Use different ID ranges per server** - Prevents INSERT/INSERT conflicts
   ```sql
   -- On PRIMARY: Use sequence starting at 1,000,000
   -- On STANDBY: Use sequence starting at 2,000,000
   ```

2. **Avoid deleting recently updated rows** - Give time for updates to propagate

3. **Use application-level conflict detection** for critical data
   ```sql
   -- Add a version column
   ALTER TABLE mytable ADD COLUMN version INT DEFAULT 0;
   -- Increment on every update
   UPDATE mytable SET ..., version = version + 1 WHERE id = ? AND version = ?;
   ```

4. **Monitor for divergence** - Periodically compare row counts and checksums

### Conflict Logging

Spock can log conflicts to the `spock.resolutions` table (currently not populated in testing). To enable conflict logging:

```sql
ALTER SYSTEM SET spock.conflict_log_level = 'LOG';
SELECT pg_reload_conf();
```

---

## Troubleshooting

### Apply Worker Keeps Crashing (Exit Code 1)

**Symptom:** Logs show:
```
LOG: SPOCK sub_from_standby: starting apply worker
LOG: apply worker [PID] at slot X generation Y exiting with error
LOG: background worker "spock apply ..." exited with exit code 1
```

**Cause:** Missing replication origin, sync status not set to READY, or missing replication slot.

**Fix:** Follow the [Manual Fixes Required](#manual-fixes-required) section.

### "Replication slot does not exist" Error

**Symptom:**
```
FATAL: could not send replication command: ERROR: replication slot "..." does not exist
```

**Cause:** The replication slot wasn't created on the provider server.

**Fix:** Create the slot on the PROVIDER (the server being subscribed to):
```sql
SELECT pg_create_logical_replication_slot('slot_name_here', 'spock');
```

### Subscription Status Shows "down"

**Cause:** Apply worker is crashing. Check logs for specific error.

**Fix:** Usually requires the manual fixes described above.

### "Permission denied" Errors

**Cause:** Running commands as wrong user.

**Fix:** Always run Spock administrative commands as `supabase_admin`:
```bash
docker exec container_name gosu postgres psql -U supabase_admin -d postgres
```

### Connection Refused Through Tunnel

**Symptom:** Can't connect through cloudflared tunnel.

**Check:**
1. Is the cloudflared container running?
   ```bash
   docker ps | grep cloudflared
   ```
2. Is the Cloudflare tunnel configured correctly?
3. Is the target server's PostgreSQL accepting connections?

### Changes Not Replicating

**Check:**
1. Is the table in the replication set?
   ```sql
   SELECT * FROM spock.replication_set_table;
   ```
2. Is the subscription active?
   ```sql
   SELECT * FROM spock.sub_show_status();
   ```
3. Are there any errors in the logs?
   ```bash
   docker logs container_name 2>&1 | grep -i spock | tail -50
   ```

---

## Quick Reference Commands

### Check Everything Status

```bash
# PRIMARY
echo "=== PRIMARY ===" && \
docker exec supabase-db gosu postgres psql -U supabase_admin -d postgres -c "SELECT * FROM spock.sub_show_status();"

# STANDBY (replace with your standby server hostname)
echo "=== STANDBY ===" && \
ssh your-standby-server "docker exec supabase-db gosu postgres psql -U supabase_admin -d postgres -c \"SELECT * FROM spock.sub_show_status();\""
```

### View Spock Logs

```bash
docker logs supabase-db 2>&1 | grep -i spock | tail -30
```

### Restart a Subscription

```sql
SELECT spock.sub_disable('subscription_name');
SELECT spock.sub_enable('subscription_name');
```

### List All Tables in Replication

```sql
SELECT rs.set_name, rst.set_reloid::regclass as table_name
FROM spock.replication_set rs
JOIN spock.replication_set_table rst ON rs.set_id = rst.set_id;
```

### Check Replication Lag

On the SUBSCRIBER:
```sql
SELECT
    slot_name,
    confirmed_flush_lsn,
    pg_current_wal_lsn(),
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
FROM pg_replication_slots
WHERE plugin = 'spock';
```

---

## Production Deployment Checklist

- [ ] Custom Spock Docker image built and pushed to both servers
- [ ] docker-compose.yml updated with Spock image and required PostgreSQL settings
- [ ] Cloudflare tunnels configured and tested
- [ ] pg_hba.conf updated for spock_replicator user
- [ ] spock_replicator user created on both servers
- [ ] Spock extension created on both servers
- [ ] Local nodes created on both servers
- [ ] Remote node interfaces added on both servers
- [ ] Subscriptions created on both servers
- [ ] **Replication origins created on both servers**
- [ ] **Sync status updated to 'r' on both servers**
- [ ] **Replication slots created on provider servers**
- [ ] Tables added to replication set on both servers
- [ ] Bi-directional replication tested and verified

---

## Version Information

- **Spock Version**: 3.1.8
- **PostgreSQL Version**: 15.14
- **Docker Image**: supabase-postgres-spock:15
- **Date Tested**: 2026-01-25
