# docker-backup

A small Docker image that any docker-compose service can drop in as a sidecar
to get versioned snapshots (restic) + current-state mirror (rsync) of its data,
configured entirely via environment variables.

## Quick start

See `examples/` for compose snippets covering common patterns:

- **restic-only** — versioned snapshots of a small data volume
- **with-mirror** — restic + rsync for services with bulky immutable data
- **with-pgdump** — built-in pg_dump via the `-pg` image tag (recommended for postgres)
- **pg-advanced** — docker.sock exec or external dump sidecar fallbacks

## Image tags

| Tag | Contents |
|-----|----------|
| `:1`, `:latest` | Core image (restic, rsync, hooks) |
| `:1-pg`, `:latest-pg` | Core + postgresql client (`pg_dump`) |

The image runs as a non-root user (uid 1000). See `compose-pg-advanced.yml`
for the `group_add` workaround when mounting `docker.sock`.

## License

MIT
