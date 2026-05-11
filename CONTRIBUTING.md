# Contributing

## Adding a new module

Modules extend docker-backup with database dump support or other pre-backup
actions. Each module is self-contained -- adding one requires **zero changes**
to the core scripts (`backup.sh`, `entrypoint.sh`).

### 1. Create the module script

Add `scripts/modules/<name>.sh`. The file must define four functions using the
naming convention `mod_<name>_<hook>`:

```bash
#!/usr/bin/env bash
# Module: <name> — short description
#
# Activated by: BACKUP_<NAME>_HOST (or similar env var)

mod_<name>_validate() {
  # Called once at container startup (entrypoint.sh).
  # Check that required binaries and env vars are present.
  # Return 0 early if the module's activation env var is unset.
  # Exit non-zero to abort startup.
}

mod_<name>_backup() {
  # Called each backup run, before user pre-hooks.
  # Run the dump/export and write output to a scratch directory.
  # Return 0 early if not activated.
  # Use `fail "message"` to abort the run and fire the failure webhook.
}

mod_<name>_sources() {
  # Print paths (one per line) to add to the restic snapshot.
  # Print nothing and return 0 if not activated.
}

mod_<name>_cleanup() {
  # Called after user post-hooks.
  # Remove scratch files created by mod_<name>_backup.
  # Return 0 early if not activated.
}
```

Each function must guard itself with an activation check so it's a no-op when
the module's env vars are not set:

```bash
mod_<name>_validate() {
  [[ -z "${BACKUP_<NAME>_HOST:-}" ]] && return 0
  # ... actual validation ...
}
```

The module is sourced into the main shell, so it has access to the core helpers
`log` and `fail`.

### 2. Add a Dockerfile stage

Append a new stage to `Dockerfile` that extends `base`:

```dockerfile
# ── <name>: short description ─────────────────────────────────────
FROM base AS <name>

RUN apk add --no-cache <client-package>
COPY scripts/modules/<name>.sh /usr/local/lib/docker-backup/modules.d/
```

### 3. Add a CI matrix entry

In `.github/workflows/build.yml`, add an entry to `strategy.matrix.include`:

```yaml
- target: <name>
  suffix: "-<name>"
```

This produces image tags like `:1-<name>`, `:latest-<name>`, etc.

### 4. Add an example compose file

Create `examples/compose-with-<name>.yml` showing a typical setup. Use the
`-<name>` image tag.

### Conventions

- **Scratch directory**: use `/var/cache/docker-backup/<name>` for temporary
  dump output. Clean it up in `mod_<name>_cleanup`.
- **Env var prefix**: use `BACKUP_<NAME>_` for all module-specific variables.
- **Activation**: gate on a single env var (typically `BACKUP_<NAME>_HOST`).
  The module should be completely inert when that var is unset.
- **Restic dependency**: if the module produces files that need snapshotting,
  validate that restic is configured in `mod_<name>_validate`.

### Existing modules

| Module | Activation var | Image tag | Client package |
|--------|---------------|-----------|----------------|
| `pg` | `BACKUP_PG_HOST` | `:1-pg` | `postgresql16-client` |
