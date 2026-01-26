-- Spock Extension Initialization
-- This migration creates the Spock extension which is required for bi-directional replication
-- The extension will be created regardless of whether replication is configured

-- Create Spock extension
CREATE EXTENSION IF NOT EXISTS spock;

-- Note: The spock_replicator user and pg_hba.conf configuration
-- are handled by 99-replication-init.sh when REPLICA_HOST_IP is set
