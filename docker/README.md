# Self-Hosted Supabase with Docker

This is the official Docker Compose setup for self-hosted Supabase. It provides a complete stack with all Supabase services running locally or on your infrastructure.

## Getting Started

Follow the detailed setup guide in our documentation: [Self-Hosting with Docker](https://supabase.com/docs/guides/self-hosting/docker)

The guide covers:
- Prerequisites (Git and Docker)
- Initial setup and configuration
- Securing your installation
- Accessing services
- Updating your instance

## What's Included

This Docker Compose configuration includes the following services:

- **[Studio](https://github.com/supabase/supabase/tree/master/apps/studio)** - A dashboard for managing your self-hosted Supabase project
- **[Kong](https://github.com/Kong/kong)** - Kong API gateway
- **[Auth](https://github.com/supabase/auth)** - JWT-based authentication API for user sign-ups, logins, and session management
- **[PostgREST](https://github.com/PostgREST/postgrest)** - Web server that turns your PostgreSQL database directly into a RESTful API
- **[Realtime](https://github.com/supabase/realtime)** - Elixir server that listens to PostgreSQL database changes and broadcasts them over websockets
- **[Storage](https://github.com/supabase/storage)** - RESTful API for managing files in S3, with Postgres handling permissions
- **[imgproxy](https://github.com/imgproxy/imgproxy)** - Fast and secure image processing server
- **[postgres-meta](https://github.com/supabase/postgres-meta)** - RESTful API for managing Postgres (fetch tables, add roles, run queries)
- **[PostgreSQL](https://github.com/supabase/postgres)** - Object-relational database with over 30 years of active development
- **[Edge Runtime](https://github.com/supabase/edge-runtime)** - Web server based on Deno runtime for running JavaScript, TypeScript, and WASM services
- **[Logflare](https://github.com/Logflare/logflare)** - Log management and event analytics platform
- **[Vector](https://github.com/vectordotdev/vector)** - High-performance observability data pipeline for logs
- **[Supavisor](https://github.com/supabase/supavisor)** - Supabase's Postgres connection pooler

## Documentation

- **[Documentation](https://supabase.com/docs/guides/self-hosting/docker)** - Setup and configuration guides
- **[CHANGELOG.md](./CHANGELOG.md)** - Track recent updates and changes to services
- **[versions.md](./versions.md)** - Complete history of Docker image versions for rollback reference

## Updates

To update your self-hosted Supabase instance:

1. Review [CHANGELOG.md](./CHANGELOG.md) for breaking changes
2. Check [versions.md](./versions.md) for new image versions
3. Update `docker-compose.yml` if there are configuration changes
4. Pull the latest images: `docker compose pull`
5. Stop services: `docker compose down`
6. Start services with new configuration: `docker compose up -d`

**Note:** Consider to always backup your database before updating.

## Community & Support

For troubleshooting common issues, see:
- [GitHub Discussions](https://github.com/orgs/supabase/discussions?discussions_q=is%3Aopen+label%3Aself-hosted) - Questions, feature requests, and workarounds
- [GitHub Issues](https://github.com/supabase/supabase/issues?q=is%3Aissue%20state%3Aopen%20label%3Aself-hosted) - Known issues
- [Documentation](https://supabase.com/docs/guides/self-hosting) - Setup and configuration guides

Self-hosted Supabase is community-supported. Get help and connect with other users:

- [Discord](https://discord.supabase.com) - Real-time chat and community support
- [Reddit](https://www.reddit.com/r/Supabase/) - Official Supabase subreddit

Share your self-hosting experience:

- [GitHub Discussions](https://github.com/orgs/supabase/discussions/39820) - "Self-hosting: What's working (and what's not)?"

## Important Notes

### Security

⚠️ **The default configuration is not secure for production use.**

Before deploying to production, you must:
- Update all default passwords and secrets in the `.env` file
- Generate new JWT secrets
- Review and update CORS settings
- Consider setting up a secure proxy in front of self-hosted Supabase
- Review and adjust network security configuration (ACLs, etc.)
- Set up proper backup procedures

See the [security section](https://supabase.com/docs/guides/self-hosting/docker#configuring-and-securing-supabase) in the documentation.

## Bi-Directional Replication with Spock

This Docker setup uses a custom PostgreSQL image that includes the [Spock](https://github.com/pgEdge/spock) extension for bi-directional logical replication. This enables active-active replication between two or more Supabase instances.

### Prerequisites

⚠️ **Supabase CLI Required for Migrations**

When using Spock replication, the [Supabase CLI](https://supabase.com/docs/guides/cli) is **strongly recommended** for running database migrations.

**Why?** Spock does not automatically replicate DDL (schema changes) like `CREATE TABLE`, `ALTER TABLE`, etc. All DDL statements must be wrapped in `spock.replicate_ddl()` to replicate to other nodes. The Supabase CLI handles this automatically when Spock is enabled in your `config.toml`.

**Without the CLI**, you must manually wrap every DDL statement:
```sql
-- Instead of this (won't replicate):
CREATE TABLE public.users (id SERIAL PRIMARY KEY, name TEXT);

-- You must write this:
SELECT spock.replicate_ddl($$
    CREATE TABLE public.users (id SERIAL PRIMARY KEY, name TEXT)
$$);
```

**With the CLI**, your migrations stay clean and the wrapping is automatic:
```sql
-- supabase/migrations/20240101000000_create_users.sql
-- Just write normal SQL - CLI wraps it automatically
CREATE TABLE public.users (id SERIAL PRIMARY KEY, name TEXT);
```

To enable Spock in the CLI, add to your `config.toml`:
```toml
[db.spock]
enabled = true
replication_sets = ["default", "ddl_sql"]
auto_add_tables = true
node_offset = 1  # Use 2 on standby node
```

Then run migrations with:
```bash
supabase migration up \
  --db-url "postgresql://postgres:password@primary:5432/postgres" \
  --spock-remote-dsn "postgresql://postgres:password@standby:5432/postgres"
```

### How It Works

- The Spock extension is automatically installed when the database initializes
- A replication user (`spock_replicator`) is created automatically
- pg_hba.conf is pre-configured to allow replication connections
- An event trigger automatically adds new tables to the `default` replication set
- Data changes (INSERT, UPDATE, DELETE) replicate automatically once tables are in a replication set

### Setting Up Bi-Directional Replication

For two Supabase instances (e.g., PRIMARY and STANDBY):

1. **Configure both instances** with different ports and unique `COMPOSE_PROJECT_NAME` values in their `.env` files

2. **Start both instances**:
   ```bash
   # On primary server
   docker compose up -d

   # On standby server
   docker compose up -d
   ```

3. **Run the setup script on each node** (after both are running):
   ```bash
   # On PRIMARY first - creates the primary node
   docker exec <primary-db-container> /spock-setup.sh primary <standby-host> <standby-db-port>

   # On STANDBY - subscribe to PRIMARY
   docker exec <standby-db-container> /spock-setup.sh standby <primary-host> <primary-db-port>
   ```

4. **Run migrations using Supabase CLI** (recommended) or manually wrap DDL:

   **Using CLI (recommended):**
   ```bash
   supabase migration up \
     --db-url "postgresql://postgres:password@primary:5432/postgres" \
     --spock-remote-dsn "postgresql://postgres:password@standby:5432/postgres"
   ```

   **Manual alternative:**
   ```sql
   -- Run on either node - DDL replicates to all subscribers
   SELECT spock.replicate_ddl($$
       CREATE TABLE public.my_table (
           id SERIAL PRIMARY KEY,
           data TEXT
       )
   $$);
   ```

5. **Configure sequences** to avoid primary key conflicts:
   ```sql
   -- On STANDBY only, set different sequence range
   ALTER SEQUENCE my_table_id_seq RESTART WITH 1000000;
   ```

   Note: The CLI handles this automatically when `node_offset` is configured.

### Important Notes

- **DDL replication**: DDL must be wrapped in `spock.replicate_ddl()` - use Supabase CLI for automatic wrapping
- **Auto repset**: Tables are automatically added to the `default` replication set via event trigger
- **Sequence conflicts**: Use different sequence ranges on each node (CLI handles this with `node_offset`)
- **Change the default password**: Update `REPLICATION_PASSWORD` in `.env` for production use

### Disabling Replication

If you don't need replication, you can use this setup as a standard Supabase installation. The Spock extension is installed but inactive until you run the setup script.

## License

This repository is licensed under the Apache 2.0 License. See the main [Supabase repository](https://github.com/supabase/supabase) for details.
