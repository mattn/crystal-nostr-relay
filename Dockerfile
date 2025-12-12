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
COPY public ./public

# Build static binary
RUN crystal build src/main.cr \
    --release \
    --static \
    --no-debug \
    -o nostr-relay

# Runtime stage
FROM alpine:latest

WORKDIR /app

# Run as non-root user
RUN addgroup -g 1000 nostr && \
    adduser -D -u 1000 -G nostr nostr && \
    chown -R nostr:nostr /app

USER nostr

# Copy CA certificates for HTTPS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the binary
COPY --from=builder /build/nostr-relay /app/nostr-relay

COPY --from=builder --chown=nostr:nostr /build/public /app/public

# Expose WebSocket port
EXPOSE 8080

ENV RELAY_NAME="Crystal Nostr Relay"
ENV RELAY_DESCRIPTION="A lightweight Nostr relay implementation in Crystal"
ENV RELAY_URL="ws://localhost:8080"
ENV DATABASE_URL="postgresql://user:password@localhost:5432/crystal-nostr-relay?auth_methods=cleartext"

# Run as non-root (note: scratch doesn't have users, so we just set the binary)
ENTRYPOINT ["./nostr-relay"]
