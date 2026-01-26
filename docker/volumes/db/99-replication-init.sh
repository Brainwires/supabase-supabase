#!/bin/bash
# Spock replication user initialization script
# This script runs on container startup and configures:
# 1. spock_replicator user with proper grants
# 2. pg_hba.conf for replication access
#
# Note: The Spock extension is created by 98-spock.sql migration
# This script only runs when REPLICA_HOST_IP is set

set -e

# Check if replication is configured
if [ -z "$REPLICA_HOST_IP" ]; then
  echo "REPLICA_HOST_IP not set, skipping replication user configuration"
  echo "Spock extension is available but bi-directional replication is disabled"
  exit 0
fi

if [ -z "$REPLICATION_PASSWORD" ]; then
  echo "WARNING: REPLICA_HOST_IP is set but REPLICATION_PASSWORD is empty"
  echo "Replication user will not be created"
  exit 0
fi

echo "=== Configuring Spock Replication ==="
echo "REPLICA_HOST_IP=$REPLICA_HOST_IP"

# Create spock_replicator user with proper grants
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$\$
  BEGIN
    -- Create spock_replicator user if it doesn't exist
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'spock_replicator') THEN
      CREATE USER spock_replicator WITH REPLICATION LOGIN PASSWORD '$REPLICATION_PASSWORD';
      RAISE NOTICE 'Created replication user: spock_replicator';
    ELSE
      -- Update password if user exists
      ALTER USER spock_replicator WITH PASSWORD '$REPLICATION_PASSWORD';
      RAISE NOTICE 'Updated spock_replicator password';
    END IF;
  END
  \$\$;

  -- Grant permissions to spock_replicator
  GRANT ALL ON SCHEMA spock TO spock_replicator;
  GRANT ALL ON ALL TABLES IN SCHEMA spock TO spock_replicator;
  GRANT USAGE ON SCHEMA public TO spock_replicator;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO spock_replicator;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO spock_replicator;
EOSQL

echo "Spock replicator user configured"

# Add replication lines to pg_hba.conf if not present
PG_HBA="/var/lib/postgresql/data/pg_hba.conf"
if [ -f "$PG_HBA" ]; then
  # Add entry for replication connections
  if ! grep -q "host.*replication.*spock_replicator.*0.0.0.0/0" "$PG_HBA" 2>/dev/null; then
    echo "host    replication     spock_replicator      0.0.0.0/0        scram-sha-256" >> "$PG_HBA"
    echo "Added replication entry to pg_hba.conf"
  fi

  # Add entry for regular connections (needed for Spock)
  if ! grep -q "host.*all.*spock_replicator.*0.0.0.0/0" "$PG_HBA" 2>/dev/null; then
    echo "host    all             spock_replicator      0.0.0.0/0        scram-sha-256" >> "$PG_HBA"
    echo "Added spock_replicator access entry to pg_hba.conf"
  fi
else
  echo "WARNING: pg_hba.conf not found at $PG_HBA"
fi

echo "=== Spock replication configuration complete ==="
echo "Next steps:"
echo "  1. Create local node: SELECT spock.node_create(...);"
echo "  2. Add remote node interface: SELECT spock.node_add_interface(...);"
echo "  3. Create subscription: SELECT spock.sub_create(...);"
echo "  See SPOCK-SETUP.md for detailed instructions"
