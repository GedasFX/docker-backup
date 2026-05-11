# docker-backup

A small Docker image that any docker-compose service can drop in as a sidecar
to get versioned snapshots (restic) + current-state mirror (rsync) of its data,
configured entirely via environment variables.

## Quick start

See `examples/` for compose snippets covering common patterns:

- **restic-only** — simple versioned snapshots
- **with-mirror** — restic + rsync for bulky immutable data
- **with-pgdump** — built-in pg_dump prong (recommended for postgres)
- **pg-advanced** — docker.sock exec or external dump sidecar fallbacks

## License

MIT
