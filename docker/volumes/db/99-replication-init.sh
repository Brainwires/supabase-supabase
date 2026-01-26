#!/bin/bash
# Replication initialization script for PostgreSQL streaming replication
# This script runs on container startup and configures pg_hba.conf for replication
# Only executes if REPLICA_HOST_IP is set

set -e

# Only run if replication is configured
if [ -z "$REPLICA_HOST_IP" ]; then
  echo "REPLICA_HOST_IP not set, skipping replication configuration"
  exit 0
fi

if [ -z "$REPLICATION_PASSWORD" ]; then
  echo "WARNING: REPLICA_HOST_IP is set but REPLICATION_PASSWORD is empty"
  echo "Replication user will not be created"
  exit 0
fi

echo "Configuring replication for replica at $REPLICA_HOST_IP"

# Create replication user if it doesn't exist
# This runs as the postgres user via docker-entrypoint
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
      CREATE USER replicator WITH REPLICATION LOGIN PASSWORD '$REPLICATION_PASSWORD';
      RAISE NOTICE 'Created replication user: replicator';
    ELSE
      -- Update password if user exists
      ALTER USER replicator WITH PASSWORD '$REPLICATION_PASSWORD';
      RAISE NOTICE 'Updated replication user password';
    END IF;
  END
  \$\$;
EOSQL

# Add replication line to pg_hba.conf if not present
PG_HBA="/var/lib/postgresql/data/pg_hba.conf"
if [ -f "$PG_HBA" ]; then
  if ! grep -q "host.*replication.*replicator.*${REPLICA_HOST_IP}" "$PG_HBA" 2>/dev/null; then
    echo "host    replication     replicator      ${REPLICA_HOST_IP}/32        scram-sha-256" >> "$PG_HBA"
    echo "Replication host added to pg_hba.conf for $REPLICA_HOST_IP"
  else
    echo "Replication host already configured in pg_hba.conf"
  fi
else
  echo "WARNING: pg_hba.conf not found at $PG_HBA"
  echo "This script may be running too early in the initialization"
fi

echo "Replication configuration complete"
