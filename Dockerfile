# --- Stage 1: The Forge (Builder) ---
# This stage handles the compilation of the Assembly source into a static binary.
FROM alpine AS builder

# 1. Install build dependencies
# nasm: The assembler
# binutils: Provides 'ld' (linker) and 'strip'
# make: Orchestrates the build process
RUN apk add --no-cache nasm binutils make

# 2. Setup a non-privileged user (UID 1000) for security
RUN adduser -D -u 1000 asmuser

WORKDIR /app

# 3. Initialize directory structure
# build: object files (.o)
# bin: final executable
# db: persistent storage shards
RUN mkdir -p build bin db && chown -R 1000:1000 /app

# 4. Ingest project source and configuration
# Copying Makefile and config.inc first to optimize Docker layer caching
COPY config.inc Makefile ./
COPY src/ ./src/

# 5. Modular Compilation & Linkage
# Using the Makefile ensures parity between local development and container builds
RUN make clean && make

# 6. Binary Hardening
# Strip all symbols to minimize binary size and complicate reverse engineering
RUN strip -s bin/micro_rest

# --- Stage 2: The Void (Production Runner) ---
# A zero-dependency scratch image for maximum performance and minimal attack surface.
FROM scratch

# 1. Import user identity from the Forge
COPY --from=builder /etc/passwd /etc/passwd

# 2. Mirror persistent storage volume
COPY --from=builder --chown=1000:1000 /app/db /app/db

# 3. Deploy high-performance static binary
COPY --from=builder /app/bin/micro_rest /app/micro_rest

WORKDIR /app
USER 1000

# Standard port for Micro-KV communications
EXPOSE 8080

# Execute "La Roca" as the entrypoint
ENTRYPOINT ["/app/micro_rest"]