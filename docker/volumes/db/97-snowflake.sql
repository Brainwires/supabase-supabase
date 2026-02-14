-- Snowflake Extension Initialization
-- Creates the snowflake extension for distributed unique ID generation
-- Required: snowflake.node must be set in postgresql-spock.conf (1-1023, unique per node)

CREATE EXTENSION IF NOT EXISTS snowflake;
