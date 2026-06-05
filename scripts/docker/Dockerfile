# beszel DuckDB ingester/reporter — Alpine.
#
# Build context MUST be the scripts/ dir so the duck-*.sh files are reachable:
#   docker build -f scripts/docker/Dockerfile -t beszel-duck scripts/
#
# DuckDB ships native musl CLI builds (duckdb_cli-linux-<arch>-musl.zip), so on
# Alpine we use those directly — no gcompat shim. A build-time smoke test confirms
# the binary runs on this base/arch.
FROM alpine:3.20

ARG DUCKDB_VERSION=1.5.3
ARG TARGETARCH

RUN apk add --no-cache \
      bash curl jq coreutils tzdata ca-certificates unzip su-exec \
      libstdc++ libgcc \
 && case "${TARGETARCH:-amd64}" in \
      amd64) DUCK_ARCH=amd64 ;; \
      arm64) DUCK_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/duckdb.zip \
      "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${DUCK_ARCH}-musl.zip" \
 && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
 && chmod +x /usr/local/bin/duckdb \
 && rm /tmp/duckdb.zip

# report/ingest tools + entrypoints (build context = scripts/)
COPY duck-ingest.sh duck-report-capacity.sh duck-report-basics.sh duck-haproxy-ingest.sh duck-report-haproxy.sh duck-report-summary.sh duck-conntrack-ingest.sh duck-report-conntrack.sh duck-report-cross.sh /usr/local/bin/
COPY docker/entrypoints/capacity.sh docker/entrypoints/haproxy.sh docker/entrypoints/conntrack.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/duck-ingest.sh /usr/local/bin/duck-report-capacity.sh \
      /usr/local/bin/duck-report-basics.sh \
      /usr/local/bin/duck-haproxy-ingest.sh /usr/local/bin/duck-report-haproxy.sh \
      /usr/local/bin/duck-report-summary.sh \
      /usr/local/bin/duck-conntrack-ingest.sh /usr/local/bin/duck-report-conntrack.sh \
      /usr/local/bin/duck-report-cross.sh \
      /usr/local/bin/capacity.sh /usr/local/bin/haproxy.sh /usr/local/bin/conntrack.sh \
 # back-compat aliases for the pre-reorg entrypoint names (drop once compose is migrated)
 && ln -sf /usr/local/bin/capacity.sh /usr/local/bin/entrypoint.sh \
 && ln -sf /usr/local/bin/haproxy.sh  /usr/local/bin/haproxy-entrypoint.sh

# non-root user; /data holds the DuckDB file (named volume OR host bind mount).
# We DON'T set USER here: the entrypoint starts as root only to fix bind-mount
# ownership, then drops to `duck` via su-exec for all real work.
RUN adduser -D -h /home/duck duck && mkdir -p /data && chown duck:duck /data
ENV DUCK_DB=/data/beszel.duckdb \
    GLOB='*' \
    INGEST_INTERVAL=2700 \
    LOOKBACK_MIN=70 \
    TZ_OFFSET=8
VOLUME ["/data"]

# Smoke-check at build time that the duckdb binary actually runs on this base.
RUN duckdb -c "SELECT 'duckdb ok' AS check;"

ENTRYPOINT ["/usr/local/bin/capacity.sh"]

# ---------------------------------------------------------------------------
# glibc fallback if Alpine+gcompat misbehaves — replace the FROM and apk line:
#   FROM debian:bookworm-slim
#   RUN apt-get update && apt-get install -y --no-install-recommends \
#         bash curl jq tzdata ca-certificates unzip && rm -rf /var/lib/apt/lists/*
#   (drop gcompat/libstdc++/libgcc; coreutils 'date' is already GNU on debian)
#   USER setup: RUN useradd -m duck && mkdir -p /data && chown duck /data
# ---------------------------------------------------------------------------
