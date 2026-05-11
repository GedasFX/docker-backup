# ── base: core backup functionality (restic + rsync) ───────────────
FROM alpine:3.20 AS base

ARG SOURCE_VERSION=dev
ARG SOURCE_SHA=local
ARG BUILD_DATE=unknown
ARG ALPINE_VERSION=3.20
ARG SUPERCRONIC_VERSION=0.2.33

RUN apk add --no-cache \
        restic \
        rsync \
        curl \
        tini \
        bash \
        docker-cli \
        coreutils \
    && arch=$(uname -m) \
    && case "$arch" in \
        x86_64)  sc_arch="linux-amd64" ;; \
        aarch64) sc_arch="linux-arm64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-${sc_arch}" \
        -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic

RUN addgroup -g 1000 backup \
    && adduser -u 1000 -G backup -s /bin/bash -D backup \
    && mkdir -p /var/run/docker-backup /var/cache/docker-backup \
        /usr/local/lib/docker-backup/modules.d \
    && chown backup:backup /var/run/docker-backup /var/cache/docker-backup

LABEL org.opencontainers.image.source="https://github.com/gedasfx/docker-backup" \
      org.opencontainers.image.revision="${SOURCE_SHA}" \
      org.opencontainers.image.version="${SOURCE_VERSION}-${SOURCE_SHA}-${BUILD_DATE}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses=MIT

COPY scripts/entrypoint.sh /usr/local/bin/
COPY scripts/backup.sh     /usr/local/bin/
COPY scripts/healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

HEALTHCHECK --interval=1h --timeout=5s --retries=2 \
  CMD /usr/local/bin/healthcheck.sh

USER backup
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]

# ── pg: adds built-in pg_dump support ──────────────────────────────
FROM base AS pg

USER root
RUN apk add --no-cache postgresql16-client
COPY scripts/modules/pg.sh /usr/local/lib/docker-backup/modules.d/
USER backup
