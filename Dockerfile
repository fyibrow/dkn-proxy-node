# ═══════════════════════════════════════════════════════════════════════════════
# Stage 1 — Build
# ═══════════════════════════════════════════════════════════════════════════════
FROM rust:1.83-slim-bookworm AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Cache dependencies layer: copy manifests first, then source
COPY Cargo.toml Cargo.lock ./

# Pre-fetch dependencies (dummy build to cache layers)
RUN mkdir -p src && \
    echo 'fn main(){}' > src/main.rs && \
    cargo fetch 2>/dev/null || true && \
    rm -rf src

# Copy full source
COPY . .

# Build release binary
RUN cargo build --release 2>&1 && \
    strip target/release/dria-node

# ═══════════════════════════════════════════════════════════════════════════════
# Stage 2 — Runtime (minimal image)
# ═══════════════════════════════════════════════════════════════════════════════
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder
COPY --from=builder /build/target/release/dria-node /usr/local/bin/dria-node

# Non-root user
RUN useradd -r -s /bin/false -m -d /home/dria dria
USER dria

# dria-node writes nothing to disk (no model downloads)
WORKDIR /home/dria

ENTRYPOINT ["dria-node"]
CMD ["start"]

# Labels
LABEL org.opencontainers.image.title="dria-proxy-node"
LABEL org.opencontainers.image.description="Dria Compute Node — Cloud API Proxy Edition"
LABEL org.opencontainers.image.source="https://github.com/fyibrow/dkn-proxy-node"
