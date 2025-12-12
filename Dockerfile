# Build stage
FROM crystallang/crystal:1.18.2-alpine AS builder

WORKDIR /build

# Install build dependencies
RUN apk add --no-cache \
    yaml-static \
    postgresql-dev \
    openssl-dev \
    openssl-libs-static \
    pcre-dev \
    gc-dev \
    libevent-static \
    zlib-static \
    xz-static

# Copy dependency files first for better caching
COPY shard.yml shard.lock ./

# Install dependencies
RUN shards install --production

# Copy source code
COPY src ./src

# Build static binary
RUN crystal build src/main.cr \
    --release \
    --static \
    --no-debug \
    -o nostr-relay

# Runtime stage
FROM scratch

# Copy CA certificates for HTTPS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the binary
COPY --from=builder /build/nostr-relay /nostr-relay

# Expose WebSocket port
EXPOSE 8080

# Run as non-root (note: scratch doesn't have users, so we just set the binary)
ENTRYPOINT ["/nostr-relay"]
