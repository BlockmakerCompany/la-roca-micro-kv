# Contributing to la-roca-micro-kv

Thank you for your interest in contributing! This guide covers everything you need to get the development environment set up and start contributing.

## Prerequisites

Make sure the following tools are installed before you begin:

| Tool | Version | Purpose |
|------|---------|---------|
| [NASM](https://www.nasm.us/) | >= 2.15 | Assembler for x86_64 source files |
| [binutils](https://www.gnu.org/software/binutils/) | >= 2.35 | `ld` linker |
| [Docker](https://docs.docker.com/get-docker/) | >= 20.10 | Containerised build and integration tests |
| [curl](https://curl.se/) | any recent | Used in integration test scripts |
| [nc (netcat)](https://nmap.org/ncat/) | any | Port-readiness probing in test scripts |
| [k6](https://k6.io/) | >= 0.46 | Load / benchmark testing (optional) |

Verify your setup:

```bash
nasm --version   # NASM version 2.x
ld --version     # GNU ld 2.x
docker --version # Docker version 20.x
```

## Project Structure

```
la-roca-micro-kv/
├── src/          # x86_64 Assembly source files
├── tests/        # Integration and unit test scripts
├── charts/       # Benchmark / performance charts
├── Makefile      # All build and test targets
├── Dockerfile    # Container build definition
├── docker-compose.yaml
├── config.inc    # Shared NASM constants
├── openapi.yaml  # HTTP API specification
├── ARCHITECTURE.md
└── BENCHMARKS.md
```

## Local Development

### Build

```bash
# Clean previous build artifacts and rebuild
make clean && make
```

The compiled binary is placed in the project root.

### Run locally

```bash
# Start the key-value store on the default port
./la-roca-micro-kv
```

### Quick iteration (build + run)

```bash
make dev
```

## Running Tests

```bash
# Run the full test suite
make test
```

Tests require Docker to be running. The Makefile will start a temporary container, run the test scripts against it, and tear it down afterwards.

## Docker Build and Run

```bash
# Build the Docker image
docker build -t la-roca-micro-kv .

# Run the container (exposes port 8080 by default)
docker run -p 8080:8080 la-roca-micro-kv

# Or use docker-compose
docker-compose up --build
```

## Submitting a Pull Request

1. **Fork** the repository and create a branch from `main`:
   ```bash
      git checkout -b fix/my-descriptive-branch-name
         ```
         2. **Make your changes** and ensure `make test` passes.
         3. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/):
            - `fix:` for bug fixes
               - `feat:` for new features
                  - `docs:` for documentation changes
                     - `refactor:` for internal refactoring with no behaviour change
                     4. **Open a PR** against the `main` branch of `BlockmakerCompany/la-roca-micro-kv`.
                     5. Fill in the PR template, reference any related issue (e.g. `Closes #14`), and wait for a review.

                     ## Code Style

                     - Follow the existing NASM conventions in `src/`.
                     - Keep procedures small and well-commented.
                     - Update `ARCHITECTURE.md` if you change the data layout or protocol.

                     ## Getting Help

                     Open a [GitHub Issue](https://github.com/BlockmakerCompany/la-roca-micro-kv/issues) if you run into problems not covered here.
