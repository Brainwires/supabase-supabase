-- Spock Replication User Setup
-- This creates the spock_replicator user needed for bi-directional replication
-- The user is created with a default password - change REPLICATION_PASSWORD in .env for production

DO $$
BEGIN
  -- Create spock_replicator user if it doesn't exist
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'spock_replicator') THEN
    -- Default password is 'spock_replication_password_change_me'
    -- Override by setting REPLICATION_PASSWORD in .env and running:
    --   ALTER USER spock_replicator WITH PASSWORD 'your_new_password';
    CREATE USER spock_replicator WITH REPLICATION LOGIN PASSWORD 'spock_replication_password_change_me';
    RAISE NOTICE 'Created replication user: spock_replicator';
  END IF;
END
$$;

-- Grant permissions to spock_replicator for Spock extension access
GRANT USAGE ON SCHEMA spock TO spock_replicator;
GRANT ALL ON ALL TABLES IN SCHEMA spock TO spock_replicator;
GRANT USAGE ON SCHEMA public TO spock_replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO spock_replicator;

-- Grant permissions for future tables in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO spock_replicator;
